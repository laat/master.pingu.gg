defmodule Exmaster.QW.Master do
  @moduledoc """
  The QuakeWorld master, on 27000 by default. Wire format in `Exmaster.QW`.

  QuakeWorld servers heartbeat with no challenge, and their reply to
  `status` echoes nothing the master sent. A heartbeat from an address
  that isn't listed gets `status`, and the address is noted (see "Whom the
  master asked" below); a reply is only taken from an address asked in the
  last 10 seconds, once. The server is listed for `server_ttl` after each
  reply, and each heartbeat has it asked again (see "Asking listed
  servers again" below).

  That keeps out servers that can't be reached, and makes a forged
  registration take a forged heartbeat and a forged reply. It is no proof
  that a server is at its address, as a Quake 3 challenge is: a blind
  spoofer can make up the reply. The per-IP limit keeps what one can list
  under someone else's IP to `max_per_ip` ports.

  QTV relays and qwfwd proxies heartbeat QuakeWorld masters too, and
  clients look for them there, so they are listed like servers.
  """
  @behaviour Exmaster.Protocol

  alias Exmaster.{Addr, RateLimit, Store}
  alias Exmaster.QW
  import Bitwise
  require Logger

  @window 10_000
  # A heartbeat from an address that isn't listed has the master send to
  # it, so a forged one has it send to anyone.
  @heartbeat_limit {1, 1_000, 64}
  @query_limit {1, 3_000, 5}
  @hostname_length 63

  @impl true
  def name, do: "QuakeWorld"

  @impl true
  def family, do: :inet

  @impl true
  def store, do: :exmaster_qw

  @impl true
  def init(now), do: %{pending: new_pending(now), deferred: %{}, checks: %{}}

  @impl true
  def handle_packet(data, from, ctx, now, state) do
    case QW.classify(data) do
      :query -> {query(from, ctx, now), state}
      :heartbeat -> heartbeat(from, ctx, now, state)
      :shutdown -> shutdown(from, ctx, now, state)
      {:status, payload} -> {status_reply(payload, from, ctx, now, state), state}
      :other -> {[], state}
    end
  end

  @impl true
  def tick(ctx, now, state) do
    {addrs, restarted, state} = due_polls(ctx, now, state)

    # Restarted servers, no longer listed, are asked as for any heartbeat
    # from an address that isn't.
    probes =
      for {{ip, _} = addr, _} <- restarted,
          RateLimit.take({:qw, :heartbeat, ip}, @heartbeat_limit, 1, now) == :ok,
          do: addr

    sends =
      for addr <- addrs ++ probes do
        asked(state.pending, addr, now)
        {QW.status(), addr}
      end

    {sends, state}
  end

  defp heartbeat(from, ctx, now, state) do
    cond do
      # A listed server is only asked through the listener it is listed
      # through: behind NAT it may take packets from that one only.
      entry = Store.lookup(ctx.store, from, now) ->
        case entry.via == ctx.id && poll_for_heartbeat(state, from, now) do
          {:now, state} -> {[status(from, now, state)], state}
          {:later, state} -> {[], state}
          false -> {[], state}
        end

      RateLimit.take({:qw, :heartbeat, elem(from, 0)}, @heartbeat_limit, 1, now) == :ok ->
        {[status(from, now, state)], state}

      true ->
        {[], state}
    end
  end

  # A shutdown can be forged, so it has the server asked; see "Asking
  # listed servers again" below.
  defp shutdown(from, ctx, now, state) do
    with %{via: via} when via == ctx.id <- Store.lookup(ctx.store, from, now),
         {:now, state} <- poll_for_shutdown(state, from, now) do
      {[status(from, now, state)], state}
    else
      {:later, state} -> {[], state}
      {:skip, state} -> {[], state}
      _ -> {[], state}
    end
  end

  defp status(addr, now, state) do
    asked(state.pending, addr, now)
    {QW.status(), addr}
  end

  defp status_reply(payload, from, ctx, now, state) do
    with true <- take_asked(state.pending, from, now),
         {info, clients} when map_size(info) > 0 <- QW.parse_status(payload) do
      case register(info, clients, from, ctx, now) do
        {:ok, :added, entry} ->
          registered(from, now)
          Logger.info("qw: #{Addr.to_string(from)} verified, game=#{entry.game}")

        {:ok, :updated, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("qw: #{Addr.to_string(from)} not listed: #{reason}")
      end
    end

    []
  end

  # Writes the entry if the server's current one is still what it was read
  # as: another listener may have written it in between.
  defp register(info, clients, from, ctx, now, tries \\ 3) do
    existing = Store.lookup(ctx.store, from, now)

    entry = %{
      game: QW.game(info),
      version: info |> Map.get("*version", "") |> binary_slice(0, @hostname_length),
      clients: clients,
      max_clients: QW.int(info["maxclients"]),
      hostname: info |> Map.get("hostname", "") |> binary_slice(0, @hostname_length),
      via: if(existing, do: existing.via, else: ctx.id),
      seen: now,
      expires: now + ctx.server_ttl,
      verified: if(existing, do: existing.verified, else: now)
    }

    case Store.put(ctx.store, from, entry, now, existing) do
      :ok -> {:ok, if(existing, do: :updated, else: :added), entry}
      {:error, :changed} when tries > 1 -> register(info, clients, from, ctx, now, tries - 1)
      error -> error
    end
  end

  defp query({ip, _} = from, ctx, now) do
    with :ok <- RateLimit.take({:qw, :query, ip}, @query_limit, 1, now),
         :ok <- RateLimit.reserve_reply(now),
         addrs = ctx.store |> Store.all(now) |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
         packets = QW.encode_list(addrs),
         :ok <- RateLimit.charge_reply(packets |> Enum.map(&byte_size/1) |> Enum.sum(), now) do
      for p <- packets, do: {p, from}
    else
      _ -> []
    end
  end

  # Asking listed servers again.
  #
  # A heartbeat from a listed server has it asked again, which is what
  # keeps it listed: only a reply refreshes the expiry. Heartbeats can be
  # forged with a listed server's address, so that happens at most once a
  # minute; a heartbeat inside the minute has the server asked when the
  # minute is over, as after a map change.
  #
  # A `C` (S2M_SHUTDOWN) can be forged too, so it isn't taken as one: the
  # server is asked, and dropped if it doesn't answer within 10 seconds of
  # that. The check shares the once-a-minute allowance with heartbeats: a
  # second query soon after the first could be dropped by the server's
  # flood protection, and a forged shutdown would get a healthy server
  # dropped. A shutdown inside the minute has the check wait for its end.
  # The query a server answered to register counts as its first.
  #
  # state.deferred is addr => {due, :poll | :check}, state.checks addr =>
  # when the check's query went out. Both are this listener's: a server is
  # only asked through the listener it is listed through.

  @gap {1, 60_000, 1}
  @check_window 10_000

  # A heartbeat from a listed server: {:now, state} to ask it, or
  # {:later, state}. A check waiting for the minute becomes this query.
  defp poll_for_heartbeat(state, addr, now) do
    case RateLimit.take({:qw, :poll, addr}, @gap, 1, now) do
      :ok -> {:now, sent(state, addr, now, :poll)}
      {:error, wait} -> {:later, defer(state, addr, now + wait, :poll)}
    end
  end

  # A shutdown from a listed server: {:now, state} to ask it, {:later,
  # state} if it will be asked at the end of the minute, or {:skip, state}
  # if a check is under way.
  defp poll_for_shutdown(state, addr, now) do
    if Map.has_key?(state.checks, addr) do
      {:skip, state}
    else
      case RateLimit.take({:qw, :poll, addr}, @gap, 1, now) do
        :ok -> {:now, sent(state, addr, now, :check)}
        {:error, wait} -> {:later, defer(state, addr, now + wait, :check)}
      end
    end
  end

  # A server was just registered: its minute starts now, even if one from
  # an earlier listing of the address was still running.
  defp registered(addr, now), do: RateLimit.drain({:qw, :poll, addr}, @gap, now)

  # A query of kind went out to addr: whatever was waiting is done, and a
  # check, this one or one that was waiting, starts its 10 seconds.
  defp sent(state, addr, now, kind) do
    {waiting, deferred} = Map.pop(state.deferred, addr)
    state = %{state | deferred: deferred}

    if kind == :check or match?({_, :check}, waiting),
      do: %{state | checks: Map.put_new(state.checks, addr, now)},
      else: state
  end

  defp defer(state, addr, due, kind) do
    deferred =
      Map.update(state.deferred, addr, {due, kind}, fn {d, k} ->
        {min(d, due), if(:check in [k, kind], do: :check, else: :poll)}
      end)

    %{state | deferred: deferred}
  end

  # Drops servers that didn't answer a shutdown check, and returns the
  # servers whose put-off poll or check is due, and those just dropped that
  # heartbeat after their check went out. A server that restarts sends a
  # shutdown and, a moment later, a heartbeat; the heartbeat is put off,
  # since the check spent the minute, and the check fails, since the old
  # instance is gone. Its heartbeat is then from an address that isn't
  # listed, and is answered as one. A server listed through another
  # listener since (after it expired, or the store restarted) is left to
  # that one.
  defp due_polls(ctx, now, state) do
    {done, checks} = Map.split_with(state.checks, fn {_, at} -> at + @check_window <= now end)

    {restarted, state} =
      Enum.reduce(done, {[], %{state | checks: checks}}, fn {addr, at}, {restarted, state} ->
        with {:dropped, entry} <- Store.drop_unless_seen(ctx.store, addr, at, ctx.id),
             {{_, :poll}, deferred} <- Map.pop(state.deferred, addr) do
          {[{addr, entry} | restarted], %{state | deferred: deferred}}
        else
          _ -> {restarted, state}
        end
      end)

    {due, deferred} = Map.split_with(state.deferred, fn {_, {at, _}} -> at <= now end)
    state = %{state | deferred: deferred}
    via = ctx.id

    {addrs, state} =
      Enum.reduce(due, {[], state}, fn {addr, {_, kind}}, {addrs, state} ->
        with %{via: ^via} <- Store.lookup(ctx.store, addr, now),
             :ok <- RateLimit.take({:qw, :poll, addr}, @gap, 1, now) do
          checks = if kind == :check, do: Map.put_new(state.checks, addr, now), else: state.checks
          {[addr | addrs], %{state | checks: checks}}
        else
          # Spent since: wait for it again rather than lose a check.
          {:error, wait} -> {addrs, defer(state, addr, now + wait, kind)}
          _ -> {addrs, state}
        end
      end)

    {addrs, restarted, state}
  end

  # Whom the master asked for status, so a reply is only taken from an
  # address that was asked in the last 10 seconds, once.
  #
  # A heartbeat from an address that isn't listed has to leave some state,
  # so this is a fixed table of slots (:atomics, owned by the listener)
  # rather than a map forged heartbeats could grow, or fill so real
  # servers were turned away. An address goes in the slot its salted hash
  # picks, over whatever was there. Under a flood of forged heartbeats a
  # real server's slot may be taken before it answers; it is asked again
  # at its next heartbeat. The salt is per table, so nobody can pick
  # addresses that land in a given server's slot. A slot holds a tag from
  # a second hash, so another address's reply doesn't match, and the time
  # the request went out.

  @slots 65_536
  @time_bits 40
  @tag_bits 23

  defp new_pending(now),
    do: %{
      slots: :atomics.new(@slots, signed: false),
      t0: now,
      salt: :crypto.strong_rand_bytes(16)
    }

  defp asked(p, addr, now) do
    # + 1, so a slot is never 0, which is empty.
    :atomics.put(p.slots, slot(p, addr), tag(p, addr) <<< @time_bits ||| now - p.t0 + 1)
  end

  defp take_asked(p, addr, now) do
    i = slot(p, addr)
    v = :atomics.get(p.slots, i)
    sent = (v &&& (1 <<< @time_bits) - 1) + p.t0 - 1

    if v != 0 and v >>> @time_bits == tag(p, addr) and now - sent <= @window do
      :atomics.put(p.slots, i, 0)
      true
    else
      false
    end
  end

  defp slot(p, addr), do: :erlang.phash2({p.salt, addr}, @slots) + 1
  defp tag(p, addr), do: :erlang.phash2({addr, p.salt}, 1 <<< @tag_bits)
end
