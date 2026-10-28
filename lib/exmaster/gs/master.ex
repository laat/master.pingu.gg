defmodule Exmaster.GS.Master do
  @moduledoc """
  The GameSpy master's heartbeat side, on UDP 27900 by default: GameSpy's
  first protocol, as Battlefield 1942 speaks it. Wire format in
  `Exmaster.GS`; clients get the lists over TCP from
  `Exmaster.GS.ListServer`. See `docs/gamespy.md`.

  A heartbeat, `\\heartbeat\\<query port>\\gamename\\<game>`, comes from the
  server's query port. The master sends `\\info\\\\secure\\<challenge>` to
  that port at the heartbeat's IP, and lists the server at that address
  once a reply from there carries `\\validate\\` with the challenge's
  response under the game's key. Only the master and the server it asked
  know the challenge, so the reply proves the server is at its address;
  the key proves it runs the game. The challenges are stateless, like
  Quake 3's: forged heartbeats store nothing.

  The server is listed for `server_ttl` after each reply, and each
  heartbeat has it asked again (see "Asking listed servers again" below).
  `\\statechanged\\2` comes when it exits.
  """
  @behaviour Exmaster.Protocol

  alias Exmaster.{Addr, GS, RateLimit, Store}
  require Logger

  # As for the other masters: a heartbeat from an address that isn't
  # listed has the master send to it, so a forged one has it send to
  # anyone: 64 at once per IP, then one a second.
  @heartbeat_limit {1, 1_000, 64}
  @hostname_length 63

  # The games the master lists, in a fixed order: a challenge starts with
  # its game's place in it.
  @games ["bfield1942"]

  # Challenges: [A-Za-z0-9], the game's character then 15 of HMAC. Real
  # servers took up to 65, gsseckey's limit.
  @alphabet Enum.concat([?A..?Z, ?a..?z, ?0..?9]) |> List.to_string()
  @mac_length 15

  @impl true
  def name, do: "GameSpy"

  @impl true
  def family, do: :inet

  @impl true
  def store, do: :exmaster_gs

  @impl true
  def init(_now), do: %{deferred: %{}, checks: %{}}

  @doc "Makes the key challenges are signed with, random per boot."
  def init_key, do: :persistent_term.put({__MODULE__, :key}, :crypto.strong_rand_bytes(32))

  @impl true
  def handle_packet(data, {ip, _} = from, ctx, now, state) do
    info = GS.parse(data)

    cond do
      Map.has_key?(info, "heartbeat") -> heartbeat(info, ip, ctx, now, state)
      Map.has_key?(info, "validate") -> {reply(info, from, ctx, now), state}
      true -> {[], state}
    end
  end

  @impl true
  def tick(ctx, now, state) do
    {addrs, restarted, state} = due_polls(ctx, now, state)

    polls =
      for addr <- addrs,
          entry = Store.lookup(ctx.store, addr, now),
          entry != nil,
          do: query(addr, entry.game, ctx, now)

    # Restarted servers, no longer listed, are asked as for any heartbeat
    # from an address that isn't.
    probes =
      for {{ip, _} = addr, entry} <- restarted,
          RateLimit.take({:gs, :heartbeat, ip}, @heartbeat_limit, 1, now) == :ok,
          do: query(addr, entry.game, ctx, now)

    {polls ++ probes, state}
  end

  # The server is at the heartbeat's IP and the query port it names. Under
  # NAT the heartbeat's own port may be another, and clients query the
  # port it names.
  defp heartbeat(info, ip, ctx, now, state) do
    port = GS.int(info["heartbeat"])
    game = info["gamename"]
    addr = {ip, port}

    cond do
      port not in 1..65_535//1 or game not in @games ->
        {[], state}

      info["statechanged"] == "2" ->
        exiting(addr, ctx, now, state)

      entry = Store.lookup(ctx.store, addr, now) ->
        # A heartbeat for another game doesn't change a listed server's,
        # since heartbeats can be forged; it applies once it has expired.
        case entry.via == ctx.id && poll_for_heartbeat(state, addr, now) do
          {:now, state} -> {[query(addr, entry.game, ctx, now)], state}
          {:later, state} -> {[], state}
          false -> {[], state}
        end

      RateLimit.take({:gs, :heartbeat, ip}, @heartbeat_limit, 1, now) == :ok ->
        {[query(addr, game, ctx, now)], state}

      true ->
        {[], state}
    end
  end

  defp exiting(addr, ctx, now, state) do
    with %{via: via} = entry when via == ctx.id <- Store.lookup(ctx.store, addr, now),
         {:now, state} <- poll_for_shutdown(state, addr, now) do
      {[query(addr, entry.game, ctx, now)], state}
    else
      {:later, state} -> {[], state}
      {:skip, state} -> {[], state}
      _ -> {[], state}
    end
  end

  defp query(addr, game, ctx, now) do
    bucket = Integer.floor_div(now, ctx.challenge_ttl)
    {"\\info\\\\secure\\" <> challenge(addr, game, ctx.id, bucket), addr}
  end

  @doc false
  def challenge(addr, game, via, bucket, key \\ key()) do
    index = Enum.find_index(@games, &(&1 == game))
    data = [Addr.to_binary(addr), Addr.to_binary(via), <<bucket::signed-64, index>>]
    <<v::120, _::binary>> = :crypto.mac(:hmac, :sha256, key, data)
    <<:binary.at(@alphabet, index)>> <> digits(v, @mac_length, "")
  end

  defp digits(_v, 0, acc), do: acc

  defp digits(v, n, acc),
    do: digits(div(v, 62), n - 1, <<:binary.at(@alphabet, rem(v, 62))>> <> acc)

  defp key, do: :persistent_term.get({__MODULE__, :key})

  # The game whose challenge, sent from via to addr in this time bucket or
  # the one before, the response answers, or nil.
  defp answered(addr, response, via, now, ttl) do
    bucket = Integer.floor_div(now, ttl)

    Enum.find(@games, fn game ->
      Enum.any?([bucket, bucket - 1], fn b ->
        expected = GS.validate(challenge(addr, game, via, b), GS.key(game))
        byte_size(response) == byte_size(expected) and :crypto.hash_equals(response, expected)
      end)
    end)
  end

  defp reply(info, from, ctx, now) do
    with game when game != nil <- answered(from, info["validate"], ctx.id, now, ctx.challenge_ttl),
         {:ok, :added, entry} <- register(info, game, from, ctx, now) do
      registered(from, now)
      Logger.info("gs: #{Addr.to_string(from)} verified, game=#{entry.game}")
    else
      {:error, reason} -> Logger.warning("gs: #{Addr.to_string(from)} not listed: #{reason}")
      _ -> :ok
    end

    []
  end

  # Writes the entry if the server's current one is still what it was read
  # as: another listener may have written it in between.
  defp register(info, game, from, ctx, now, tries \\ 3) do
    existing = Store.lookup(ctx.store, from, now)

    entry = %{
      game: if(existing, do: existing.game, else: game),
      hostname: info |> Map.get("hostname", "") |> binary_slice(0, @hostname_length),
      version: info |> Map.get("version", "") |> binary_slice(0, @hostname_length),
      clients: GS.int(info["numplayers"]) || 0,
      max_clients: GS.int(info["maxplayers"]) || 0,
      via: if(existing, do: existing.via, else: ctx.id),
      seen: now,
      expires: now + ctx.server_ttl,
      verified: if(existing, do: existing.verified, else: now)
    }

    case Store.put(ctx.store, from, entry, now, existing) do
      :ok -> {:ok, if(existing, do: :updated, else: :added), entry}
      {:error, :changed} when tries > 1 -> register(info, game, from, ctx, now, tries - 1)
      error -> error
    end
  end

  # Asking listed servers again.
  #
  # A heartbeat from a listed server has it asked again, which is what
  # keeps it listed: only a reply refreshes the expiry. Heartbeats can be
  # forged with a listed server's address, so that happens at most once a
  # minute; a heartbeat inside the minute has the server asked when the
  # minute is over.
  #
  # \statechanged\2, which a server sends when it exits, can be forged
  # too, so it isn't taken as one: the server is asked, and dropped if it
  # doesn't answer within 10 seconds of that. The check shares the
  # once-a-minute allowance with heartbeats. An exit inside the minute has
  # the check wait for its end. The query a server answered to register
  # counts as its first.
  #
  # state.deferred is addr => {due, :poll | :check}, state.checks addr =>
  # when the check's query went out. Both are this listener's: a server is
  # only asked through the listener it is listed through.

  @gap {1, 60_000, 1}
  @check_window 10_000

  defp poll_for_heartbeat(state, addr, now) do
    case RateLimit.take({:gs, :poll, addr}, @gap, 1, now) do
      :ok -> {:now, sent(state, addr, now, :poll)}
      {:error, wait} -> {:later, defer(state, addr, now + wait, :poll)}
    end
  end

  defp poll_for_shutdown(state, addr, now) do
    if Map.has_key?(state.checks, addr) do
      {:skip, state}
    else
      case RateLimit.take({:gs, :poll, addr}, @gap, 1, now) do
        :ok -> {:now, sent(state, addr, now, :check)}
        {:error, wait} -> {:later, defer(state, addr, now + wait, :check)}
      end
    end
  end

  defp registered(addr, now), do: RateLimit.drain({:gs, :poll, addr}, @gap, now)

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

  # Drops servers that didn't answer an exit check, and returns the
  # servers whose put-off poll or check is due, and those just dropped that
  # heartbeat after their check went out: a server that restarts sends
  # \statechanged\2 and, a moment later, a heartbeat.
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
             :ok <- RateLimit.take({:gs, :poll, addr}, @gap, 1, now) do
          checks = if kind == :check, do: Map.put_new(state.checks, addr, now), else: state.checks
          {[addr | addrs], %{state | checks: checks}}
        else
          {:error, wait} -> {addrs, defer(state, addr, now + wait, kind)}
          _ -> {addrs, state}
        end
      end)

    {addrs, restarted, state}
  end
end
