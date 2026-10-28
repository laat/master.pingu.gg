defmodule Exmaster.Protocol do
  @moduledoc """
  A master protocol, run by `Exmaster.Listener` on a UDP socket. The
  listener hands it each packet and a tick every second; it returns the
  packets to send and its new state. Packets go out through the socket the
  packet that caused them came in on.

  ctx has the listener's `:id`, the local address it is bound to (two
  listeners can share a port on different addresses), its `:port`, its
  `:label`, the `:store` and the `:challenge_ttl` and `:server_ttl`. Times
  are `Exmaster.now/0`.
  """

  @type ctx :: %{
          id: Exmaster.Addr.t(),
          port: :inet.port_number(),
          label: String.t() | nil,
          store: atom,
          challenge_ttl: pos_integer,
          server_ttl: pos_integer
        }
  @type sends :: [{binary, Exmaster.Addr.t()}]

  @callback name() :: String.t()
  @doc "`:inet6` for a dual-stack socket by default, `:inet` for IPv4 only."
  @callback family() :: :inet | :inet6
  @callback store() :: atom
  @callback init(now :: integer) :: term
  @callback handle_packet(binary, Exmaster.Addr.t(), ctx, now :: integer, state :: term) ::
              {sends, term}
  @callback tick(ctx, now :: integer, state :: term) :: {sends, term}
end
