defmodule Exmaster.ListGate do
  @moduledoc """
  How many servers the TCP lists being made and sent may hold at once,
  all masters together: 16,384, and a quarter of that for the lists of
  one client IP. A list is admitted before its servers are read from the
  store, at a weight its master gives it, about the servers it could
  hold, and again once they are read, at what it holds then: the store
  may have grown in between. It keeps its weight until its task ends.

  A list that would take the total, or its IP's, over is refused. A list
  is always admitted when nothing is held, and an IP's first list when
  the total has room for it, so a list larger than an IP's share still
  goes out, and one larger than the whole goes out alone.

  The reply budget (`Exmaster.RateLimit`) bounds the bytes that go out,
  not the lists that wait for it: each keeps its servers while it waits,
  up to a minute (`Exmaster.Paid`). Without a bound, every connection
  slot of every TCP master could hold a whole list at once.
  """
  use GenServer

  @capacity 16_384
  @per_ip div(@capacity, 4)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Admits the calling process's list, for a client at ip, at weight: `:ok`,
  kept until the process ends, or `:busy`. A process has one list: asked
  again, it is weighed again, and keeps its old weight if refused.
  """
  def admit(ip, weight), do: GenServer.call(__MODULE__, {:admit, ip, weight})

  @doc "The most the lists admitted at once may weigh."
  def capacity, do: @capacity

  @doc "The most one IP's lists may weigh at once, but for its first."
  def per_ip, do: @per_ip

  @impl true
  def init(nil), do: {:ok, %{held: %{}, ips: %{}, total: 0}}

  @impl true
  def handle_call({:admit, ip, weight}, {pid, _}, state) do
    {ip, old} = Map.get(state.held, pid, {ip, 0})
    total = state.total - old
    on_ip = Map.get(state.ips, ip, 0) - old

    cond do
      weight > old and total > 0 and total + weight > @capacity ->
        {:reply, :busy, state}

      weight > old and on_ip > 0 and on_ip + weight > @per_ip ->
        {:reply, :busy, state}

      true ->
        unless Map.has_key?(state.held, pid), do: Process.monitor(pid)
        state = %{state | held: Map.put(state.held, pid, {ip, weight})}
        {:reply, :ok, add(state, ip, weight - old)}
    end
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, state) do
    case Map.pop(state.held, pid) do
      {nil, _} -> {:noreply, state}
      {{ip, weight}, held} -> {:noreply, add(%{state | held: held}, ip, -weight)}
    end
  end

  defp add(state, ip, n) do
    ips =
      case Map.get(state.ips, ip, 0) + n do
        0 -> Map.delete(state.ips, ip)
        m -> Map.put(state.ips, ip, m)
      end

    %{state | ips: ips, total: state.total + n}
  end
end
