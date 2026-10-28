defmodule Exmaster.UE2.MasterTest do
  @moduledoc "The UT2004 master over real sockets, as UT2004's server and qstat speak to it."
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Exmaster.{RateLimit, Store, UE2}
  alias Exmaster.UE2.Master

  @localhost {127, 0, 0, 1}
  @store :exmaster_ue2

  setup do
    Store.clear(@store)
    RateLimit.clear()
    :ok
  end

  defp start(opts \\ []) do
    pid = start_supervised!({Master, [ip: @localhost, port: 0] ++ opts})
    Master.port(pid)
  end

  defp connect(port) do
    {:ok, s} = :gen_tcp.connect(@localhost, port, [:binary, active: false])
    s
  end

  defp write(s, payload), do: :ok = :gen_tcp.send(s, UE2.frame(payload))

  defp read(s) do
    with {:ok, <<n::little-32>>} <- :gen_tcp.recv(s, 4, 2_000),
         {:ok, payload} <- :gen_tcp.recv(s, n, 2_000) do
      payload
    end
  end

  defp str(s), do: IO.iodata_to_binary(UE2.string(s))

  defp hello(name, version \\ 3369),
    do:
      str(String.duplicate("0", 32)) <>
        str(String.duplicate("0", 32)) <> str(name) <> <<version::little-32, 6>> <> str("int")

  defp challenge(s) do
    assert {:ok, challenge, ""} = UE2.decode_string(read(s))
    assert challenge =~ ~r/\A[0-9]{8}\z/
  end

  # A server's handshake, as UT2004 3369's.
  defp uplink(port) do
    s = connect(port)
    challenge(s)
    write(s, hello("UT2K4SERVER") <> <<-1::little-32, 0>>)
    assert read(s) == <<9, "APPROVED", 0>>
    write(s, <<0::32, 0::32>>)
    assert <<1, 120::little-32, _::binary>> = read(s)
    write(s, <<4, 44::little-32>>)
    s
  end

  defp heartbeat(port, opts \\ []) do
    rules = Keyword.get(opts, :rules, [{"ServerVersion", "3369"}, {"mutator", "DMMutator"}])

    IO.iodata_to_binary([
      <<1>>,
      UE2.compact(0),
      <<0::32>>,
      UE2.string(""),
      <<port::little-32, 0::32>>,
      UE2.string(Keyword.get(opts, :hostname, "exmaster test")),
      UE2.string(Keyword.get(opts, :map, "DM-Rankin")),
      UE2.string(Keyword.get(opts, :gametype, "xDeathMatch")),
      <<Keyword.get(opts, :players, 0)::little-32, 16::little-32, 0::32, 0::32>>,
      UE2.string("0"),
      UE2.compact(length(rules)),
      Enum.map(rules, fn {k, v} -> [UE2.string(k), UE2.string(v)] end),
      UE2.compact(0)
    ])
  end

  defp lookup(port), do: Store.lookup(@store, {@localhost, port}, Exmaster.now())

  defp eventually(f, tries \\ 100) do
    case f.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(10)
        eventually(f, tries - 1)

      result ->
        result
    end
  end

  # A client's handshake, as qstat's: it wants the approval in exactly
  # these bytes.
  defp ask(port, request) do
    s = connect(port)
    challenge(s)
    write(s, hello("UT2K4CLIENT") <> <<0::32, 0xEEEE::little-32, 17::little-32, 1>>)
    assert {:ok, <<14, 0, 0, 0, 9, "APPROVED", 0, 3, 0, 0, 0>>} = :gen_tcp.recv(s, 18, 2_000)
    write(s, str("!" <> String.duplicate("0", 32)))
    assert read(s) == <<9, "VERIFIED", 0>>
    write(s, request)
    s
  end

  defp list(port, filters \\ []) do
    query =
      Enum.map(filters, fn {k, v, op} -> [UE2.string(k), UE2.string(v), op] end)

    s = ask(port, IO.iodata_to_binary([0, length(filters), query]))
    <<count::little-32, 1>> = read(s)
    entries = for _ <- 1..count//1, do: read(s)
    assert :gen_tcp.recv(s, 0, 2_000) == {:error, :closed}

    for <<a, b, c, d, port::little-16, query_port::little-16, rest::binary>> <- entries do
      {:ok, hostname, _} = UE2.decode_string(rest)
      {{a, b, c, d}, port, query_port, hostname}
    end
  end

  test "a server is listed by its heartbeats, for as long as its connection lasts" do
    port = start()
    s = uplink(port)
    write(s, heartbeat(7757))

    entry = eventually(fn -> lookup(7757) end)
    assert %{game: "ut2004", version: "3369", hostname: "exmaster test", query_port: 7758} = entry
    assert %{map: "DM-Rankin", gametype: "xDeathMatch", clients: 0, max_clients: 16} = entry

    assert list(port) == [{@localhost, 7757, 7758, "exmaster test"}]

    :gen_tcp.close(s)
    assert eventually(fn -> lookup(7757) == nil end)
  end

  test "lists, filtered as UT2004's browser and qstat ask" do
    port = start()
    a = uplink(port)
    b = uplink(port)
    write(a, heartbeat(7757))
    write(b, heartbeat(7767, gametype: "xCTFGame", players: 3, hostname: "ctf"))
    eventually(fn -> lookup(7757) && lookup(7767) end)

    assert [{_, 7757, _, _}, {_, 7767, _, "ctf"}] = list(port)
    assert [{_, 7767, _, _}] = list(port, [{"gametype", "xCTFGame", 0}])
    assert [{_, 7767, _, _}] = list(port, [{"currentplayers", "0", 4}])
    assert [{_, 7757, _, _}] = list(port, [{"mutator", "DMMutator", 0}, {"hostname", "CTF", 1}])
    assert [] = list(port, [{"mutator", "DMMutator", 4}])
  end

  test "the message of the day is empty" do
    port = start()
    s = ask(port, <<1>>)
    assert read(s) == <<1, 0, 0::32>>
    assert :gen_tcp.recv(s, 0, 2_000) == {:error, :closed}
  end

  test "other games are denied" do
    port = start()
    s = connect(port)
    challenge(s)
    write(s, hello("KFSERVER", 1000))
    assert read(s) == <<7, "DENIED", 0>>
    assert :gen_tcp.recv(s, 0, 2_000) == {:error, :closed}
  end

  test "heartbeats inside the gap wait for its end, and the last of them is stored" do
    port = start(gap: 300)
    s = uplink(port)
    write(s, heartbeat(7757))
    assert eventually(fn -> lookup(7757) end).map == "DM-Rankin"

    write(s, heartbeat(7757, map: "DM-Antalus"))
    write(s, heartbeat(7757, map: "DM-Asbestos"))
    Process.sleep(100)
    assert lookup(7757).map == "DM-Rankin"
    assert eventually(fn -> lookup(7757).map == "DM-Asbestos" end)
  end

  test "a heartbeat counts from when it came, however long the connection was quiet" do
    port = start(gap: 0, idle: 1_000)
    s = uplink(port)
    write(s, heartbeat(7757))
    assert eventually(fn -> lookup(7757) end)

    Process.sleep(600)
    sent = Exmaster.now()
    write(s, heartbeat(7757, hostname: "later"))
    entry = eventually(fn -> (e = lookup(7757)) && e.hostname == "later" && e end)
    assert entry.seen >= sent
    assert entry.expires >= sent + 1_000
  end

  test "a server that stops heartbeating is dropped and its connection closed" do
    port = start(idle: 300)
    s = uplink(port)
    write(s, heartbeat(7757))
    assert eventually(fn -> lookup(7757) end)

    capture_log(fn ->
      assert eventually(fn -> lookup(7757) == nil end)
      assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
    end)
  end

  test "a server that moves to another port leaves the old one" do
    port = start(gap: 0)
    s = uplink(port)
    write(s, heartbeat(7757))
    assert eventually(fn -> lookup(7757) end)

    capture_log(fn ->
      write(s, heartbeat(7767))
      assert eventually(fn -> lookup(7767) && lookup(7757) == nil end)
    end)
  end

  test "a server that reconnects is listed through its new connection; the old one closing leaves it" do
    port = start()
    old = uplink(port)
    write(old, heartbeat(7757))
    assert eventually(fn -> lookup(7757) end)

    new = uplink(port)
    write(new, heartbeat(7757, hostname: "again"))
    assert eventually(fn -> lookup(7757).hostname == "again" end)

    :gen_tcp.close(old)
    Process.sleep(100)
    assert lookup(7757).hostname == "again"
  end

  test "a late heartbeat from a server's old connection leaves it to the new one" do
    port = start(gap: 0)
    old = uplink(port)
    write(old, heartbeat(7757, hostname: "old"))
    assert eventually(fn -> lookup(7757) end)

    new = uplink(port)
    write(new, heartbeat(7757, hostname: "new"))
    assert eventually(fn -> lookup(7757).hostname == "new" end)

    write(old, heartbeat(7757, hostname: "old, late"))
    Process.sleep(100)
    assert lookup(7757).hostname == "new"

    :gen_tcp.close(old)
    Process.sleep(100)
    assert lookup(7757).hostname == "new"
  end

  test "frames that list nothing don't keep a server's connection open" do
    port = start(idle: 400)
    s = uplink(port)

    # A heartbeat that doesn't parse and a stats frame, every 100 ms; the
    # sends fail once the master has closed.
    for _ <- 1..8 do
      :gen_tcp.send(s, [UE2.frame(<<1, 0xFF>>), UE2.frame(<<2, 1, 0>>)])
      Process.sleep(100)
    end

    assert {:error, reason} = :gen_tcp.recv(s, 0, 100)
    assert reason in [:closed, :econnreset]
  end

  test "a connection lasts its lifetime from when it opened, but for a server's past its handshake" do
    port = start(lifetime: 400, gap: 0)
    opened = Exmaster.now()
    s = connect(port)
    challenge(s)
    Process.sleep(250)
    write(s, hello("UT2K4CLIENT") <> <<0::32, 0::32, 0::32, 0>>)
    assert {:ok, _} = :gen_tcp.recv(s, 18, 1_000)
    assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
    assert Exmaster.now() - opened < 600

    u = uplink(port)
    write(u, heartbeat(7757))
    Process.sleep(600)
    assert lookup(7757)
    write(u, heartbeat(7757, hostname: "still"))
    assert eventually(fn -> lookup(7757).hostname == "still" end)
  end

  test "servers have slots of their own, and clients keep theirs" do
    port = start(max_uplinks: 1, max_others: 2)
    a = uplink(port)

    # A second server is closed at the end of its handshake, before the
    # ports.
    b = connect(port)
    challenge(b)
    write(b, hello("UT2K4SERVER") <> <<-1::little-32, 0>>)
    assert read(b) == <<9, "APPROVED", 0>>
    write(b, <<0::32, 0::32>>)
    assert :gen_tcp.recv(b, 0, 1_000) == {:error, :closed}

    # The server's slot isn't a client's: two can still connect, not three.
    c1 = connect(port)
    c2 = connect(port)
    challenge(c1)
    challenge(c2)
    c3 = connect(port)
    assert :gen_tcp.recv(c3, 0, 1_000) == {:error, :closed}

    :gen_tcp.close(c1)
    :gen_tcp.close(c2)
    Process.sleep(50)
    write(a, heartbeat(7757))
    assert eventually(fn -> lookup(7757) end)
    assert list(port) == [{@localhost, 7757, 7758, "exmaster test"}]
  end

  # 4,000 servers with long names come to about 1.2 MB, more than the
  # reply budget's burst.
  test "a list larger than the reply budget's burst still goes out" do
    port = start()
    now = Exmaster.now()
    name = String.duplicate("n", 127)

    for i <- 0..3_999 do
      ip = {198, 51, div(i, 32), rem(i, 32) + 1}

      entry = %{
        game: "ut2004",
        query_port: 7758,
        hostname: name,
        map: name,
        gametype: "xDeathMatch",
        skill: "0",
        clients: 0,
        max_clients: 16,
        flags: 0,
        filters: %{},
        mutators: [],
        via: self(),
        conn: 0,
        seen: now,
        expires: now + 60_000
      }

      :ok = Store.put(@store, {ip, 7757}, entry, now, nil)
    end

    assert length(list(port)) == 4_000
  end

  test "frames over 32 KB close the connection; a heartbeat in the hello's place is denied" do
    port = start()
    s = uplink(port)
    :ok = :gen_tcp.send(s, <<32_769::little-32>>)
    assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}

    s = connect(port)
    challenge(s)
    write(s, heartbeat(7757))
    assert read(s) == <<7, "DENIED", 0>>
    assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
    assert lookup(7757) == nil
  end

  test "an IP has max_per_ip connections and 8 more" do
    port = start(max_per_ip: 1)
    open = for _ <- 1..9, do: connect(port)
    for s <- open, do: challenge(s)

    s = connect(port)
    assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}

    # A slot frees as a connection closes; the connect limit is apart.
    :gen_tcp.close(hd(open))
    Process.sleep(50)
    RateLimit.clear()
    challenge(connect(port))
  end

  test "an IP gets five lists at once, then one every 3 seconds" do
    port = start()
    for _ <- 1..5, do: assert(list(port) == [])

    s = ask(port, <<0, 0>>)
    assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
  end

  test "a peer that resets at once leaves no error" do
    port = start()

    log =
      capture_log(fn ->
        for _ <- 1..3 do
          {:ok, s} =
            :gen_tcp.connect(@localhost, port, [:binary, active: false, linger: {true, 0}])

          :gen_tcp.close(s)
        end

        Process.sleep(200)
      end)

    refute log =~ "terminating"
  end
end
