defmodule Exmaster.SB.ListServerTest do
  @moduledoc "GameSpy's server browsing over real sockets, asked as the SDK asks."
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Exmaster.{RateLimit, SB, Store}
  alias Exmaster.SB.{Crypt, ListServer}

  @localhost {127, 0, 0, 1}
  @a {{198, 51, 100, 1}, 23_000}
  @b {{198, 51, 100, 2}, 23_100}

  setup do
    Store.clear(:exmaster_qr2)
    RateLimit.clear()
    now = Exmaster.now()

    for {addr, name} <- [{@b, "two"}, {@a, "one"}] do
      entry = %{
        game: "bfvietnam",
        clients: 0,
        fields: %{"hostname" => name},
        local_ip: nil,
        local_port: nil,
        seen: now,
        expires: now + 60_000
      }

      :ok = Store.put(:exmaster_qr2, addr, entry, now, nil)
    end

    pid = start_supervised!({ListServer, ip: @localhost, port: 0})
    {:ok, port: ListServer.port(pid)}
  end

  defp request(game, from, fields, options \\ 0, extra \\ "") do
    body =
      <<0, 1, 3, 0::32, game::binary, 0, from::binary, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0,
        fields::binary, 0, options::32, extra::binary>>

    <<byte_size(body) + 2::16, body::binary>>
  end

  # Sends the request in two pieces, reads to the close, and decrypts it
  # as the SDK does: the header, the key from it, the rest.
  defp ask(port, request, key) do
    {:ok, s} = :gen_tcp.connect(@localhost, port, [:binary, active: false])
    {first, rest} = String.split_at(request, 5)
    # A refused connection is closed under the client: its sends fail.
    :gen_tcp.send(s, first)
    Process.sleep(20)
    :gen_tcp.send(s, rest)
    data = read_all(s, "")

    case data do
      <<n, _::binary-size(Bitwise.bxor(n, 0xEC)), m, rest::binary>> ->
        size = Bitwise.bxor(m, 0xEA)
        <<server_challenge::binary-size(^size), cipher::binary>> = rest
        state = Crypt.init(SB.mix(<<1, 2, 3, 4, 5, 6, 7, 8>>, server_challenge, key))
        {plain, _} = Crypt.decrypt(state, cipher)
        plain

      other ->
        {:raw, other}
    end
  end

  defp read_all(s, acc) do
    case :gen_tcp.recv(s, 0, 2_000) do
      {:ok, data} -> read_all(s, acc <> data)
      {:error, reason} when reason in [:closed, :econnreset] -> acc
    end
  end

  test "Battlefield Vietnam's request: its list, as the game asks", %{port: port} do
    assert ask(port, request("bfvietnam", "bfvietnam", "\\hostname"), "h2P9dJ") ==
             <<127, 0, 0, 1, 23_000::16, 1, 0, "hostname", 0, 0>> <>
               <<64, 198, 51, 100, 1, 0xFF, "one", 0>> <>
               <<64 + 16, 198, 51, 100, 2, 23_100::16, 0xFF, "two", 0>> <>
               <<0, 0xFF, 0xFF, 0xFF, 0xFF>>
  end

  test "another game asking, under its key; at most n; no list", %{port: port} do
    assert <<127, 0, 0, 1, 23_000::16, 0, 0, 64, 198, 51, 100, 1, 0, 0xFF, 0xFF, 0xFF, 0xFF>> =
             ask(port, request("bfvietnam", "gslive", "", 128, <<1::little-32>>), "Xn221z")

    assert ask(port, request("bfvietnam", "gslive", "", 2), "Xn221z") ==
             <<127, 0, 0, 1, 23_000::16>>
  end

  test "a game it doesn't list, and a game asking that it doesn't know", %{port: port} do
    assert ask(port, request("nosuchgame", "bfvietnam", ""), "h2P9dJ") ==
             <<127, 0, 0, 1, 0xFF, 0xFF, "This master doesn't list nosuchgame.", 0>>

    assert ask(port, request("bfvietnam", "nosuchgame", ""), "x") == {:raw, ""}
  end

  test "requests over 1 KB, or that aren't lists, get nothing", %{port: port} do
    big = request("bfvietnam", "bfvietnam", String.duplicate("\\x", 600))
    assert byte_size(big) > 1_024
    assert ask(port, big, "h2P9dJ") == {:raw, ""}
    assert ask(port, <<9::16, 1, 198, 51, 100, 1, 23_000::16>>, "h2P9dJ") == {:raw, ""}
  end

  test "an IP gets five connections at once, then one every 3 seconds", %{port: port} do
    for _ <- 1..5,
        do: assert(is_binary(ask(port, request("bfvietnam", "bfvietnam", ""), "h2P9dJ")))

    assert ask(port, request("bfvietnam", "bfvietnam", ""), "h2P9dJ") == {:raw, ""}
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
end
