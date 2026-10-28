defmodule Exmaster.GS.ListServerTest do
  @moduledoc "The GameSpy list server over real sockets."
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Exmaster.{GS, RateLimit, Store}
  alias Exmaster.GS.{Enctype2, ListServer}

  @localhost {127, 0, 0, 1}
  @a {{198, 51, 100, 1}, 23_000}
  @b {{198, 51, 100, 2}, 23_001}

  setup do
    Store.clear(:exmaster_gs)
    RateLimit.clear()
    now = Exmaster.now()

    for {addr, game} <- [{@b, "bfield1942"}, {@a, "bfield1942"}, {{{198, 51, 100, 3}, 1}, "x"}] do
      :ok =
        Store.put(
          :exmaster_gs,
          addr,
          %{game: game, clients: 0, seen: now, expires: now + 60_000},
          now,
          nil
        )
    end

    pid = start_supervised!({ListServer, ip: @localhost, port: 0})
    {:ok, port: ListServer.port(pid)}
  end

  defp connect(port) do
    {:ok, s} = :gen_tcp.connect(@localhost, port, [:binary, active: false])
    s
  end

  # Asks as Battlefield 1942 does, in pieces, and reads to the close.
  defp ask(port, enctype, list \\ "cmp", game \\ "bfield1942") do
    s = connect(port)
    {:ok, "\\basic\\\\secure\\" <> challenge} = :gen_tcp.recv(s, 0, 1_000)
    assert challenge =~ ~r/\A[A-Z]{6}\z/

    hello =
      "\\gamename\\#{game}\\gamever\\2\\location\\0\\validate\\#{GS.validate(challenge, "HpWx9z")}"

    :ok = :gen_tcp.send(s, hello <> "\\enctype\\#{enctype}\\final\\\\queryid\\1.1\\")
    :ok = :gen_tcp.send(s, "\\list\\#{list}\\gamename\\")
    Process.sleep(20)
    :ok = :gen_tcp.send(s, "bfield1942\\final\\")
    read_all(s, "")
  end

  defp read_all(s, acc) do
    case :gen_tcp.recv(s, 0, 2_000) do
      {:ok, data} -> read_all(s, acc <> data)
      {:error, :closed} -> acc
    end
  end

  test "Battlefield 1942's request: cmp, enctype 2", %{port: port} do
    {:ok, list} = Enctype2.decode(ask(port, 2), "HpWx9z")
    assert list == GS.encode_list([@a, @b])
  end

  test "enctype 0, and text", %{port: port} do
    assert ask(port, 0) == GS.encode_list([@a, @b]) <> "\\final\\"
    assert ask(port, 0, "") == "\\ip\\198.51.100.1:23000\\ip\\198.51.100.2:23001\\final\\"
  end

  test "encrypting takes the asking game's key", %{port: port} do
    assert ask(port, 2, "cmp", "bfvietnam") == ""
  end

  test "qstat's request, as GameSpy Arcade, no encryption, text", %{port: port} do
    s = connect(port)
    {:ok, "\\basic\\\\secure\\" <> _} = :gen_tcp.recv(s, 0, 1_000)

    :ok =
      :gen_tcp.send(
        s,
        "\\gamename\\gamespy2\\gamever\\020109017\\location\\5\\validate\\12345678\\final\\" <>
          "\\list\\\\gamename\\bfield1942\\final\\"
      )

    assert read_all(s, "") == "\\ip\\198.51.100.1:23000\\ip\\198.51.100.2:23001\\final\\"
  end

  test "an IP gets five connections at once, then one every 3 seconds", %{port: port} do
    for _ <- 1..5, do: assert(ask(port, 0) != "")
    s = connect(port)
    assert :gen_tcp.recv(s, 0, 1_000) == {:error, :closed}
  end

  test "a client that resets at once leaves no error", %{port: port} do
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

  test "a request over 2 KB gets nothing, however it arrives", %{port: port} do
    s = connect(port)
    {:ok, _} = :gen_tcp.recv(s, 0, 1_000)
    padding = String.duplicate("x", 2_300)
    :ok = :gen_tcp.send(s, "\\gamename\\bfield1942\\pad\\" <> binary_part(padding, 0, 1_300))
    Process.sleep(20)

    :ok =
      :gen_tcp.send(
        s,
        binary_part(padding, 1_300, 1_000) <>
          "\\enctype\\0\\final\\\\list\\cmp\\gamename\\bfield1942\\final\\"
      )

    assert read_all(s, "") == ""
  end

  test "no list when the reply budget is spent", %{port: port} do
    # Spent a minute ahead, so it doesn't refill while the client asks.
    :ok =
      RateLimit.take(:replies, {262_144, 1_000, 1_048_576}, 1_048_576, Exmaster.now() + 60_000)

    assert ask(port, 2) == ""
  end
end
