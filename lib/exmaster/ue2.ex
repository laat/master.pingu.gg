defmodule Exmaster.UE2 do
  @moduledoc """
  The wire format of Unreal Engine 2's master protocol, as Unreal
  Tournament 2004 speaks it over TCP. `Exmaster.UE2.Master` runs it; see
  `docs/ut2004.md`.

  Each message is a frame: its length, 4 bytes little-endian, then the
  payload. Integers are 4 bytes little-endian. A string is an FString: a
  compact index, then that many Latin-1 bytes with a trailing NUL, or, if
  the index is negative, that many UTF-16LE characters. Strings here are
  UTF-8, without the NUL.
  """
  import Bitwise

  # The version the latest UT2004 patch reports, which a server's flags
  # compare with.
  @latest_version 3369
  # What a server is filtered by is kept small: each entry is copied to
  # every list and to the other nodes.
  @max_rules 32
  @key_bytes 32
  @value_bytes 64
  @max_mutators 16
  @max_filters 32

  @doc "A frame with payload."
  def frame(payload), do: [<<IO.iodata_length(payload)::little-32>>, payload]

  @doc "A compact index: a sign bit, then 6 bits and up to four more bytes."
  def compact(n) when n < 0, do: set_sign(compact(-n))

  def compact(n) when n < 0x40, do: <<n>>
  def compact(n), do: <<0x40 ||| (n &&& 0x3F)>> <> more(n >>> 6, 1)

  defp more(n, 4), do: <<n>>
  defp more(n, _) when n < 0x80, do: <<n>>
  defp more(n, i), do: <<0x80 ||| (n &&& 0x7F)>> <> more(n >>> 7, i + 1)

  defp set_sign(<<b0, rest::binary>>), do: <<b0 ||| 0x80, rest::binary>>

  @doc "Reads a compact index: `{:ok, n, rest}` or `:error`."
  def decode_compact(<<b0, rest::binary>>) do
    with {:ok, n, rest} <- decode_more(rest, b0 &&& 0x3F, 6, (b0 &&& 0x40) != 0, 1) do
      {:ok, if((b0 &&& 0x80) != 0, do: -n, else: n), rest}
    end
  end

  def decode_compact(_), do: :error

  defp decode_more(rest, n, _, false, _), do: {:ok, n, rest}
  defp decode_more(<<b, rest::binary>>, n, shift, true, 4), do: {:ok, n ||| b <<< shift, rest}

  defp decode_more(<<b, rest::binary>>, n, shift, true, i),
    do: decode_more(rest, n ||| (b &&& 0x7F) <<< shift, shift + 7, (b &&& 0x80) != 0, i + 1)

  defp decode_more(_, _, _, _, _), do: :error

  @doc "An FString: Latin-1 if the string fits, UTF-16LE otherwise."
  def string(s) do
    case :unicode.characters_to_binary(s, :utf8, :latin1) do
      latin1 when is_binary(latin1) ->
        [compact(byte_size(latin1) + 1), latin1, 0]

      _ ->
        utf16 = :unicode.characters_to_binary(s, :utf8, {:utf16, :little})
        [compact(-(div(byte_size(utf16), 2) + 1)), utf16, <<0, 0>>]
    end
  end

  @doc "Reads an FString: `{:ok, string, rest}` or `:error`."
  def decode_string(bin) do
    case decode_compact(bin) do
      {:ok, 0, rest} ->
        {:ok, "", rest}

      {:ok, n, rest} when n > 0 and byte_size(rest) >= n ->
        <<s::binary-size(^n), rest::binary>> = rest
        {:ok, s |> strip_nul(1) |> :unicode.characters_to_binary(:latin1), rest}

      {:ok, n, rest} when n < 0 and byte_size(rest) >= -2 * n ->
        size = -2 * n
        <<s::binary-size(^size), rest::binary>> = rest

        case :unicode.characters_to_binary(strip_nul(s, 2), {:utf16, :little}) do
          s when is_binary(s) -> {:ok, s, rest}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp strip_nul(s, width) do
    size = byte_size(s) - width

    case s do
      <<s::binary-size(^size), 0::size(^width)-unit(8)>> -> s
      s -> s
    end
  end

  @doc """
  The client name and version from a challenge response, the first thing
  a game server or client sends: two hashes of its CD key, its name
  (`UT2K4SERVER`, `UT2K4CLIENT`), its version, then things about its
  machine. `{:ok, name, version}` or `:error`.
  """
  def parse_hello(payload) do
    with {:ok, _key_hash, rest} <- decode_string(payload),
         {:ok, _response, rest} <- decode_string(rest),
         {:ok, name, <<version::little-signed-32, _::binary>>} <- decode_string(rest) do
      {:ok, name, version}
    else
      _ -> :error
    end
  end

  @doc """
  A heartbeat's fields, from after its message byte: the server's own
  description, as its browser shows it. `{:ok, map}` or `:error`. The
  player list after the rules is left unread.
  """
  def parse_heartbeat(payload) do
    with {:ok, n, rest} <- decode_compact(payload),
         {:ok, _addresses, rest} <- strings(rest, n),
         <<_server_id::little-32, rest::binary>> <- rest,
         {:ok, _ip, rest} <- decode_string(rest),
         <<port::little-signed-32, query_port::little-signed-32, rest::binary>> <- rest,
         {:ok, hostname, rest} <- decode_string(rest),
         {:ok, map, rest} <- decode_string(rest),
         {:ok, gametype, rest} <- decode_string(rest),
         <<players::little-signed-32, max::little-signed-32, _ping::little-32, _flags::little-32,
           rest::binary>> <- rest,
         {:ok, skill, rest} <- decode_string(rest),
         {:ok, n, rest} <- decode_compact(rest),
         {:ok, rules, _rest} <- pairs(rest, n, []) do
      {:ok,
       %{
         port: port,
         query_port: query_port,
         hostname: hostname,
         map: map,
         gametype: gametype,
         players: players,
         max_players: max,
         skill: skill,
         rules: rules
       }}
    else
      _ -> :error
    end
  end

  defp strings(_rest, n) when n < 0, do: :error
  defp strings(rest, 0), do: {:ok, [], rest}

  defp strings(rest, n) do
    with {:ok, _, rest} <- decode_string(rest), do: strings(rest, n - 1)
  end

  defp pairs(_rest, n, _acc) when n < 0, do: :error
  defp pairs(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp pairs(rest, n, acc) do
    with {:ok, k, rest} <- decode_string(rest),
         {:ok, v, rest} <- decode_string(rest),
         do: pairs(rest, n - 1, [{k, v} | acc])
  end

  @doc """
  A list query's filters, from after its message byte: a count, then
  key, value and a comparison each. `{:ok, [{key, value, op, number}]}`
  or `:error`. Key and value are in lower case, the value cut as a
  server's are and read as a number once. The ops are `:eq`, `:ne`,
  `:lt`, `:le`, `:gt`, `:ge`; a filter with another one is left out, as
  UT2004's "disabled" is. More than 32 filters is an error: each is
  checked against every server.
  """
  def parse_query(<<n, rest::binary>>) when n <= @max_filters, do: filters(rest, n, [])
  def parse_query(_), do: :error

  @ops %{0 => :eq, 1 => :ne, 2 => :lt, 3 => :le, 4 => :gt, 5 => :ge}

  defp filters(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp filters(rest, n, acc) do
    with {:ok, k, rest} <- decode_string(rest),
         {:ok, v, <<op, rest::binary>>} <- decode_string(rest) do
      case @ops do
        %{^op => op} ->
          {text, number} = value(v)
          filters(rest, n - 1, [{String.downcase(k), text, op, number} | acc])

        _ ->
          filters(rest, n - 1, acc)
      end
    else
      _ -> :error
    end
  end

  @doc """
  The values a server is filtered by, keyed in lower case: its first 32
  rules, and those UT2004's browser asks for, as OpenSpy's master derives
  them. Each is `{text, number}`: the text in lower case, cut to 64 bytes,
  and the number it starts with, read once.
  """
  def filter_values(hb) do
    rules =
      for {k, v} <- Enum.take(hb.rules, @max_rules),
          into: %{},
          do: {k |> cut(@key_bytes) |> String.downcase(), v}

    rules
    |> Map.merge(%{
      "hostname" => hb.hostname,
      "mapname" => hb.map,
      "gametype" => hb.gametype,
      "category" => hb.skill,
      "numplayers" => Integer.to_string(hb.players),
      "currentplayers" => Integer.to_string(hb.players),
      "maxplayers" => Integer.to_string(hb.max_players),
      "freespace" => if(hb.players < hb.max_players, do: "1", else: "0"),
      "nomutators" => to_string(mutators(hb) == []),
      "standard" => "true",
      "nobots" => to_string(Map.get(rules, "minplayers", "0") == "0"),
      "transloc" => Map.get(rules, "translocator", "False"),
      "weaponstay" => Map.get(rules, "weaponstay", "False"),
      "stats" => Map.get(rules, "gamestats", "False"),
      "password" => Map.get(rules, "gamepassword", "False")
    })
    |> Map.new(fn {k, v} -> {k, value(v)} end)
  end

  defp value(v) do
    text = v |> cut(@value_bytes) |> String.downcase()
    {text, int(text)}
  end

  @doc "The server's first 16 mutators, in lower case, cut to 64 bytes."
  def mutators(hb) do
    for({k, v} <- hb.rules, String.downcase(k) == "mutator", do: v)
    |> Enum.take(@max_mutators)
    |> Enum.map(&(&1 |> cut(@value_bytes) |> String.downcase()))
  end

  @doc "s, cut to at most max bytes where a UTF-8 character starts."
  def cut(s, max) when byte_size(s) <= max, do: s

  def cut(s, max) do
    case :unicode.characters_to_binary(binary_part(s, 0, max)) do
      {:incomplete, s, _} -> s
      s -> s
    end
  end

  @doc """
  The flags the browser shows icons by, from a server's filter values
  and mutators: password, stats, the latest version, non-dedicated,
  InstaGib, standard (always, as on OpenSpy's master), UT Classic.
  """
  def flags(values, mutators) do
    text = fn k -> with {t, _} <- values[k], do: t end

    [
      {text.("gamepassword") == "true", 0},
      {text.("gamestats") == "true", 1},
      {text.("serverversion") == Integer.to_string(@latest_version), 2},
      {text.("servermode") == "non-dedicated", 3},
      {"mutinstagib" in mutators, 4},
      {true, 5},
      {"mututclassic" in mutators, 6}
    ]
    |> Enum.reduce(0, fn {set, bit}, acc -> if set, do: acc ||| 1 <<< bit, else: acc end)
  end

  @doc """
  Whether a server matches every filter. As on OpenSpy's master, a key
  the server doesn't have matches; `=` and `!=` compare text, case
  aside, the others numbers. `mutator` compares as 0 if the server runs
  the mutator and 1 if not, so `> 0`, qstat's `-` before a mutator, asks
  for servers without it.
  """
  def matches?(entry, filters), do: Enum.all?(filters, &passes?(entry, &1))

  defp passes?(entry, {"mutator", v, op, _}),
    do: holds?(if(v in entry.mutators, do: 0, else: 1), op)

  defp passes?(entry, {k, v, op, n}) do
    case entry.filters do
      %{^k => {text, _}} when op in [:eq, :ne] -> holds?(if(text == v, do: 0, else: 1), op)
      %{^k => {_, have}} -> holds?(sign(have - n), op)
      _ -> true
    end
  end

  defp sign(n) when n < 0, do: -1
  defp sign(0), do: 0
  defp sign(_), do: 1

  defp holds?(cmp, :eq), do: cmp == 0
  defp holds?(cmp, :ne), do: cmp != 0
  defp holds?(cmp, :lt), do: cmp < 0
  defp holds?(cmp, :le), do: cmp <= 0
  defp holds?(cmp, :gt), do: cmp > 0
  defp holds?(cmp, :ge), do: cmp >= 0

  # As C's atoi: leading digits, 0 for none.
  defp int(s) do
    case Integer.parse(String.trim_leading(s)) do
      {n, _} -> n
      :error -> 0
    end
  end

  @doc "A server as a list sends it to UT2004 clients: one frame's payload."
  def encode_entry({{a, b, c, d}, port}, entry) do
    [
      <<a, b, c, d, port::little-16, entry.query_port::little-16>>,
      string(entry.hostname),
      string(entry.map),
      string(entry.gametype),
      <<min(entry.clients, 255), min(entry.max_clients, 255), entry.flags::little-32>>,
      string(entry.skill)
    ]
  end
end
