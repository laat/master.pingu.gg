defmodule Exmaster.Q3.Master do
  @moduledoc """
  The Quake 3 master: dpmaster's protocol (see
  `docs/quake3.md`).

  Only an `infoResponse` that echoes a valid challenge is trusted. A
  heartbeat from an address that isn't listed gets a `getinfo` with a
  stateless challenge (`Exmaster.Q3.Challenge`) and stores nothing; the
  server is listed once it answers, for `server_ttl`, and each heartbeat
  after that has it asked again (see "Asking listed servers again" below).
  """
  @behaviour Exmaster.Protocol

  alias Exmaster.{Addr, RateLimit, Store}
  alias Exmaster.Q3
  alias Exmaster.Q3.Challenge
  alias Exmaster.Q3.Games
  require Logger

  # A heartbeat from an address that isn't listed has the master send a
  # getinfo to it, so a forged one has it send to anyone: 64 at once per
  # IP, for hosts that start all their servers together, then one a
  # second. A cap for all IPs together would let forged heartbeats keep
  # new servers out, and a getinfo is no larger than the heartbeat.
  @heartbeat_limit {1, 1_000, 64}
  # getservers: 5 at once per IP, then one every 3 seconds.
  @query_limit {1, 3_000, 5}
  # Protocols remembered per server. The most seen is four, on RTCW servers
  # rotating through 50, 57, 59 and 60 to get onto every list.
  @max_protocols 8
  @hostname_length 63

  @impl true
  def name, do: "Quake 3"

  @impl true
  def family, do: :inet6

  @impl true
  def store, do: :exmaster_q3

  @impl true
  def init(_now), do: %{deferred: %{}, checks: %{}}

  @impl true
  def handle_packet(data, from, ctx, now, state) do
    case Q3.split_command(data) do
      {:ok, "heartbeat", tag} -> heartbeat(Q3.trim(tag), from, ctx, now, state)
      {:ok, "infoResponse", payload} -> {info_response(payload, from, ctx, now), state}
      {:ok, "getservers", payload} -> {get_servers(payload, false, from, ctx, now), state}
      {:ok, "getserversExt", payload} -> {get_servers(payload, true, from, ctx, now), state}
      _ -> {[], state}
    end
  end

  @impl true
  def tick(ctx, now, state) do
    {addrs, restarted, state} = due_polls(ctx, now, state)

    polls =
      for addr <- addrs,
          entry = Store.lookup(ctx.store, addr, now),
          entry != nil,
          do: getinfo(addr, entry.class, ctx, now)

    # Restarted servers, no longer listed, are asked as for any heartbeat
    # from an address that isn't.
    probes =
      for {{ip, _} = addr, entry} <- restarted,
          RateLimit.take({:q3, :heartbeat, ip}, @heartbeat_limit, 1, now) == :ok,
          do: getinfo(addr, entry.class, ctx, now)

    {polls ++ probes, state}
  end

  # Classes, by the index the challenge carries. :known goes with the game
  # the tag implies; :darkplaces and :unknown servers must name their game.
  # :unknown ones can't be listed as a built-in game unless a label says so,
  # and there are at most max_unknown_tag of them.
  def classes, do: [:darkplaces, :unknown] ++ for(g <- Games.all(), do: {:known, g.name})

  def classify(tag) do
    cond do
      game = Games.by_heartbeat(tag) -> {:known, game.name}
      tag == Games.darkplaces() -> :darkplaces
      true -> :unknown
    end
  end

  defp heartbeat(tag, from, ctx, now, state) do
    cond do
      not Q3.valid_name?(tag, Q3.max_name_length()) ->
        {[], state}

      Games.flatline?(tag) ->
        flatline(from, ctx, now, state)

      entry = Store.lookup(ctx.store, from, now) ->
        # A heartbeat with another tag doesn't reclassify a listed server,
        # since heartbeats can be forged. The new tag applies once the
        # server has expired.
        case entry.via == ctx.id && poll_for_heartbeat(state, ctx, from, now) do
          {:now, state} -> {[getinfo(from, entry.class, ctx, now)], state}
          {:later, state} -> {[], state}
          false -> {[], state}
        end

      RateLimit.take({:q3, :heartbeat, elem(from, 0)}, @heartbeat_limit, 1, now) == :ok ->
        {[getinfo(from, classify(tag), ctx, now)], state}

      true ->
        {[], state}
    end
  end

  defp flatline(from, ctx, now, state) do
    with %{via: via} = entry when via == ctx.id <- Store.lookup(ctx.store, from, now),
         {:now, state} <- poll_for_shutdown(state, ctx, from, now) do
      {[getinfo(from, entry.class, ctx, now)], state}
    else
      {:later, state} -> {[], state}
      {:skip, state} -> {[], state}
      _ -> {[], state}
    end
  end

  defp getinfo(addr, class, ctx, now) do
    index = Enum.find_index(classes(), &(&1 == class))
    {Q3.packet("getinfo", [Challenge.issue(addr, index, ctx.id, now, ctx.challenge_ttl)]), addr}
  end

  defp info_response(payload, from, ctx, now) do
    info = Q3.parse_info(payload)

    with {:ok, index} <-
           Challenge.check(from, Map.get(info, "challenge"), ctx.id, now, ctx.challenge_ttl),
         class when class != nil <- Enum.at(classes(), index),
         {:ok, :added, entry} <- register(info, class, from, ctx, now) do
      registered(ctx, from, now)

      Logger.info(
        "q3: #{Addr.to_string(from)} verified, game=#{entry.game} protocol=#{entry.protocol}"
      )
    else
      {:reject, reason} ->
        Logger.warning("q3: infoResponse from #{Addr.to_string(from)} rejected: #{reason}")

      {:error, reason} ->
        Logger.warning("q3: #{Addr.to_string(from)} not listed: #{reason}")

      _ ->
        :bad_challenge
    end

    []
  end

  # Builds the entry from the server's current one and writes it if that is
  # still current: another listener may have replied for the same server in
  # between, and its protocols or its first registration would be lost.
  defp register(info, class, from, ctx, now, tries \\ 3) do
    existing = Store.lookup(ctx.store, from, now)

    with {:ok, entry} <- entry(info, existing || %{class: class}, ctx, now) do
      case Store.put(ctx.store, from, entry, now, existing) do
        :ok -> {:ok, if(existing, do: :updated, else: :added), entry}
        {:error, :changed} when tries > 1 -> register(info, class, from, ctx, now, tries - 1)
        error -> error
      end
    end
  end

  # The entry for a server that answered a challenge. old is the server's
  # entry, or for one that isn't listed yet just the class its challenge
  # carried.
  defp entry(info, old, ctx, now) do
    class = old.class
    label = ctx.label
    protocol = Q3.leading_int(info["protocol"])
    max_clients = Q3.int(info["sv_maxclients"])
    gametype = Map.get(info, "gametype", "0")
    game = game_name(info, class, label)

    cond do
      protocol == nil ->
        {:reject, "invalid protocol"}

      max_clients == nil or max_clients <= 0 ->
        {:reject, "invalid sv_maxclients"}

      not Q3.valid_name?(gametype, Q3.max_gametype_length()) ->
        {:reject, "invalid gametype"}

      game in [nil, ""] ->
        {:reject, "no game name"}

      not Q3.valid_name?(game, Q3.max_name_length()) ->
        {:reject, "invalid gamename"}

      class == :unknown and label == nil and Games.builtin?(game) ->
        {:reject, "unknown heartbeat tag claims a built-in game"}

      true ->
        {:ok,
         %{
           class: class,
           unknown: class == :unknown,
           via: Map.get(old, :via, ctx.id),
           game: game,
           protocol: protocol,
           protocols: protocols(Map.get(old, :protocols, %{}), protocol, now, ctx.server_ttl),
           gametype: gametype,
           # Call of Duty servers leave clients out when nobody is on.
           clients: Q3.int(info["clients"]) || 0,
           max_clients: max_clients,
           hostname: info |> Map.get("hostname", "") |> binary_slice(0, @hostname_length),
           seen: now,
           expires: now + ctx.server_ttl,
           verified: Map.get(old, :verified, now)
         }}
    end
  end

  @doc """
  The game a server is listed as. In order:

    1. The listener's label: a labelled listener is a game's own master,
       and Urban Terror says Quake3Arena or nothing.
    2. gamename.
    3. The game the heartbeat tag implies.
  """
  def game_name(info, class, label) do
    gamename = Map.get(info, "gamename")

    cond do
      label -> label
      gamename -> gamename
      match?({:known, _}, class) -> elem(class, 1)
      true -> nil
    end
  end

  # Some servers answer with a different protocol from one reply to the
  # next, to be listed for several client versions, so every protocol a
  # server reported in the last server_ttl is kept, the oldest dropped
  # past @max_protocols.
  defp protocols(old, protocol, now, ttl) do
    recent = Map.reject(old, fn {_, at} -> now - at > ttl end)

    recent
    |> Enum.sort_by(fn {_, at} -> at end, :desc)
    |> Enum.reject(fn {p, _} -> p == protocol end)
    |> Enum.take(@max_protocols - 1)
    |> Map.new()
    |> Map.put(protocol, now)
  end

  defp get_servers(payload, ext, {ip, _} = from, ctx, now) do
    with :ok <- RateLimit.take({:q3, :query, ip}, @query_limit, 1, now),
         {:ok, q} <- Q3.parse_query(payload, ext),
         :ok <- RateLimit.reserve_reply(now),
         packets = Q3.encode_list(match(q, ctx, now), ext),
         :ok <- RateLimit.charge_reply(packets |> Enum.map(&byte_size/1) |> Enum.sum(), now) do
      for p <- packets, do: {p, from}
    else
      _ -> []
    end
  end

  @doc "The servers that answer a query, sorted by address."
  def match(q, ctx, now) do
    # A labelled listener has a store of its own, and every server in it
    # is its game's, whatever name a query gives it: Smokin' Guns asks
    # for smokinguns. An anonymous query elsewhere asks for the game of
    # its protocol, and one for an unknown protocol matches on protocol
    # alone.
    game =
      if ctx.label == nil do
        q.game ||
          case Games.by_protocol(q.protocol) do
            nil -> nil
            g -> g.name
          end
      end

    # A label can be a built-in game's: q3:27955=et is ET's own master.
    {empty, full} =
      case Games.by_name(game || ctx.label) do
        %{always_empty_full: true} -> {true, true}
        _ -> {q.empty, q.full}
      end

    for {addr, e} <- Store.all(ctx.store, now, game),
        speaks?(e, q.protocol, now, ctx.server_ttl),
        empty or e.clients > 0,
        full or e.clients < e.max_clients,
        q.gametype == nil or e.gametype == q.gametype,
        if(Addr.ipv4?(addr), do: q.ipv4, else: q.ipv6) do
      addr
    end
    |> Enum.sort()
  end

  defp speaks?(e, protocol, now, ttl) do
    case e.protocols do
      %{^protocol => at} -> now - at <= ttl
      _ -> false
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
  # A flatline (WolfFlatline-1, ETFlatline-1, Tremulousdead, Call of
  # Duty's flatline) can be forged too, so it isn't taken as one: the
  # server is asked, and dropped if it doesn't answer within 10 seconds of
  # that. The check shares the once-a-minute allowance with heartbeats: a
  # second query soon after the first could fall to the server's own flood
  # protection (DarkPlaces drops a query within a second of the last), and
  # a forged flatline would get a healthy server dropped. A flatline inside
  # the minute has the check wait for its end. The query a server answered
  # to register counts as its first.
  #
  # The minute is each store's: a server listed by the Quake 3 master and
  # a labelled one is asked by each, on its own heartbeats. But they
  # usually share an address, and the server's flood protection counts
  # queries by IP, so the stores' polls and checks of a server wait for 2
  # seconds after the last (@spacing); one that would come sooner is sent
  # when they are over. Each store asks at most once a minute, so a query
  # put off gets through after one refusal per other store at most.
  #
  # The first query to a server a store doesn't list goes out at once and
  # spends nothing of the spacing: anyone can forge a heartbeat, and first
  # queries that took the spacing could keep it from the listed servers.
  # A DarkPlaces server one master asks for the first time while another
  # asks it again may drop the second query: a poll it drops is made at
  # its next heartbeat, but a shutdown check it drops has it delisted
  # until then, and a forged heartbeat to the one master and a forged
  # flatline to the other can arrange that.
  #
  # state.deferred is addr => {due, :poll | :check}, state.checks addr =>
  # when the check's query went out. Both are this listener's: a server is
  # only asked through the listener it is listed through.

  @gap {1, 60_000, 1}
  @spacing {1, 2_000, 1}
  @check_window 10_000

  # A query needs both. The minute is looked at first and taken last, so a
  # query that one of them refuses spends neither: the spacing taken for a
  # query the minute then refused would put off the next by 2 seconds, and
  # the minute taken for one the spacing then refused would cost a minute.
  defp take_poll(ctx, addr, now) do
    with :ok <- RateLimit.check(poll_key(ctx, addr), @gap, 1, now),
         :ok <- RateLimit.take(spacing_key(addr), @spacing, 1, now),
         do: RateLimit.take(poll_key(ctx, addr), @gap, 1, now)
  end

  # A heartbeat from a listed server: {:now, state} to ask it, or
  # {:later, state}. A check waiting for the minute becomes this query.
  defp poll_for_heartbeat(state, ctx, addr, now) do
    case take_poll(ctx, addr, now) do
      :ok -> {:now, sent(state, addr, now, :poll)}
      {:error, wait} -> {:later, defer(state, addr, now + wait, :poll)}
    end
  end

  # A shutdown from a listed server: {:now, state} to ask it, {:later,
  # state} if it will be asked at the end of the minute, or {:skip, state}
  # if a check is under way.
  defp poll_for_shutdown(state, ctx, addr, now) do
    if Map.has_key?(state.checks, addr) do
      {:skip, state}
    else
      case take_poll(ctx, addr, now) do
        :ok -> {:now, sent(state, addr, now, :check)}
        {:error, wait} -> {:later, defer(state, addr, now + wait, :check)}
      end
    end
  end

  # A server was just registered: its minute starts now, even if one from
  # an earlier listing of the address was still running.
  defp registered(ctx, addr, now), do: RateLimit.drain(poll_key(ctx, addr), @gap, now)

  defp poll_key(ctx, addr), do: {:q3, :poll, ctx.store, addr}
  defp spacing_key(addr), do: {:q3, :spacing, addr}

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
             :ok <- take_poll(ctx, addr, now) do
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
end
