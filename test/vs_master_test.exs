defmodule Exmaster.VS.MasterTest do
  @moduledoc "The Vintage Story master over real sockets, as the game's server and client speak to it."
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Exmaster.{RateLimit, Store}
  alias Exmaster.VS.Master

  @localhost {127, 0, 0, 1}
  @store :exmaster_vs

  setup do
    Store.clear(@store)
    RateLimit.clear()
    :ok
  end

  defp start(opts \\ []) do
    pid = start_supervised!({Master, [ip: @localhost, port: 0] ++ opts})
    Master.port(pid)
  end

  # A game server's port: something that takes connections.
  defp game_port do
    {:ok, l} = :gen_tcp.listen(0, [:binary, ip: @localhost, active: false])
    {:ok, port} = :inet.port(l)
    {l, port}
  end

  # A request as .NET's HttpClient sends it, and the reply: {status, body}.
  defp request(port, method, path, body \\ nil, headers \\ []) do
    {:ok, s} = :gen_tcp.connect(@localhost, port, [:binary, active: false])

    head =
      [
        "#{method} #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n",
        if(body, do: "Content-Type: application/json; charset=utf-8\r\n", else: ""),
        if(body, do: "Content-Length: #{byte_size(body)}\r\n", else: ""),
        Enum.map(headers, &"#{&1}\r\n"),
        "\r\n"
      ]

    :ok = :gen_tcp.send(s, [head, body || ""])
    reply = read_all(s, "")
    :gen_tcp.close(s)
    ["HTTP/1.1 " <> <<status::binary-3>> <> _ | _] = String.split(reply, "\r\n")
    [head, body] = String.split(reply, "\r\n\r\n", parts: 2)
    assert head =~ "Content-Length: #{byte_size(body)}\r\n"
    {String.to_integer(status), body}
  end

  defp read_all(s, acc) do
    case :gen_tcp.recv(s, 0, 5_000) do
      {:ok, data} -> read_all(s, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp post(port, endpoint, json) do
    {200, body} = request(port, "POST", "/api/v1/servers/#{endpoint}", JSON.encode!(json))
    JSON.decode!(body)
  end

  defp list(port) do
    {200, body} = request(port, "GET", "/api/v1/servers/list")
    %{"status" => "ok", "data" => data} = JSON.decode!(body)
    data
  end

  # What 1.22.7's server posts, with LinuxGSM's settings.
  defp registration(port, opts \\ []) do
    Map.merge(
      %{
        "port" => port,
        "name" => "exmaster test",
        "icon" => "",
        "playstyle" => %{"id" => "surviveandbuild", "langCode" => "preset-surviveandbuild"},
        "maxPlayers" => 16,
        "gameVersion" => "1.22.7",
        "hasPassword" => false,
        "Mods" => [%{"id" => "game", "version" => "1.22.7"}],
        "serverUrl" => nil,
        "gameDescription" => nil,
        "whitelisted" => true,
        "vhIdentifier" => nil
      },
      Map.new(opts)
    )
  end

  test "a server registers, heartbeats and is listed as the game's client reads it" do
    port = start()
    {_l, game} = game_port()

    capture_log(fn ->
      assert %{"status" => "ok", "data" => token} = post(port, "register", registration(game))
      assert token == Integer.to_string(game)

      assert [entry] = list(port)

      assert entry == %{
               "serverName" => "exmaster test",
               "serverIP" => "127.0.0.1:#{game}",
               "playstyle" => %{
                 "id" => "surviveandbuild",
                 "langCode" => "preset-surviveandbuild"
               },
               "mods" => [%{"id" => "game", "version" => "1.22.7"}],
               "maxPlayers" => 16,
               "players" => 0,
               "gameVersion" => "1.22.7",
               "hasPassword" => false,
               "whitelisted" => true,
               "gameDescription" => ""
             }

      assert post(port, "heartbeat", %{"token" => token, "players" => 3}) ==
               %{"status" => "ok", "data" => nil}

      assert [%{"players" => 3}] = list(port)

      # Registering again, as the game does after `invalid` or when its
      # settings change, keeps the players.
      assert %{"status" => "ok"} = post(port, "register", registration(game, name: "renamed"))
      assert [%{"serverName" => "renamed", "players" => 3}] = list(port)

      assert [%{game: "vintagestory", clients: 3, max_clients: 16, version: "1.22.7"}] =
               Exmaster.servers(:vs)
    end)
  end

  test "a port that doesn't take connections isn't listed" do
    port = start()
    {l, game} = game_port()
    :gen_tcp.close(l)

    assert %{"status" => "error", "data" => reason} = post(port, "register", registration(game))
    assert reason =~ "doesn't take connections"
    assert list(port) == []
  end

  test "a heartbeat for a server that isn't listed gets invalid, and the game registers again" do
    port = start(ttl: 200)
    {_l, game} = game_port()

    capture_log(fn ->
      assert %{"status" => "invalid"} = post(port, "heartbeat", %{"token" => "#{game}"})
      assert %{"status" => "ok"} = post(port, "register", registration(game))
      Process.sleep(250)
      assert list(port) == []
      assert %{"status" => "invalid"} = post(port, "heartbeat", %{"token" => "#{game}"})
    end)

    assert %{"status" => "error"} = post(port, "heartbeat", %{"token" => "x"})
    assert %{"status" => "error"} = post(port, "heartbeat", %{"token" => nil})
  end

  test "registrations that don't parse" do
    port = start()
    assert %{"status" => "error"} = post(port, "register", %{"name" => "no port"})
    assert %{"status" => "error"} = post(port, "register", registration(0))
    assert %{"status" => "error"} = post(port, "register", registration("42420"))
    assert %{"status" => "error"} = post(port, "register", [1])
    assert {200, body} = request(port, "POST", "/register", "{")
    assert %{"status" => "error", "data" => "not JSON"} = JSON.decode!(body)
  end

  test "an unregistration without a token checks every server at the IP" do
    port = start(unregister_wait: 100)
    {stopped, a} = game_port()
    {_l, b} = game_port()

    capture_log(fn ->
      assert %{"status" => "ok"} = post(port, "register", registration(a))
      assert %{"status" => "ok"} = post(port, "register", registration(b))
      :gen_tcp.close(stopped)

      # As the game sends it: it has cleared its token.
      assert post(port, "unregister", %{"token" => nil}) == %{"status" => "ok", "data" => nil}
      assert length(list(port)) == 2
      Process.sleep(300)
      assert [%{"serverIP" => ip}] = list(port)
      assert ip == "127.0.0.1:#{b}"
    end)
  end

  test "a server that heartbeats after the unregistration is kept" do
    port = start(unregister_wait: 200)
    {l, game} = game_port()

    capture_log(fn ->
      assert %{"status" => "ok"} = post(port, "register", registration(game))
      :gen_tcp.close(l)
      assert %{"status" => "ok"} = post(port, "unregister", %{"token" => nil})
      Process.sleep(10)
      assert %{"status" => "ok"} = post(port, "heartbeat", %{"token" => "#{game}"})
      Process.sleep(400)
      assert [_] = list(port)
    end)
  end

  test "an unregistration with a token checks that server only" do
    port = start(unregister_wait: 50)
    {la, a} = game_port()
    {lb, b} = game_port()

    capture_log(fn ->
      assert %{"status" => "ok"} = post(port, "register", registration(a))
      assert %{"status" => "ok"} = post(port, "register", registration(b))
      :gen_tcp.close(la)
      :gen_tcp.close(lb)
      assert %{"status" => "ok"} = post(port, "unregister", %{"token" => "#{a}"})
      Process.sleep(200)
      assert [%{"serverIP" => ip}] = list(port)
      assert ip == "127.0.0.1:#{b}"
    end)
  end

  test "any path prefix, and HTTP the master doesn't serve" do
    port = start()
    assert {200, ~s({"status":"ok","data":[]})} = request(port, "GET", "/list")
    assert {200, _} = request(port, "GET", "/a/b/list?x=1")
    assert {404, _} = request(port, "GET", "/api/v1/servers/")
    assert {404, _} = request(port, "GET", "/api/v1/servers/lists")
    assert {405, _} = request(port, "GET", "/register")
    assert {405, _} = request(port, "POST", "/list", "{}")
    assert {413, _} = request(port, "POST", "/register", String.duplicate(" ", 70_000))

    assert {411, _} =
             request(port, "POST", "/register", nil, ["Transfer-Encoding: chunked"])

    assert {400, _} = request(port, "GET", "http://127.0.0.1/list")
    assert {431, _} = request(port, "GET", "/list", nil, for(i <- 1..70, do: "X-#{i}: 1"))
  end

  test "lists per IP: 5 at once, then one every 3 seconds" do
    port = start()
    for _ <- 1..5, do: assert({200, _} = request(port, "GET", "/list"))
    assert {429, _} = request(port, "GET", "/list")
  end

  test "a connection that sends nothing is closed" do
    port = start(lifetime: 200)
    {:ok, s} = :gen_tcp.connect(@localhost, port, [:binary, active: false])
    assert {:error, :closed} = :gen_tcp.recv(s, 0, 2_000)
  end
end
