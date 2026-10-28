defmodule Exmaster do
  @moduledoc """
  Master servers for Quake 3 based games, Quake 2 and QuakeWorld, keeping
  their server lists in memory. See README.md.
  """

  alias Exmaster.{Addr, Store}

  @stores [q3: :exmaster_q3, q2: :exmaster_q2, qw: :exmaster_qw]

  @doc "The clock everything goes by, in milliseconds."
  def now, do: System.monotonic_time(:millisecond)

  @doc """
  The number of servers each master lists, in total and by game.

      bin/exmaster rpc 'IO.inspect(Exmaster.stats())'
  """
  def stats do
    now = now()

    for {name, store} <- @stores, into: %{} do
      entries = Store.all(store, now)
      games = Enum.frequencies_by(entries, fn {_, e} -> e.game end)
      {name, %{servers: length(entries), games: games}}
    end
  end

  @doc "The servers a master (`:q3`, `:q2` or `:qw`) lists, sorted by address."
  def servers(master) do
    now = now()

    @stores
    |> Keyword.fetch!(master)
    |> Store.all(now)
    |> Enum.sort()
    |> Enum.map(fn {addr, e} ->
      e
      |> Map.take([:game, :protocol, :version, :clients, :max_clients, :hostname])
      |> Map.put(:address, Addr.to_string(addr))
      |> Map.put(:expires_in, div(e.expires - now, 1000))
    end)
  end
end
