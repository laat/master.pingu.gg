defmodule Exmaster.Q2 do
  @moduledoc """
  The wire format of the Quake 2 master protocol (id's `server/sv_main.c`,
  packetflinger/q2master, quakeservices/master).

  | Message | Direction | Format |
  |---|---|---|
  | `query\\n` | client → master | no out-of-band prefix (taken with one too) |
  | `servers ` | master → client | out-of-band, then 6-byte entries: IPv4 address and port, big-endian |
  | `heartbeat\\n<status>` | server → master | out-of-band, every 300 s |
  | `ping` | server → master | out-of-band, taken as a heartbeat |
  | `shutdown` | server → master | out-of-band, when the server stops |
  | `status\\n` | master → server | out-of-band |
  | `print\\n<status>` | server → master | out-of-band: the serverinfo, then `<frags> <ping> "<name>"` per player |
  """

  @oob <<0xFF, 0xFF, 0xFF, 0xFF>>
  @max_packet 1400

  @doc "Asks a server for its serverinfo and players."
  def status, do: @oob <> "status\n"

  @doc """
  The command of a packet and what follows it: `{:oob, cmd, rest}` or
  `{:plain, cmd, rest}`. Quake 2 tokenizes the whole packet, so the command
  ends at the first byte <= ' ', which is dropped.
  """
  def split(<<0xFF, 0xFF, 0xFF, 0xFF, rest::binary>>) do
    {cmd, rest} = word(rest, 0)
    {:oob, cmd, rest}
  end

  def split(data) do
    {cmd, rest} = word(data, 0)
    {:plain, cmd, rest}
  end

  defp word(bin, i) when i == byte_size(bin), do: {bin, ""}

  defp word(bin, i) do
    if :binary.at(bin, i) <= ?\s,
      do: {binary_part(bin, 0, i), binary_part(bin, i + 1, byte_size(bin) - i - 1)},
      else: word(bin, i + 1)
  end

  @doc """
  Parses a `print` reply: the serverinfo infostring on the first line,
  then a line per player. Returns the info and the number of players.
  """
  def parse_status(payload) do
    [first | players] = payload |> String.trim_trailing("\n") |> :binary.split("\n", [:global])
    {parse_info(first), Enum.count(players, &String.contains?(&1, "\""))}
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
  The `servers` reply, in packets of at most 1400 bytes, each with the
  header. The list has no end marker and no room for IPv6.
  """
  def encode_list(addrs) do
    header = @oob <> "servers "

    for({{a, b, c, d}, port} <- addrs, do: <<a, b, c, d, port::16>>)
    |> Enum.chunk_every(div(@max_packet - byte_size(header), 6))
    |> case do
      [] -> [header]
      chunks -> Enum.map(chunks, &IO.iodata_to_binary([header | &1]))
    end
  end

  @doc """
  Action Quake 2 is a game of its own (37 of 98 servers on
  master.quakeservers.net on 2026-10-25); everything else is Quake 2 with
  whatever mod. gamename is the mod's name, not the game's.
  """
  def game(info) do
    if Map.get(info, "actionversion", "") != "" or
         "action" in [info["game"], info["gamedir"], info["gamename"]],
       do: "ActionQuake2",
       else: "Quake2"
  end
end
