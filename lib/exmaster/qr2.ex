defmodule Exmaster.QR2 do
  @moduledoc """
  The wire format of GameSpy's Query and Reporting 2 (QR2), as game
  servers speak it to the master over UDP 27900. Battlefield Vietnam is
  one. Clients get the lists over TCP from `Exmaster.SB`. See
  `docs/gamespy.md`.

  A server's packets start with a type byte and its instance key, 4 random
  bytes it picks as it starts; the master's start with `FE FD`, the type
  and the key back. The server ignores a master packet with another key.

  | Packet | Direction | Payload |
  |---|---|---|
  | `09` available | server → master, from a port of its own | key 0, the gamename, NUL; answered `FE FD 09` and 4 zero bytes |
  | `03` heartbeat | server → master, from its query port | key, then key NUL value NUL ... NUL, then its players and teams |
  | `FE FD 01` challenge | master → server | key, the challenge, NUL |
  | `01` response | server → master | key, gsseckey(challenge, game key), NUL |
  | `FE FD 0A` registered | master → server | key |
  | `08` keepalive | server → master, every 20 seconds | key |

  A server heartbeats with `statechanged` 3 every 10 seconds until the
  master answers, then every 60 seconds (0), at most every 10 seconds on a
  change (1), and as it exits (2). It answers a challenge whenever it
  comes, if the key is its own. It reads the challenge's last 14
  characters as 2 hex digits of options and its public IP and port in hex.
  """

  # The games the master lists, by the gamename their servers heartbeat,
  # with their secret key and the query port they use by default. The keys
  # are in aluigi's gslist.cfg; Battlefield Vietnam's servers answer
  # challenges with this one.
  @games %{"bfvietnam" => {"h2P9dJ", 23_000}}

  # Games whose clients ask for lists but that list no servers of their
  # own: GameSpy Arcade (gslive), which gslist asks as.
  @clients %{"gslive" => "Xn221z"}

  @doc "The games the master lists."
  def games, do: Map.keys(@games)

  @doc "The secret key of a game the master lists, or nil."
  def key(game) do
    case @games do
      %{^game => {key, _}} -> key
      _ -> nil
    end
  end

  @doc "The secret key of a game that may ask for lists, or nil."
  def client_key(game), do: key(game) || Map.get(@clients, game)

  @doc "The query port a game's servers use by default, or nil."
  def default_port(game) do
    case @games do
      %{^game => {_, port}} -> port
      _ -> nil
    end
  end

  @available 0x09
  @heartbeat 0x03
  @response 0x01

  @doc """
  A server's packet: `{:available, gamename}`, `{:heartbeat, key, payload}`,
  `{:response, key, response}` or `:other`.
  """
  def parse(<<@available, _key::binary-4, rest::binary>>), do: {:available, nts(rest)}
  def parse(<<@heartbeat, key::binary-4, rest::binary>>), do: {:heartbeat, key, rest}
  def parse(<<@response, key::binary-4, rest::binary>>), do: {:response, key, nts(rest)}
  def parse(_), do: :other

  defp nts(bin), do: bin |> :binary.split(<<0>>) |> hd()

  @doc """
  A heartbeat's keys, up to the empty key that ends them, as
  `{:ok, [{key, value}]}`, or `:error` if nothing ends them. Values may
  be empty. The players and teams after them are left unread.
  """
  def parse_keys(payload), do: keys(:binary.split(payload, <<0>>, [:global]), [])

  defp keys(["" | _], acc), do: {:ok, Enum.reverse(acc)}
  defp keys([k, v, next | rest], acc), do: keys([next | rest], [{k, v} | acc])
  defp keys(_, _), do: :error

  @doc "The master's challenge to a server."
  def challenge_packet(key, challenge),
    do: <<0xFE, 0xFD, 0x01, key::binary, challenge::binary, 0>>

  @doc "The master's word that a server is listed."
  def registered_packet(key), do: <<0xFE, 0xFD, 0x0A, key::binary>>

  @doc "The answer to an available check: the game's services are on."
  def available_packet, do: <<0xFE, 0xFD, 0x09, 0::32>>
end
