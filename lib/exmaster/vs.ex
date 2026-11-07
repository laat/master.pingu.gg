defmodule Exmaster.VS do
  @moduledoc """
  The JSON Vintage Story's master speaks over HTTP: what servers post to
  `register`, `heartbeat` and `unregister`, the replies, and the list
  clients get from `list`. `Exmaster.VS.Master` runs it; see
  `docs/vintagestory.md`.

  Every reply is `{"status": ..., "data": ...}`. A registration's `data`
  is the token the server heartbeats with; here it is the server's port,
  since the master knows its IP from the connection.
  """

  # What a server says about itself is copied to every list and to the
  # other nodes, so it is kept small. The game's own longest are a few
  # hundred mods, of 30 characters or so each.
  @name_bytes 128
  @description_bytes 1_024
  @short_bytes 64
  @max_mods 512

  @doc "The endpoint a request path names: its last segment, without a query."
  def endpoint(path) do
    path |> String.split("?", parts: 2) |> hd() |> String.split("/") |> List.last()
  end

  @doc "A reply: `status` and `data`, a string or nil."
  def reply(status, data), do: JSON.encode!(%{"status" => status, "data" => data})

  @doc "The token a registration gets: the server's port."
  def token(port), do: Integer.to_string(port)

  @doc """
  A registration, as `{:ok, map}` with the fields a list entry is made
  of, or `{:error, reason}`. Strings are cut to their limits, and fields
  that are missing or of the wrong type are empty, but for the port.
  """
  def parse_register(body) do
    with {:ok, %{} = r} <- decode(body),
         port when port in 1..65_535//1 <- r["port"] do
      {:ok,
       %{
         port: port,
         name: string(r["name"], @name_bytes),
         playstyle: playstyle(r["playstyle"]),
         max_players: integer(r["maxPlayers"], 0..65_535),
         game_version: string(r["gameVersion"], @short_bytes),
         has_password: r["hasPassword"] == true,
         whitelisted: r["whitelisted"] == true,
         description: string(r["gameDescription"], @description_bytes),
         mods: mods(r["Mods"])
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "no port"}
    end
  end

  @doc "A heartbeat, as `{:ok, %{port: port, players: n}}` or `{:error, reason}`."
  def parse_heartbeat(body) do
    with {:ok, %{} = h} <- decode(body),
         {:ok, port} <- port(h["token"]) do
      {:ok, %{port: port, players: integer(h["players"], 0..65_535)}}
    else
      {:error, _} = error -> error
      _ -> {:error, "not an object"}
    end
  end

  @doc """
  An unregistration, as `{:ok, port}`, or `{:ok, nil}` without a token, as
  the game sends it: it clears its token before it sends it.
  """
  def parse_unregister(body) do
    case decode(body) do
      {:ok, %{"token" => token}} when is_binary(token) -> port(token)
      {:ok, %{}} -> {:ok, nil}
      {:ok, _} -> {:error, "not an object"}
      error -> error
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> {:error, "not JSON"}
    end
  end

  defp port(token) when is_binary(token) do
    case Integer.parse(token) do
      {port, ""} when port in 1..65_535 -> {:ok, port}
      _ -> {:error, "not a token"}
    end
  end

  defp port(_), do: {:error, "not a token"}

  defp playstyle(%{} = p),
    do: %{id: string(p["id"], @short_bytes), lang_code: string(p["langCode"], @short_bytes)}

  defp playstyle(_), do: %{id: "", lang_code: ""}

  defp mods(mods) when is_list(mods) do
    for %{} = m <- Enum.take(mods, @max_mods),
        do: %{id: string(m["id"], @short_bytes), version: string(m["version"], @short_bytes)}
  end

  defp mods(_), do: []

  defp string(s, max) when is_binary(s), do: cut(s, max)
  defp string(_, _), do: ""

  defp integer(n, min..max//1) when is_integer(n), do: n |> max(min) |> min(max)
  defp integer(_, min.._//1), do: min

  # At most max bytes of s, cut at a character.
  defp cut(s, max) when byte_size(s) <= max, do: s

  defp cut(s, max) do
    case :unicode.characters_to_binary(binary_part(s, 0, max)) do
      {:incomplete, s, _} -> s
      s -> s
    end
  end

  @doc """
  A server as the list has it, JSON, from its registration and its
  number of players, with the keys the official master's list has.
  `serverIP` is where clients connect; everything the client reads is
  there, never null.
  """
  def encode_entry({ip, port}, server, players) do
    JSON.encode!(%{
      "serverName" => server.name,
      "serverIP" => "#{:inet.ntoa(ip)}:#{port}",
      "playstyle" => %{"id" => server.playstyle.id, "langCode" => server.playstyle.lang_code},
      "mods" => Enum.map(server.mods, &%{"id" => &1.id, "version" => &1.version}),
      "maxPlayers" => server.max_players,
      "players" => players,
      "gameVersion" => server.game_version,
      "hasPassword" => server.has_password,
      "whitelisted" => server.whitelisted,
      "gameDescription" => server.description
    })
  end

  @doc "The list, from entries made by encode_entry/3, in parts of iodata."
  def list(entries) do
    rest = entries |> Enum.drop(1) |> Enum.map(&[?, | &1])
    [~s({"status":"ok","data":[) | Enum.take(entries, 1)] ++ rest ++ ["]}"]
  end
end
