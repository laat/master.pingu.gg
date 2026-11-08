defmodule Exmaster.Protocol do
  @moduledoc """
  A master protocol, run by `Exmaster.Listener` on a UDP socket. The
  listener hands it each packet, a tick every second and, if it pulls
  lists from upstream masters, each round of them; it returns the
  packets to send and its new state. Packets go out through the socket the
  packet that caused them came in on.

  ctx has the listener's `:id`, the local address it is bound to (two
  listeners can share a port on different addresses), its `:port`, its
  `:label`, the `:store`, the `:masters` on a shared socket
  (`Exmaster.Shared`) and the `:challenge_ttl` and `:server_ttl`. Times
  are `Exmaster.now/0`.
  """

  @type ctx :: %{
          id: Exmaster.Addr.t(),
          port: :inet.port_number(),
          label: String.t() | nil,
          store: atom,
          masters: [module],
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

  @doc """
  For a master that pulls lists from upstream masters (`Exmaster.Upstream`):
  the query of an upstream's line in the upstreams file, from the words
  after its address, with the port its masters listen on by default.
  """
  @callback upstream(args :: [String.t()]) ::
              {:ok, %{required(:packet) => binary, required(:port) => :inet.port_number()}}
              | {:error, String.t()}

  @doc "Starts a round of upstream queries, `{master address, upstream}` in order."
  @callback pull(targets :: [{Exmaster.Addr.t(), map}], ctx, now :: integer, state :: term) ::
              {sends, term}

  @optional_callbacks upstream: 1, pull: 4
end
