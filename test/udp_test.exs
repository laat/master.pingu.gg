defmodule Exmaster.UDPTest do
  @moduledoc "The masters over real sockets, through Exmaster.Listener."
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Exmaster.{Listener, RateLimit, Store}
  import Exmaster.TestHelpers

  @localhost {127, 0, 0, 1}

  setup do
    for s <- [:exmaster_q3, :exmaster_q2, :exmaster_qw, :exmaster_gs], do: Store.clear(s)
    RateLimit.clear()
    :ok
  end

  defp listen(protocol, opts \\ []) do
    pid =
      start_supervised!({Listener, [protocol: protocol, ip: @localhost, port: 0] ++ opts},
        id: make_ref()
      )

    Listener.port(pid)
  end

  defp socket do
    {:ok, s} = :gen_udp.open(0, [:binary, active: false, ip: @localhost])
    s
  end

  defp recv(s) do
    {:ok, {_, _, data}} = :gen_udp.recv(s, 0, 1_000)
    data
  end

  defp port_of(s) do
    {:ok, p} = :inet.port(s)
    p
  end

  test "Quake 3: heartbeat, getinfo, infoResponse, getservers" do
    port = listen(Exmaster.Q3.Master)
    server = socket()
    client = socket()

    :ok = :gen_udp.send(server, @localhost, port, "\xFF\xFF\xFF\xFFheartbeat QuakeArena-1\n")
    "\xFF\xFF\xFF\xFFgetinfo " <> challenge = recv(server)

    info =
      infostring(%{
        "challenge" => challenge,
        "protocol" => "68",
        "sv_maxclients" => "8",
        "clients" => "1"
      })

    :ok = :gen_udp.send(server, @localhost, port, "\xFF\xFF\xFF\xFFinfoResponse\n" <> info)

    # The store is written by another process; wait for it.
    wait_until(fn -> Store.all(:exmaster_q3, Exmaster.now()) != [] end)
    :ok = :gen_udp.send(client, @localhost, port, "\xFF\xFF\xFF\xFFgetservers 68")
    assert decode_q3_lists([recv(client)]) == [{@localhost, port_of(server)}]
  end

  test "Quake 3 on a dual-stack socket sees IPv4 clients as IPv4" do
    pid =
      start_supervised!({Listener, protocol: Exmaster.Q3.Master, port: 0}, id: make_ref())

    port = Listener.port(pid)
    server = socket()
    :ok = :gen_udp.send(server, @localhost, port, "\xFF\xFF\xFF\xFFheartbeat QuakeArena-1\n")
    "\xFF\xFF\xFF\xFFgetinfo " <> challenge = recv(server)

    info =
      infostring(%{
        "challenge" => challenge,
        "protocol" => "68",
        "sv_maxclients" => "8",
        "clients" => "1"
      })

    :ok = :gen_udp.send(server, @localhost, port, "\xFF\xFF\xFF\xFFinfoResponse\n" <> info)

    wait_until(fn ->
      Store.lookup(:exmaster_q3, {@localhost, port_of(server)}, Exmaster.now())
    end)
  end

  test "Quake 2: heartbeat, status, print, query" do
    port = listen(Exmaster.Q2.Master)
    server = socket()
    client = socket()

    :ok = :gen_udp.send(server, @localhost, port, "\xFF\xFF\xFF\xFFheartbeat\n\\hostname\\x\n")
    assert recv(server) == "\xFF\xFF\xFF\xFFstatus\n"

    :ok =
      :gen_udp.send(
        server,
        @localhost,
        port,
        "\xFF\xFF\xFF\xFFprint\n\\hostname\\x\\maxclients\\8\n"
      )

    wait_until(fn -> Store.all(:exmaster_q2, Exmaster.now()) != [] end)

    :ok = :gen_udp.send(client, @localhost, port, "query\n")
    assert decode_ipv4_lists([recv(client)], "servers ") == [{@localhost, port_of(server)}]
  end

  test "Quake 2 and GameSpy on one socket, and the All-Seeing Eye's heartbeat dropped" do
    port = listen(Exmaster.Q2GS)
    q2 = socket()
    gs = socket()
    client = socket()

    :ok = :gen_udp.send(gs, @localhost, port, "\\hb\\14690\\bf1942")

    :ok =
      :gen_udp.send(gs, @localhost, port, "\\heartbeat\\#{port_of(gs)}\\gamename\\bfield1942")

    # Nothing for the All-Seeing Eye's: the first reply is the challenge.
    "\\info\\\\secure\\" <> challenge = recv(gs)

    :ok =
      :gen_udp.send(
        gs,
        @localhost,
        port,
        "\\hostname\\x\\maxplayers\\16\\numplayers\\0" <>
          "\\validate\\#{Exmaster.GS.validate(challenge, "HpWx9z")}\\final\\\\queryid\\2.1"
      )

    :ok = :gen_udp.send(q2, @localhost, port, "\xFF\xFF\xFF\xFFheartbeat\n\\hostname\\x\n")
    assert recv(q2) == "\xFF\xFF\xFF\xFFstatus\n"

    :ok =
      :gen_udp.send(q2, @localhost, port, "\xFF\xFF\xFF\xFFprint\n\\hostname\\x\\maxclients\\8\n")

    wait_until(fn ->
      Store.all(:exmaster_q2, Exmaster.now()) != [] and
        Store.all(:exmaster_gs, Exmaster.now()) != []
    end)

    # Each master lists only its own.
    assert [{{@localhost, q2_port}, _}] = Store.all(:exmaster_q2, Exmaster.now())
    assert q2_port == port_of(q2)

    assert [{{@localhost, gs_port}, %{game: "bfield1942"}}] =
             Store.all(:exmaster_gs, Exmaster.now())

    assert gs_port == port_of(gs)

    :ok = :gen_udp.send(client, @localhost, port, "query\n")
    assert decode_ipv4_lists([recv(client)], "servers ") == [{@localhost, port_of(q2)}]
    assert {:error, :timeout} = :gen_udp.recv(gs, 0, 100)
  end

  test "QuakeWorld: heartbeat, status, reply, c" do
    port = listen(Exmaster.QW.Master)
    server = socket()
    client = socket()

    :ok = :gen_udp.send(server, @localhost, port, "a\n1\n0\n")
    assert recv(server) == "\xFF\xFF\xFF\xFFstatus\n"

    :ok =
      :gen_udp.send(server, @localhost, port, "\xFF\xFF\xFF\xFFn\\hostname\\x\\maxclients\\8\n")

    wait_until(fn -> Store.all(:exmaster_qw, Exmaster.now()) != [] end)

    :ok = :gen_udp.send(client, @localhost, port, "c\n")
    assert decode_ipv4_lists([recv(client)], "d\n") == [{@localhost, port_of(server)}]
  end

  defmodule Crashy do
    @behaviour Exmaster.Protocol
    def name, do: "Crashy"
    def family, do: :inet
    def store, do: :exmaster_q3
    def init(_), do: nil
    def handle_packet("boom", _, _, _, _), do: raise("boom")
    def handle_packet(data, from, _, _, state), do: {[{data, from}], state}
    def tick(_, _, state), do: {[], state}
  end

  test "a packet that makes the protocol raise is dropped, and the listener stays up" do
    port = listen(Crashy)
    s = socket()

    log =
      capture_log(fn ->
        :ok = :gen_udp.send(s, @localhost, port, "boom")
        :ok = :gen_udp.send(s, @localhost, port, "echo")
        assert recv(s) == "echo"
      end)

    assert log =~ "boom"
  end

  defp wait_until(f, tries \\ 100) do
    cond do
      f.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(10) && wait_until(f, tries - 1)
    end
  end
end
