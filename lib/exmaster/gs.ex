defmodule Exmaster.GS do
  @moduledoc """
  The wire format of GameSpy's first master protocol, from before Query and
  Reporting 2: heartbeats and the `\\secure\\`/`\\validate\\` challenge over
  UDP, server lists over TCP. See `docs/gamespy.md`.

  | Message | Direction | Format |
  |---|---|---|
  | `\\heartbeat\\<query port>\\gamename\\<game>` | server → master, UDP 27900 | from the query port; `\\statechanged\\<n>` after it on a change, 2 when it exits |
  | `\\info\\\\secure\\<challenge>` | master → server's query port | |
  | `\\<info>\\validate\\<response>\\...\\final\\\\queryid\\<n>.1` | server → master | the response is gsseckey(challenge, game key) |
  | `\\basic\\\\secure\\<challenge>` | master → client, TCP 28900 | on connecting |
  | `\\gamename\\<game>\\...\\enctype\\<n>\\final\\\\queryid\\1.1\\` | client → master | |
  | `\\list\\cmp\\gamename\\<game>[\\where\\<filter>]\\final\\` | client → master | |
  | the list | master → client | 6 bytes a server: IPv4 and query port, big-endian; then `\\final\\`; enctype 2 encrypts both |
  """

  # The games the master lists, by the gamename their servers heartbeat and
  # clients ask for, with their secret key: it signs a server's reply to a
  # challenge and encrypts lists. Battlefield 1942's is in its binaries'
  # ServerListReadList and in aluigi's gslist.cfg.
  @games %{"bfield1942" => "HpWx9z"}

  @doc "The secret key of a game the master lists, or nil."
  def key(game), do: Map.get(@games, game)

  @doc """
  Parses `\\key\\value\\key\\value...`. A key given twice keeps its last
  value; a key without one (`\\final\\`) has "". Values are the bytes they
  came as.
  """
  def parse("\\" <> bin), do: bin |> :binary.split("\\", [:global]) |> pairs(%{})
  def parse(_), do: %{}

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
  The response to a `\\secure\\` challenge: Luigi Auriemma's gsmsalg
  (gsseckey) with enctype 0, an RC4-like pass keyed with the game's key,
  then base64. GameSpy's code takes challenges of 1 to 65 bytes.
  """
  def validate(challenge, key) when byte_size(challenge) in 1..65 do
    table =
      Enum.reduce(0..255, {List.to_tuple(Enum.to_list(0..255)), 0}, fn i, {t, a} ->
        a = rem(a + elem(t, i) + :binary.at(key, rem(i, byte_size(key))), 256)
        {swap(t, i, a), a}
      end)
      |> elem(0)

    {out, _, _, _} =
      for <<c <- challenge>>, reduce: {[], table, 0, 0} do
        {out, t, a, b} ->
          a = rem(a + c + 1, 256)
          x = elem(t, a)
          b = rem(b + x, 256)
          y = elem(t, b)
          t = t |> put_elem(b, x) |> put_elem(a, y)
          {[Bitwise.bxor(c, elem(t, rem(x + y, 256))) | out], t, a, b}
      end

    bytes = out |> Enum.reverse() |> :erlang.list_to_binary()
    pad = rem(3 - rem(byte_size(bytes), 3), 3)
    Base.encode64(bytes <> :binary.copy(<<0>>, pad))
  end

  defp swap(t, i, j), do: t |> put_elem(i, elem(t, j)) |> put_elem(j, elem(t, i))

  @doc "A server list, `cmp` form: 6 bytes a server, IPv4 and port, big-endian."
  def encode_list(addrs),
    do: for({{a, b, c, d}, port} <- addrs, into: "", do: <<a, b, c, d, port::16>>)

  @doc "A server list, text form: `\\ip\\a.b.c.d:port` a server."
  def encode_text_list(addrs),
    do: for(addr <- addrs, into: "", do: "\\ip\\" <> Exmaster.Addr.to_string(addr))
end
