defmodule Exmaster do
  @moduledoc """
  Master servers for Quake 3 based games, Quake 2, QuakeWorld, GameSpy's
  games and Unreal Tournament 2004, keeping their server lists in memory.
  See README.md.
  """

  alias Exmaster.{Addr, Store}

  @doc "The clock everything goes by, in milliseconds."
  def now, do: System.monotonic_time(:millisecond)

  @doc """
  The number of servers each master lists, in total, by game, and of those
  the ones this node lists itself rather than another. Masters are `:q3`,
  `:q2`, `:qw`, `:gs`, `:ue2` and the labels of labelled listeners.

      bin/exmaster rpc 'IO.inspect(Exmaster.stats())'
  """
  def stats do
    now = now()

    for {name, store} <- stores(), into: %{} do
      entries = Store.all(store, now)
      games = Enum.frequencies_by(entries, fn {_, e} -> e.game end)
      {name, %{servers: length(entries), local: Store.local_count(store, now), games: games}}
    end
  end

  @doc """
  The servers a master (`:q3`, `:q2`, `:qw`, `:gs`, `:ue2` or a label,
  such as `"UrbanTerror"`) lists, sorted by address.
  """
  def servers(master) do
    now = now()
    {_, store} = List.keyfind!(stores(), master, 0)

    store
    |> Store.all(now)
    |> Enum.sort()
    |> Enum.map(fn {addr, e} ->
      e
      |> Map.take([:game, :protocol, :version, :clients, :max_clients, :hostname])
      |> Map.put(:address, Addr.to_string(addr))
      |> Map.put(:expires_in, div(e.expires - now, 1000))
    end)
  end

  defp stores,
    do:
      Exmaster.Config.stores(
        Exmaster.Config.listeners!(Application.fetch_env!(:exmaster, :listen))
      )
end
