defmodule Exmaster.QW do
  @moduledoc """
  The wire format of the QuakeWorld master protocol (id's GPL Quake
  source, `QW/client/protocol.h` and `QW/server/sv_main.c`). See
  `docs/quakeworld.md` in laat/pingu.gg. Commands are one byte.

  | Message | Direction | Format |
  |---|---|---|
  | `c\\n` | client → master | no out-of-band prefix (taken with one too) |
  | `d\\n` | master → client | out-of-band (`M2C_MASTER_REPLY`), then 6-byte entries: IPv4 address and port, big-endian |
  | `a\\n<seq>\\n<players>\\n` | server → master | `S2M_HEARTBEAT`, no prefix (taken with one too) |
  | `C\\n` | server → master | `S2M_SHUTDOWN` |
  | `status\\n` | master → server | out-of-band |
  | `n<status>` | server → master | out-of-band (`A2C_PRINT`): the serverinfo, then a line per client |
  """

  @oob <<0xFF, 0xFF, 0xFF, 0xFF>>
  @max_packet 1400

  @doc "Asks a server for its serverinfo and clients."
  def status, do: @oob <> "status\n"

  @doc """
  What a packet is: `:query`, `:heartbeat`, `:shutdown`, `{:status, payload}`
  or `:other`.
  """
  def classify(<<0xFF, 0xFF, 0xFF, 0xFF, "n", payload::binary>>), do: {:status, payload}
  def classify(<<0xFF, 0xFF, 0xFF, 0xFF, rest::binary>>), do: classify_plain(rest)
  def classify(data), do: classify_plain(data)

  # qstat's master query is "c\n\0"; id's master only looked at the first
  # byte. A one-byte command may be followed by newlines and NULs.
  defp classify_plain("c" <> rest), do: if(padding?(rest), do: :query, else: :other)
  defp classify_plain("a"), do: :heartbeat
  defp classify_plain("a\n" <> _), do: :heartbeat
  defp classify_plain("C" <> rest), do: if(padding?(rest), do: :shutdown, else: :other)
  defp classify_plain(_), do: :other

  defp padding?(rest), do: rest |> :binary.bin_to_list() |> Enum.all?(&(&1 in [?\n, 0]))

  @doc """
  Parses a status reply: the serverinfo, then a line per client,
  `userid frags time ping "name" "skin" top bottom ["team"]`. MVDSV
  includes spectators, with frags -9999 or a name starting `\\s\\`; they
  aren't counted. Returns the info and the number of players.
  """
  def parse_status(payload) do
    [first | clients] = payload |> String.trim_trailing("\n") |> :binary.split("\n", [:global])
    {parse_info(first), Enum.count(clients, &player?/1)}
  end

  defp player?(line) do
    case :binary.split(line, "\"") do
      [numbers, name] ->
        frags =
          case String.split(numbers) do
            [_, frags | _] -> frags
            _ -> ""
          end

        frags != "-9999" and not String.starts_with?(name, "\\s\\")

      _ ->
        false
    end
  end

  @doc "Parses `\\\\key\\\\value...`; a key given twice keeps its last value."
  def parse_info("\\" <> info), do: info |> :binary.split("\\", [:global]) |> pairs(%{})
  def parse_info(_), do: %{}

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
  The `d` reply, in packets of at most 1400 bytes, each with the header.
  The list has no end marker and no room for IPv6.
  """
  def encode_list(addrs) do
    header = @oob <> "d\n"

    for({{a, b, c, d}, port} <- addrs, do: <<a, b, c, d, port::16>>)
    |> Enum.chunk_every(div(@max_packet - byte_size(header), 6))
    |> case do
      [] -> [header]
      chunks -> Enum.map(chunks, &IO.iodata_to_binary([header | &1]))
    end
  end

  @doc """
  QuakeWorld Team Fortress is a game of its own: `*gamedir` fortress, or
  `teamplay` ending in a TF tag (`1?TF2.7`, `21?TeamFortress`). Everything
  else is QuakeWorld.
  """
  def game(info) do
    tag =
      case String.split(Map.get(info, "teamplay", ""), "?", parts: 2) do
        [_, tag] -> downcase(tag)
        _ -> ""
      end

    if downcase(Map.get(info, "*gamedir", "")) == "fortress" or
         String.starts_with?(tag, ["tf", "teamfortress"]),
       do: "QWTF",
       else: "QuakeWorld"
  end

  # Serverinfo is whatever bytes the server has, not always UTF-8.
  defp downcase(bin),
    do: for(<<c <- bin>>, into: "", do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)
end
