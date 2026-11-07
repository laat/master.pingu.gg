defmodule Exmaster.VSTest do
  use ExUnit.Case, async: true

  alias Exmaster.VS

  test "the endpoint is the path's last segment" do
    assert VS.endpoint("/api/v1/servers/register") == "register"
    assert VS.endpoint("/list?x=/y") == "list"
    assert VS.endpoint("/") == ""
  end

  test "a registration's fields are cut and defaulted" do
    body =
      JSON.encode!(%{
        "port" => 42420,
        "name" => String.duplicate("é", 100),
        "playstyle" => "not an object",
        "maxPlayers" => 70_000,
        "Mods" => List.duplicate(%{"id" => "a", "version" => 1}, 600) ++ ["x"],
        "hasPassword" => "yes"
      })

    assert {:ok, r} = VS.parse_register(body)
    assert r.port == 42420
    # 128 bytes, cut at a character.
    assert r.name == String.duplicate("é", 64)
    assert r.playstyle == %{id: "", lang_code: ""}
    assert r.max_players == 65_535
    assert length(r.mods) == 512
    assert hd(r.mods) == %{id: "a", version: ""}
    assert r.has_password == false
    assert r.description == ""
  end

  test "an entry has everything the client reads, never null" do
    {:ok, r} = VS.parse_register(~s({"port": 42420}))
    entry = JSON.decode!(VS.encode_entry({{203, 0, 113, 1}, 42420}, r, 2))

    assert entry == %{
             "serverName" => "",
             "serverIP" => "203.0.113.1:42420",
             "playstyle" => %{"id" => "", "langCode" => ""},
             "mods" => [],
             "maxPlayers" => 0,
             "players" => 2,
             "gameVersion" => "",
             "hasPassword" => false,
             "whitelisted" => false,
             "gameDescription" => ""
           }
  end

  test "the list" do
    decode = &(&1 |> VS.list() |> IO.iodata_to_binary() |> JSON.decode!())
    assert decode.([]) == %{"status" => "ok", "data" => []}

    assert decode.([~s({"a":1}), ~s({"b":2})]) == %{
             "status" => "ok",
             "data" => [%{"a" => 1}, %{"b" => 2}]
           }
  end

  test "heartbeats and unregistrations" do
    assert VS.parse_heartbeat(~s({"token":"42420","players":3})) ==
             {:ok, %{port: 42420, players: 3}}

    assert VS.parse_heartbeat(~s({"token":"42420"})) == {:ok, %{port: 42420, players: 0}}
    assert {:error, _} = VS.parse_heartbeat(~s({"token":"0"}))
    assert {:error, _} = VS.parse_heartbeat(~s({"token":42420}))
    assert {:error, _} = VS.parse_heartbeat(~s([]))
    assert VS.parse_unregister(~s({"token":null})) == {:ok, nil}
    assert VS.parse_unregister(~s({"token":"42420"})) == {:ok, 42420}
    assert {:error, _} = VS.parse_unregister(~s({"token":"x"}))
    assert {:error, _} = VS.parse_unregister("")
  end
end
