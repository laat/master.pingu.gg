defmodule Exmaster.Store do
  @moduledoc """
  The servers one master lists, in an ETS table that this process owns and
  alone writes to. Listeners read the table directly; they ask this process
  to add, replace or drop a server, so the limits are checked against one
  consistent count.

  Rows are `{addr, expires, game, entry}`. An entry is a map with at least
  `:expires`, `:seen` (when the server last answered), `:game` and
  `:clients`. Entries with `unknown: true` count toward `max_unknown_tag`.

  Expired rows are dropped every 5 seconds; until then lookups skip them.
  """
  use GenServer
  require Logger

  alias Exmaster.Addr

  @sweep_interval 5_000

  def child_spec(opts),
    do: %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "The entry for addr, or nil if there is none or it has expired."
  def lookup(store, addr, now) do
    case :ets.lookup(store, addr) do
      [{_, expires, _, entry}] when expires > now -> entry
      _ -> nil
    end
  end

  @doc "`{addr, entry}` for every server that hasn't expired, of one of games if given."
  def all(store, now, games \\ nil) do
    guards = [{:>, :"$2", now} | game_guard(games)]
    :ets.select(store, [{{:"$1", :"$2", :"$3", :"$4"}, guards, [{{:"$1", :"$4"}}]}])
  end

  defp game_guard(nil), do: []
  defp game_guard([game]), do: [{:==, :"$3", game}]
  defp game_guard(games), do: [List.to_tuple([:orelse | Enum.map(games, &{:==, :"$3", &1})])]

  @doc """
  Adds or replaces the server at addr, if its entry is still expected (nil
  for none), as a listener read it with lookup/3: `{:error, :changed}`
  otherwise. Listeners build an entry from the one before, and two of them
  can answer for one server at once.

  A server is refused if the table is full, its IP has `max_per_ip`
  servers, or it is `unknown` and there are `max_unknown_tag` of those.
  """
  def put(store, addr, entry, now, expected),
    do: GenServer.call(store, {:put, addr, entry, now, expected})

  @doc """
  Drops the server at addr, if it is listed through via, unless it has
  answered since since: `{:dropped, entry}` or `:kept`.
  """
  def drop_unless_seen(store, addr, since, via),
    do: GenServer.call(store, {:drop_unless_seen, addr, since, via})

  @doc false
  def sweep(store, now), do: GenServer.call(store, {:sweep, now})

  @doc false
  def clear(store), do: GenServer.call(store, :clear)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = :ets.new(name, [:named_table, :set, :protected, read_concurrency: true])

    env = fn key ->
      Keyword.get_lazy(opts, key, fn -> Application.fetch_env!(:exmaster, key) end)
    end

    state = %{
      table: table,
      label:
        Keyword.get(
          opts,
          :label,
          name |> Atom.to_string() |> String.replace_prefix("exmaster_", "")
        ),
      max_servers: env.(:max_servers),
      max_per_ip: env.(:max_per_ip),
      max_unknown: env.(:max_unknown_tag),
      per_ip: %{},
      unknown: 0
    }

    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, state}
  end

  @impl true
  def handle_call({:put, addr, entry, now, expected}, _from, state) do
    case :ets.lookup(state.table, addr) do
      [{_, expires, _, old}] when expires > now and old != expected ->
        {:reply, {:error, :changed}, state}

      [{_, expires, _, old}] when expires > now ->
        if unknown(entry) > unknown(old) and state.unknown >= state.max_unknown do
          {:reply, {:error, :too_many_unknown_tags}, state}
        else
          insert(state, addr, entry)
          {:reply, :ok, %{state | unknown: state.unknown - unknown(old) + unknown(entry)}}
        end

      _rows when expected != nil ->
        {:reply, {:error, :changed}, state}

      rows ->
        state = Enum.reduce(rows, state, &remove(&2, &1))
        {ip, _} = addr

        cond do
          :ets.info(state.table, :size) >= state.max_servers ->
            {:reply, {:error, :full}, state}

          Map.get(state.per_ip, ip, 0) >= state.max_per_ip ->
            {:reply, {:error, :too_many_on_ip}, state}

          unknown(entry) == 1 and state.unknown >= state.max_unknown ->
            {:reply, {:error, :too_many_unknown_tags}, state}

          true ->
            insert(state, addr, entry)

            {:reply, :ok,
             %{
               state
               | per_ip: Map.update(state.per_ip, ip, 1, &(&1 + 1)),
                 unknown: state.unknown + unknown(entry)
             }}
        end
    end
  end

  def handle_call({:drop_unless_seen, addr, since, via}, _from, state) do
    case :ets.lookup(state.table, addr) do
      [{_, _, _, %{via: ^via} = entry} = row] when entry.seen < since ->
        Logger.info("#{state.label}: #{Addr.to_string(addr)} shut down")
        {:reply, {:dropped, entry}, remove(state, row)}

      _ ->
        {:reply, :kept, state}
    end
  end

  def handle_call({:sweep, now}, _from, state), do: {:reply, :ok, sweep_expired(state, now)}

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, %{state | per_ip: %{}, unknown: 0}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, sweep_expired(state, Exmaster.now())}
  end

  defp sweep_expired(state, now) do
    rows = :ets.select(state.table, [{{:_, :"$1", :_, :_}, [{:"=<", :"$1", now}], [:"$_"]}])

    Enum.reduce(rows, state, fn {addr, _, game, _} = row, state ->
      Logger.info("#{state.label}: #{Addr.to_string(addr)} timed out, game=#{game}")
      remove(state, row)
    end)
  end

  defp insert(state, addr, entry),
    do: :ets.insert(state.table, {addr, entry.expires, entry.game, entry})

  defp remove(state, {{ip, _} = addr, _, _, entry}) do
    :ets.delete(state.table, addr)

    per_ip =
      case Map.fetch!(state.per_ip, ip) do
        1 -> Map.delete(state.per_ip, ip)
        n -> Map.put(state.per_ip, ip, n - 1)
      end

    %{state | per_ip: per_ip, unknown: state.unknown - unknown(entry)}
  end

  defp unknown(%{unknown: true}), do: 1
  defp unknown(_), do: 0
end
