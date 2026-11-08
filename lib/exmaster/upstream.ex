defmodule Exmaster.Upstream do
  @moduledoc """
  Pulling server lists from other masters, the part with no protocol in
  it. A listener with upstreams (`EXMASTER_UPSTREAMS`, see
  `Exmaster.Config.upstreams!/2`) has their names looked up every 5
  minutes and hands its protocol the round (`pull/2`). The protocol keeps
  this state, sends the query `due/2` gives it, takes a reply as a list if
  it comes from a master `asked/3` names, queues the list (`listed/3`)
  and asks the servers `probes/1` hands it as if each had heartbeat.

  Nothing on a list is trusted: a server is only listed once it answers
  the master's own query, as for a heartbeat. The list only says whom to
  ask. A reply is taken from a master's address for 10 seconds after it
  was asked, so a forged list needs the master's address and the moment;
  and what one can have the master send is what a forged heartbeat can,
  under the same per-IP limit, at most 50 a tick.

  Queries go out 2 seconds apart, and 5 apart to one master: dpmaster
  takes 5 queries from an IP at once, then one every 3 seconds. A reply
  doesn't say which query it answers, so it goes with the last one sent to
  its master. Servers are asked at most 50 a tick, one a server however
  many lists have it, as the first list that had it says. A server the protocol
  can't ask yet goes back on the queue (`listed/3`), so the queue is the
  only way a list's servers are asked, and the 50 hold.
  """
  alias Exmaster.Addr

  @spacing 2_000
  @same_master 5_000
  @window 10_000
  @probes_per_tick 50
  @max_queued 65_536

  def new,
    do: %{
      queries: :queue.new(),
      next: nil,
      asked: %{},
      probes: :queue.new(),
      queued: MapSet.new()
    }

  @doc """
  Starts a round: targets are `{master address, upstream}`, asked in order.
  What is left of the last round is dropped.
  """
  def pull(u, targets), do: %{u | queries: :queue.from_list(targets)}

  @doc "The query to send now, as `[{master address, upstream}]` or `[]`."
  def due(u, now) do
    with {:value, {addr, upstream}} <- :queue.peek(u.queries),
         true <- u.next == nil or now >= u.next,
         true <- spaced?(u, addr, now) do
      {[{addr, upstream}],
       %{
         u
         | queries: :queue.drop(u.queries),
           next: now + @spacing,
           asked: Map.put(u.asked, addr, {now, upstream})
       }}
    else
      _ -> {[], u}
    end
  end

  # Times are monotonic, and may be negative.
  defp spaced?(u, addr, now) do
    case u.asked do
      %{^addr => {at, _}} -> now >= at + @same_master
      _ -> true
    end
  end

  @doc "The upstream whose master at addr was asked in the last 10 seconds, or nil."
  def asked(u, addr, now) do
    case u.asked do
      %{^addr => {at, upstream}} when now - at <= @window -> upstream
      _ -> nil
    end
  end

  @doc """
  Queues the servers on upstream's list to be asked: those with a public
  address that aren't queued already, up to 65,536.
  """
  def listed(u, addrs, upstream) do
    Enum.reduce(addrs, u, fn addr, u ->
      if Addr.public?(addr) and not MapSet.member?(u.queued, addr) and
           MapSet.size(u.queued) < @max_queued,
         do: %{
           u
           | probes: :queue.in({addr, upstream}, u.probes),
             queued: MapSet.put(u.queued, addr)
         },
         else: u
    end)
  end

  @doc "The next servers to ask, `{address, upstream}`, at most 50."
  def probes(u) do
    {taken, rest} = :queue.split(min(@probes_per_tick, MapSet.size(u.queued)), u.probes)
    taken = :queue.to_list(taken)
    queued = Enum.reduce(taken, u.queued, fn {addr, _}, q -> MapSet.delete(q, addr) end)
    {taken, %{u | probes: rest, queued: queued}}
  end
end
