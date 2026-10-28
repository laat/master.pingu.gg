defmodule Exmaster.SB do
  @moduledoc """
  The wire format of GameSpy's server browsing, the TCP side of QR2: a
  client asks a master on port 28910 for a game's list, and gets it
  encrypted. `Exmaster.SB.ListServer` runs it; see `docs/gamespy.md`.

  A request is a 2-byte length, big-endian, counting itself, then:

  | Field | |
  |---|---|
  | `00` | a list request |
  | protocol and encoding version | a byte each, 1 and 3 |
  | game version | 4 bytes |
  | the game to list, the game asking | NUL-terminated |
  | challenge | 8 bytes |
  | filter | NUL-terminated, SQL-like |
  | fields | NUL-terminated, `\\hostname\\numplayers...` |
  | options | 4 bytes, big-endian |
  | source IP | 4 bytes, with option 8 |
  | most servers | 4 bytes, little-endian, with option 128 |

  The answer starts with a crypt header: a byte, 10 xor 0xEC, then 10
  bytes, the first two the game's options (0 here), then a byte, 25 xor
  0xEA, and 25 random bytes. Mixed into the client's challenge with the
  asking game's secret key, those key `Exmaster.SB.Crypt`, which
  encrypts the rest: the client's IP, the game's default query port
  (0xFFFF and a message for an error), then, unless the client asked for
  no list (option 2), the fields, by type (0, text) and name, a count of
  popular values (0), and a record a server, ending with a zero byte and
  4 bytes 0xFF.
  """
  import Bitwise

  alias Exmaster.SB.Crypt

  @no_server_list 2
  @alternate_source_ip 8
  @limit_result_count 128

  @private_ip 2
  @nonstandard_port 16
  @nonstandard_private_port 32
  @has_keys 64

  @max_fields 64

  @doc """
  A list request, from after the length: `{:ok, map}` with `:game`,
  `:from`, `:challenge`, `:fields`, `:list?`, `:source_ip` and `:max`, or
  `:error`. The filter is read and left: masters players use now apply
  it, but this one lists every server, as its GameSpy master does.
  """
  def parse_request(<<0, _protocol, _encoding, _game_version::binary-4, rest::binary>>) do
    with [game, rest] <- :binary.split(rest, <<0>>),
         [from, <<challenge::binary-8, rest::binary>>] <- :binary.split(rest, <<0>>),
         [_filter, rest] <- :binary.split(rest, <<0>>),
         [fields, <<options::32, rest::binary>>] <- :binary.split(rest, <<0>>),
         {:ok, source_ip, rest} <- optional(rest, options, @alternate_source_ip, :big),
         {:ok, max, _} <- optional(rest, options, @limit_result_count, :little) do
      {:ok,
       %{
         game: game,
         from: from,
         challenge: challenge,
         fields:
           fields
           |> :binary.split("\\", [:global])
           |> Enum.reject(&(&1 == ""))
           |> Enum.take(@max_fields),
         list?: (options &&& @no_server_list) == 0,
         source_ip: source_ip && ip(source_ip),
         max: max
       }}
    else
      _ -> :error
    end
  end

  def parse_request(_), do: :error

  defp optional(rest, options, flag, endian) when (options &&& flag) != 0 do
    case {rest, endian} do
      {<<n::32, rest::binary>>, :big} -> {:ok, n, rest}
      {<<n::little-32, rest::binary>>, :little} -> {:ok, n, rest}
      _ -> :error
    end
  end

  defp optional(rest, _options, _flag, _endian), do: {:ok, nil, rest}

  defp ip(n), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}

  @doc """
  The crypt header and the cipher state for the rest, from the client's
  challenge and the asking game's secret key: `{header, state}`.
  """
  def crypt(challenge, key, random \\ &:crypto.strong_rand_bytes/1) do
    server_challenge = random.(25)

    header =
      <<bxor(10, 0xEC), 0, 0, random.(8)::binary, bxor(25, 0xEA), server_challenge::binary>>

    {header, Crypt.init(mix(challenge, server_challenge, key))}
  end

  @doc false
  # GameSpy's SDK, InitCryptKey: the master's challenge and the secret key
  # folded into the client's 8 bytes.
  def mix(challenge, server_challenge, key) do
    c = :binary.bin_to_list(challenge) |> List.to_tuple()
    k = byte_size(key)

    server_challenge
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce(c, fn {s, i}, c ->
      j = rem(i * :binary.at(key, rem(i, k)), 8)
      put_elem(c, j, bxor(elem(c, j), bxor(elem(c, rem(i, 8)), s) &&& 0xFF))
    end)
    |> Tuple.to_list()
    |> :erlang.list_to_binary()
  end

  @doc "The list's head: the client's IP and the game's default query port."
  def head({a, b, c, d}, port), do: <<a, b, c, d, port::16>>

  @doc "The answer to a request for a game the master doesn't list."
  def error({a, b, c, d}, message), do: <<a, b, c, d, 0xFF, 0xFF, message::binary, 0>>

  @doc """
  The list after the head: the fields asked for, no popular values, a
  record a server, the end. Values are text; a server's own port is given
  where it isn't the game's default, its address on its own network where
  it said one.
  """
  def encode_list(fields, servers, default_port) do
    [
      length(fields),
      Enum.map(fields, &[0, &1, 0]),
      0,
      Enum.map(servers, &record(&1, fields, default_port)),
      <<0, 0xFF, 0xFF, 0xFF, 0xFF>>
    ]
  end

  defp record({{{a, b, c, d}, port}, entry}, fields, default_port) do
    private_ip = entry.local_ip
    private_port = entry.local_port

    flags =
      @has_keys |||
        if(port != default_port, do: @nonstandard_port, else: 0) |||
        if(private_ip, do: @private_ip, else: 0) |||
        if(private_port && private_port != default_port, do: @nonstandard_private_port, else: 0)

    [
      <<flags, a, b, c, d>>,
      if((flags &&& @nonstandard_port) != 0, do: <<port::16>>, else: []),
      if(private_ip, do: Exmaster.Addr.ip_bytes(private_ip), else: []),
      if((flags &&& @nonstandard_private_port) != 0, do: <<private_port::16>>, else: []),
      Enum.map(fields, &[0xFF, Map.get(entry.fields, &1, ""), 0])
    ]
  end
end
