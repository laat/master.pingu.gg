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

  ## Other nodes

  With several nodes behind one DNS name, a game server heartbeats one of
  them and a client asks one of them, maybe another. So each store sends
  the servers it lists to the same master's store on the other nodes, which
  keep them in a second table, `:"<name> replicas"`, keyed by `{addr, node}`.
  The space keeps it apart from every store's name: a label has none.
  `all/3` answers from both; `lookup/3`, `put/5` and the limits only see
  this node's own servers, the ones its listeners ask and check.

  The stores of one master are a `pg` group. A store sends each server it
  adds, replaces or drops to the others, and its whole list to a store that
  joins, which replaces what the joiner had from it: after a restart, or
  when two nodes find each other again after a split. Messages between two
  processes arrive in order, so a list and the changes after it can't be
  swapped. A copy that stops being refreshed expires like any entry, so
  servers a node listed before it went away stay listed until then, and a
  split heals by itself. If the `pg` scope restarts, which forgets its
  groups, each store joins again and sends its list.

  `Exmaster.now/0` is a monotonic clock, which differs from node to node,
  so entries travel with their times on the OS clock, which NTP keeps the
  same on every host. Each node converts with its own offset between the
  two, so time an entry spends in transit or in a mailbox counts against
  it.
  """
  use GenServer
  require Logger

  alias Exmaster.Addr

  @sweep_interval 5_000
  @scope Exmaster.PG
  # Match patterns binding address, expiry, game and entry, for the rows of
  # this node's servers and of the others'.
  @local {:"$1", :"$2", :"$3", :"$4"}
  @replica {{:"$1", :_}, :"$2", :"$3", :"$4"}

  @doc "The `pg` scope the stores' groups are in."
  def scope, do: @scope

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

  @doc """
  `{addr, entry}` for every server that hasn't expired, of game if given,
  listed by this node or another. A server two nodes list is there
  once, as the copy that expires last has it: the one from the node that
  heard from it last. That copy decides its game too.
  """
  def all(store, now, game \\ nil) do
    local = select(store, @local, now, game)

    if :ets.info(replicas(store), :size) == 0 do
      local
    else
      entries = newest(local ++ select(replicas(store), @replica, now, game))
      if game, do: drop_superseded(entries, store, now, game), else: entries
    end
  end

  @doc "The number of servers this node lists itself."
  def local_count(store, now),
    do: :ets.select_count(store, [{{:_, :"$1", :_, :_}, [{:>, :"$1", now}], [true]}])

  defp select(table, pattern, now, game) do
    guards = [{:>, :"$2", now} | game_guard(game)]
    :ets.select(table, [{pattern, guards, [{{:"$1", :"$4"}}]}])
  end

  defp newest(entries) do
    entries
    |> Enum.reduce(%{}, fn {addr, e}, acc ->
      Map.update(acc, addr, e, &if(&1.expires >= e.expires, do: &1, else: e))
    end)
    |> Map.to_list()
  end

  # Drops the servers that have a newer copy of another game.
  defp drop_superseded(entries, store, now, game) do
    guards = [{:>, :"$2", now}, {:"=/=", :"$3", game}]

    others =
      for {table, pattern} <- [{store, @local}, {replicas(store), @replica}],
          {addr, expires} <- :ets.select(table, [{pattern, guards, [{{:"$1", :"$2"}}]}]),
          reduce: %{} do
        acc -> Map.update(acc, addr, expires, &max(&1, expires))
      end

    Enum.reject(entries, fn {addr, e} ->
      case others do
        %{^addr => expires} -> expires > e.expires
        _ -> false
      end
    end)
  end

  defp replicas(store), do: :"#{store} replicas"

  defp game_guard(nil), do: []
  defp game_guard(game), do: [{:"=:=", :"$3", game}]

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

    replicas =
      :ets.new(replicas(name), [:named_table, :set, :protected, read_concurrency: true])

    env = fn key ->
      Keyword.get_lazy(opts, key, fn -> Application.fetch_env!(:exmaster, key) end)
    end

    state = %{
      table: table,
      replicas: replicas,
      group: {__MODULE__, name},
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
    # The list is empty, but it clears what the others still have from this
    # store's last run.
    {:ok, join_group(state)}
  end

  # Joins the group, watches it and the scope, and sends this store's list
  # to the others.
  defp join_group(state) do
    scope = Process.monitor(Process.whereis(@scope))
    :ok = :pg.join(@scope, state.group, self())
    {ref, members} = :pg.monitor(@scope, state.group)
    send_list(state, others(members))
    Map.merge(state, %{monitor: ref, scope: scope})
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
          replicate(state, {:put, addr, entry})
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
            replicate(state, {:put, addr, entry})

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
        replicate(state, {:drop, addr})
        {:reply, {:dropped, entry}, remove(state, row)}

      _ ->
        {:reply, :kept, state}
    end
  end

  def handle_call({:sweep, now}, _from, state), do: {:reply, :ok, sweep_expired(state, now)}

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    :ets.delete_all_objects(state.replicas)
    replicate(state, {:list, []})
    {:reply, :ok, %{state | per_ip: %{}, unknown: 0}}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, sweep_expired(state, Exmaster.now())}
  end

  # The scope restarted and forgot the group. The others may have missed
  # changes since, so the list goes out again on joining.
  def handle_info({:DOWN, ref, :process, _, _}, %{scope: ref} = state) do
    send(self(), :join_group)
    {:noreply, %{state | monitor: nil, scope: nil}}
  end

  def handle_info(:join_group, state) do
    if Process.whereis(@scope) do
      {:noreply, join_group(state)}
    else
      Process.send_after(self(), :join_group, 100)
      {:noreply, state}
    end
  end

  def handle_info({ref, :join, _group, pids}, %{monitor: ref} = state) do
    send_list(state, others(pids))
    {:noreply, state}
  end

  # A store that leaves, with its node or not, may come back; its servers
  # stay listed until they expire or it sends its list again.
  def handle_info({ref, :leave, _group, _pids}, %{monitor: ref} = state), do: {:noreply, state}

  def handle_info({:replica, from, msg}, state) do
    shift = -os_offset()

    case msg do
      {:put, addr, entry} ->
        insert_replica(state, from, addr, entry, shift)

      {:drop, addr} ->
        :ets.delete(state.replicas, {addr, from})

      {:list, entries} ->
        :ets.match_delete(state.replicas, {{:_, from}, :_, :_, :_})
        for {addr, entry} <- entries, do: insert_replica(state, from, addr, entry, shift)
    end

    {:noreply, state}
  end

  defp others(pids), do: Enum.reject(pids, &(node(&1) == node()))

  defp replicate(state, msg) do
    case others(members(state)) do
      [] -> :ok
      pids -> send_all(pids, msg)
    end
  end

  # Nobody while the scope restarts; the list goes out when it is back.
  defp members(state) do
    :pg.get_members(@scope, state.group)
  rescue
    ArgumentError -> []
  end

  defp send_list(_state, []), do: :ok

  defp send_list(state, pids),
    do:
      send_all(
        pids,
        {:list, select(state.table, @local, Exmaster.now(), nil)}
      )

  defp send_all(pids, msg) do
    d = os_offset()

    msg =
      case msg do
        {:put, addr, entry} -> {:put, addr, shift(entry, d)}
        {:list, entries} -> {:list, for({addr, e} <- entries, do: {addr, shift(e, d)})}
        msg -> msg
      end

    msg = {:replica, node(), msg}
    Enum.each(pids, &send(&1, msg))
  end

  # Adding it moves a time from Exmaster.now/0 to the OS clock.
  defp os_offset, do: System.os_time(:millisecond) - Exmaster.now()

  defp insert_replica(state, from, addr, entry, shift) do
    entry = shift(entry, shift)
    :ets.insert(state.replicas, {{addr, from}, entry.expires, entry.game, entry})
  end

  # Moves an entry's times by d: its own, and a Quake 3 server's protocols'.
  defp shift(entry, d) do
    Map.new(entry, fn
      {k, t} when k in [:seen, :expires, :verified] -> {k, t + d}
      {:protocols, ps} -> {:protocols, Map.new(ps, fn {p, at} -> {p, at + d} end)}
      kv -> kv
    end)
  end

  defp sweep_expired(state, now) do
    :ets.select_delete(state.replicas, [{{:_, :"$1", :_, :_}, [{:"=<", :"$1", now}], [true]}])
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
