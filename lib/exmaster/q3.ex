defmodule Exmaster.Q3 do
  @moduledoc """
  The wire format of the Quake 3 master protocol, as dpmaster speaks it.
  """
  alias Exmaster.Addr

  @oob <<0xFF, 0xFF, 0xFF, 0xFF>>
  @max_packet 1400
  @eot "\\EOT\0\0\0"
  @spaces [" ", "\t", "\n", "\r", "\v", "\f", <<0>>]

  # Length limits from dpmaster.
  def max_name_length, do: 63
  def max_gametype_length, do: 31

  @doc """
  Splits an out-of-band packet into its command and payload. The command
  ends at the first byte <= ' ', '\\' or '/'. A space or newline after it
  is dropped; '\\' and '/' are kept, since they start the payload (an
  infostring, or a server list where '/' marks an IPv6 entry).
  """
  def split_command(<<0xFF, 0xFF, 0xFF, 0xFF, rest::binary>>) do
    {cmd, payload} = split(rest, 0)
    {:ok, cmd, payload}
  end

  def split_command(_), do: :error

  defp split(bin, i) when i == byte_size(bin), do: {bin, ""}

  defp split(bin, i) do
    case :binary.at(bin, i) do
      c when c <= ?\s ->
        {binary_part(bin, 0, i), binary_part(bin, i + 1, byte_size(bin) - i - 1)}

      c when c == ?\\ or c == ?/ ->
        {binary_part(bin, 0, i), binary_part(bin, i, byte_size(bin) - i)}

      _ ->
        split(bin, i + 1)
    end
  end

  @doc "An out-of-band packet: four `0xFF` bytes, the command and its arguments, separated by spaces."
  def packet(cmd, args \\ []), do: @oob <> Enum.join([cmd | args], " ")

  @doc """
  Parses an infostring, `\\key\\value\\key\\value`. A key given twice keeps
  its last value. Values are kept as the bytes they came as.
  """
  def parse_info(bin) do
    bin = trim_trailing(bin, [?\n, 0])

    bin =
      case bin do
        "\\" <> rest -> rest
        _ -> bin
      end

    if bin == "", do: %{}, else: bin |> :binary.split("\\", [:global]) |> pairs(%{})
  end

  defp pairs([k, v | rest], acc), do: pairs(rest, Map.put(acc, k, v))
  defp pairs(_, acc), do: acc

  @doc "The integer s is, or nil."
  def int(nil), do: nil

  def int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc """
  The integer at the start of s, as C's atoi and dpmaster read it, or nil:
  QuakeSpasm-Spiked servers report protocol "3n".
  """
  def leading_int(nil), do: nil

  def leading_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  @space [0, ?\t, ?\n, ?\v, ?\f, ?\r, ?\s]

  @doc "Trims ASCII whitespace and NULs from both ends, as from a heartbeat tag."
  def trim(bin), do: bin |> trim_leading() |> trim_trailing(@space)

  defp trim_leading(<<c, rest::binary>>) when c in @space, do: trim_leading(rest)
  defp trim_leading(bin), do: bin

  defp trim_trailing(bin, chars) do
    size = byte_size(bin)

    if size > 0 and :binary.last(bin) in chars,
      do: trim_trailing(binary_part(bin, 0, size - 1), chars),
      else: bin
  end

  @doc """
  Whether s is a usable heartbeat tag, game name or gametype: 1 to max
  printable ASCII characters, no whitespace or '\\'.
  """
  def valid_name?(s, max) when is_binary(s) and byte_size(s) >= 1 and byte_size(s) <= max,
    do: printable?(s)

  def valid_name?(_, _), do: false

  defp printable?(<<c, rest::binary>>) when c > ?\s and c <= ?~ and c != ?\\, do: printable?(rest)
  defp printable?(<<>>), do: true
  defp printable?(_), do: false

  @doc """
  Parses the payload of `getservers` (ext false) or `getserversExt` (ext
  true). Anonymous queries (`getservers 68`) have game nil. `getservers`
  only lists IPv4; `getserversExt` lists both unless it names one.
  """
  def parse_query(payload, ext) do
    tokens = :binary.split(payload, @spaces, [:global, :trim_all])

    with {:ok, game, protocol, options} <- query_head(tokens) do
      q = %{
        game: game,
        protocol: protocol,
        empty: false,
        full: false,
        gametype: nil,
        ipv4: false,
        ipv6: false,
        ext: ext
      }

      {:ok, options |> Enum.reduce(q, &option/2) |> families()}
    end
  end

  defp query_head([first | rest]) do
    case {int(first), rest} do
      {nil, [p | options]} ->
        case int(p) do
          nil -> :error
          p -> {:ok, first, p, options}
        end

      {nil, []} ->
        :error

      {p, options} ->
        {:ok, nil, p, options}
    end
  end

  defp query_head([]), do: :error

  defp option("empty", q), do: %{q | empty: true}
  defp option("full", q), do: %{q | full: true}
  defp option("ffa", q), do: %{q | gametype: "0"}
  defp option("tourney", q), do: %{q | gametype: "1"}
  # pymaster had team as 2 and ctf as 3; in Quake 3, 2 is single player.
  defp option("team", q), do: %{q | gametype: "3"}
  defp option("ctf", q), do: %{q | gametype: "4"}
  defp option("ipv4", q), do: %{q | ipv4: true}
  defp option("ipv6", q), do: %{q | ipv6: true}
  defp option("gametype=" <> "", q), do: %{q | gametype: nil}
  defp option("gametype=" <> gametype, q), do: %{q | gametype: gametype}
  defp option(_, q), do: q

  defp families(%{ext: false} = q), do: %{q | ipv4: true, ipv6: false}
  defp families(%{ipv4: false, ipv6: false} = q), do: %{q | ipv4: true, ipv6: true}
  defp families(q), do: q

  @doc """
  Builds `getserversResponse` (ext false) or `getserversExtResponse`
  packets of at most max bytes, each with the full header. `\\` starts an
  IPv4 entry, `/` an IPv6 one; IPv6 is left out of `getserversResponse`.
  Only the last packet ends with the `\\EOT\\0\\0\\0` marker.
  """
  def encode_list(addrs, ext, max \\ @max_packet) do
    header = @oob <> if(ext, do: "getserversExtResponse", else: "getserversResponse")

    {done, current} =
      addrs
      |> Enum.flat_map(&entry(&1, ext))
      |> Kernel.++([@eot])
      |> Enum.reduce({[], header}, fn e, {done, current} ->
        if byte_size(current) + byte_size(e) > max,
          do: {[current | done], header <> e},
          else: {done, current <> e}
      end)

    Enum.reverse([current | done])
  end

  defp entry({{_, _, _, _}, _} = addr, _ext), do: ["\\" <> Addr.to_binary(addr)]
  defp entry(addr, true), do: ["/" <> Addr.to_binary(addr)]
  defp entry(_addr, false), do: []
end
