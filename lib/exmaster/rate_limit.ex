defmodule Exmaster.RateLimit do
  @moduledoc """
  Token buckets the listeners share, in a public ETS table this process
  owns and sweeps.

  A bucket is GCRA: the time at which it would be full again. `take/4`
  reads it and writes the new one with compare-and-swap
  (`:ets.select_replace/2`), so listeners on different sockets can spend
  from one bucket without a process in between. A bucket that is full
  again is the same as none, and the sweep drops it, so buckets keyed by
  forged source addresses don't pile up.

  A limit is `{rate, per, burst}`: `rate` tokens every `per` milliseconds,
  up to `burst`. A bucket counts time in units of 1/rate ms, so a token is
  exactly `per` units and nothing is lost to rounding, however small the
  costs (bytes, at 262,144 a second).
  """
  use GenServer

  @table __MODULE__
  @sweep_interval 1_000

  # Replies to server list queries, to all clients of all masters
  # together: 256 KB a second, bursts of 1 MB. A 27-byte query can get
  # kilobytes back, and its source address can be forged and changed from
  # one query to the next, so the per-IP limits alone would let the master
  # flood someone else's network with server lists.
  @replies {262_144, 1_000, 1_048_576}
  # Each reply costs at least a full packet, so queries that match nothing
  # still pay for scanning the table.
  @min_reply 1_400

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Spends cost tokens from the bucket key: `:ok`, or `{:error, ms}` until there would be enough."
  def take(key, {rate, per, burst} = limit, cost, now) do
    # Rows are {key, tat, rate}, tat in units of 1/rate ms.
    t = now * rate
    inc = cost * per
    tau = burst * per

    case :ets.lookup(@table, key) do
      [] ->
        tat = t + inc

        cond do
          tat - t > tau -> {:error, wait(tat - t - tau, rate)}
          :ets.insert_new(@table, {key, tat, rate}) -> :ok
          true -> take(key, limit, cost, now)
        end

      [{_, old, _}] ->
        tat = max(old, t) + inc

        cond do
          tat - t > tau ->
            {:error, wait(tat - t - tau, rate)}

          :ets.select_replace(@table, [{{key, old, rate}, [], [{:const, {key, tat, rate}}]}]) ==
              1 ->
            :ok

          true ->
            take(key, limit, cost, now)
        end
    end
  end

  defp wait(units, rate), do: div(units + rate - 1, rate)

  @doc """
  Empties the bucket key as of now, however full or spent it was: nothing
  passes until it has refilled from empty.
  """
  def drain(key, {rate, per, burst} = limit, now) do
    tat = now * rate + burst * per

    case :ets.lookup(@table, key) do
      [] ->
        :ets.insert_new(@table, {key, tat, rate}) || drain(key, limit, now)

      [{_, old, _}] when old >= tat ->
        true

      [{_, old, _}] ->
        :ets.select_replace(@table, [{{key, old, rate}, [], [{:const, {key, tat, rate}}]}]) == 1 ||
          drain(key, limit, now)
    end

    :ok
  end

  @doc "Reserves the least a server list reply costs, before the list is made."
  def reserve_reply(now), do: take(:replies, @replies, @min_reply, now)

  @doc "Charges the rest of a reply of size bytes, once reserve_reply/1 has passed."
  def charge_reply(size, _now) when size <= @min_reply, do: :ok
  def charge_reply(size, now), do: take(:replies, @replies, size - @min_reply, now)

  @doc false
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(nil) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    Process.send_after(self(), :sweep, @sweep_interval)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(Exmaster.now())
    Process.send_after(self(), :sweep, @sweep_interval)
    {:noreply, state}
  end

  @doc false
  def sweep(now),
    do:
      :ets.select_delete(@table, [{{:_, :"$1", :"$2"}, [{:<, :"$1", {:*, :"$2", now}}], [true]}])
end
