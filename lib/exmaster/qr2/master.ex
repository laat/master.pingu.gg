defmodule Exmaster.QR2.Master do
  @moduledoc """
  The master for GameSpy's Query and Reporting 2, on UDP 27900 by
  default, as Battlefield Vietnam speaks it. Wire format in
  `Exmaster.QR2`; clients get the lists from `Exmaster.SB.ListServer`. See
  `docs/gamespy.md`.

  A heartbeat comes from the server's query port and carries everything
  the server says about itself. The master answers it with a challenge,
  and lists the server at that address once a reply from there carries
  the challenge's response under the game's key. The challenges are
  stateless, as GameSpy's first protocol's: an HMAC of the address, the
  listener, a time bucket, the game and the instance key the heartbeat
  came with. The server only answers a challenge with its own instance
  key, which the reply carries back.

  Heartbeats can be forged, so what one says is kept aside, by address
  and instance key, for 75 seconds at most, and taken into the server's
  entry when a reply with that instance key comes. An address keeps two:
  the latest with the instance key it is listed with, and the latest with
  another; 16,384 addresses at most. A forger who doesn't know the
  instance key can't get its heartbeat's contents listed.

  The server is listed for `server_ttl` after each reply, and each
  heartbeat with its instance key has it asked again, at most once a
  minute, as on the GameSpy master (see "Asking listed servers again"
  below). Those questions go with the instance key it is listed with, so
  forged heartbeats can't have it ignore them. A heartbeat with another
  instance key, as from a server that restarted, is asked about as one
  from an address that isn't listed, and a reply has the entry take the
  new key. `statechanged` 2 comes as the server exits: it is asked, with
  its listed instance key, and dropped if it doesn't answer. Keepalives
  are ignored: anyone can send one.
  """
  @behaviour Exmaster.Protocol

  alias Exmaster.{Addr, GS, QR2, RateLimit, Store}
  require Logger

  # As for the other masters: a heartbeat from an address that isn't
  # listed has the master send to it, so a forged one has it send to
  # anyone: 64 at once per IP, then one a second. Available checks share
  # it.
  @heartbeat_limit {1, 1_000, 64}

  @max_pending 16_384
  @pending_ttl 75_000

  # What an entry keeps of a heartbeat: each entry is copied to every list
  # and to the other nodes.
  @max_keys 64
  @key_bytes 32
  @value_bytes 64

  # Challenges: 20 characters, as OpenSpy's master sends them and the
  # games read them: 6 from an HMAC ([A-Za-z0-9]), "00" for no options,
  # then the public IP and port in hex. A blind forger needs about
  # 62^6 / 2 guesses, each a packet the master checks.
  @alphabet Enum.concat([?A..?Z, ?a..?z, ?0..?9]) |> List.to_string()
  @mac_length 6

  @impl true
  def name, do: "QR2"

  @impl true
  def family, do: :inet

  @impl true
  def store, do: :exmaster_qr2

  @impl true
  def init(_now), do: %{deferred: %{}, checks: %{}, pending: %{}}

  @doc "Makes the key challenges are signed with, random per boot."
  def init_key, do: :persistent_term.put({__MODULE__, :key}, :crypto.strong_rand_bytes(32))

  @impl true
  def handle_packet(data, {ip, _} = from, ctx, now, state) do
    case QR2.parse(data) do
      {:available, game} ->
        if QR2.key(game) != nil and
             RateLimit.take({:qr2, :heartbeat, ip}, @heartbeat_limit, 1, now) == :ok,
           do: {[{QR2.available_packet(), from}], state},
           else: {[], state}

      {:heartbeat, key, payload} ->
        heartbeat(key, payload, from, ctx, now, state)

      {:response, key, response} ->
        reply(key, response, from, ctx, now, state)

      :other ->
        {[], state}
    end
  end

  @impl true
  def tick(ctx, now, state) do
    pending =
      for {addr, slots} <- state.pending,
          slots = Map.filter(slots, fn {_, p} -> p.at + @pending_ttl > now end),
          slots != %{},
          into: %{},
          do: {addr, slots}

    {due, state} = due_polls(ctx, now, %{state | pending: pending})

    polls =
      for addr <- due,
          entry = Store.lookup(ctx.store, addr, now),
          entry != nil,
          do: query(addr, entry.game, entry.instance, ctx, now)

    {polls, state}
  end

  # The server is at the address the heartbeat came from: the SDK
  # heartbeats from its query port, and under NAT that is the port its
  # keepalives keep open.
  defp heartbeat(key, payload, {ip, _} = addr, ctx, now, state) do
    with {:ok, keys} <- QR2.parse_keys(payload),
         info = info(keys),
         game when game != nil <- if(QR2.key(info["gamename"]), do: info["gamename"]) do
      entry = Store.lookup(ctx.store, addr, now)

      cond do
        info["statechanged"] == "2" ->
          exiting(addr, entry, ctx, now, state)

        entry != nil and entry.instance == key ->
          state = remember(state, addr, key, info, now, entry)

          case entry.via == ctx.id && poll_for_heartbeat(state, addr, now) do
            {:now, state} -> {[query(addr, entry.game, key, ctx, now)], state}
            {:later, state} -> {[], state}
            false -> {[], state}
          end

        RateLimit.take({:qr2, :heartbeat, ip}, @heartbeat_limit, 1, now) == :ok ->
          game = if entry, do: entry.game, else: game
          {[query(addr, game, key, ctx, now)], remember(state, addr, key, info, now, entry)}

        true ->
          {[], state}
      end
    else
      _ -> {[], state}
    end
  end

  # A heartbeat's keys as an entry keeps them: the first of a key, the
  # first 64 keys, cut to 32 and 64 bytes.
  defp info(keys) do
    keys
    |> Enum.take(@max_keys)
    |> Enum.reverse()
    |> Map.new(fn {k, v} ->
      {binary_slice(k, 0, @key_bytes), binary_slice(v, 0, @value_bytes)}
    end)
  end

  # Keeps a heartbeat aside, with its instance key, and the latest one
  # with the key the server is listed with if this one's is another. A new
  # address only while there is room.
  defp remember(state, addr, key, info, now, entry) do
    slots = Map.get(state.pending, addr)

    if slots != nil or map_size(state.pending) < @max_pending do
      keep = if entry, do: Map.take(slots || %{}, [entry.instance]), else: %{}
      slots = Map.put(keep, key, %{info: info, at: now})
      %{state | pending: Map.put(state.pending, addr, slots)}
    else
      state
    end
  end

  defp exiting(addr, entry, ctx, now, state) do
    with %{via: via} when via == ctx.id <- entry,
         {:now, state} <- poll_for_shutdown(state, addr, now) do
      {[query(addr, entry.game, entry.instance, ctx, now)], state}
    else
      {:later, state} -> {[], state}
      {:skip, state} -> {[], state}
      _ -> {[], state}
    end
  end

  defp query(addr, game, key, ctx, now) do
    bucket = Integer.floor_div(now, ctx.challenge_ttl)
    {QR2.challenge_packet(key, challenge(addr, game, key, ctx.id, bucket)), addr}
  end

  @doc false
  def challenge({ip, port} = addr, game, key, via, bucket, secret \\ secret()) do
    data = [Addr.to_binary(addr), Addr.to_binary(via), <<bucket::signed-64>>, game, 0, key]
    <<mac::binary-size(@mac_length), _::binary>> = :crypto.mac(:hmac, :sha256, secret, data)
    # A byte a character, rem 62, slightly uneven.
    random = for <<b <- mac>>, into: "", do: <<:binary.at(@alphabet, rem(b, 62))>>
    random <> "00" <> Base.encode16(Addr.ip_bytes(ip)) <> Base.encode16(<<port::16>>)
  end

  defp secret, do: :persistent_term.get({__MODULE__, :key})

  # The game whose challenge, sent from via to addr with key in this time
  # bucket or the one before, the response answers, or nil. Any packet of
  # type 1 gets here, from any address, so the length goes first.
  defp answered(addr, key, response, via, now, ttl) do
    bucket = Integer.floor_div(now, ttl)

    Enum.find(QR2.games(), fn game ->
      byte_size(response) == 28 and
        Enum.any?([bucket, bucket - 1], fn b ->
          expected = GS.validate(challenge(addr, game, key, via, b), QR2.key(game))
          :crypto.hash_equals(response, expected)
        end)
    end)
  end

  defp reply(key, response, from, ctx, now, state) do
    with game when game != nil <- answered(from, key, response, ctx.id, now, ctx.challenge_ttl),
         {:ok, status, entry} <- register(from, game, key, state, ctx, now) do
      registered(from, now)

      if status == :added,
        do: Logger.info("qr2: #{Addr.to_string(from)} verified, game=#{entry.game}")

      {[{QR2.registered_packet(key), from}], state}
    else
      {:error, reason} ->
        Logger.warning("qr2: #{Addr.to_string(from)} not listed: #{reason}")
        {[], state}

      _ ->
        {[], state}
    end
  end

  # Writes the entry if the server's current one is still what it was read
  # as: another listener may have written it in between. What the server
  # says comes from its heartbeat with the reply's instance key, if one
  # was kept; otherwise the entry keeps what it had. The reply's key
  # becomes the entry's: a restarted server's is new.
  defp register(addr, game, key, state, ctx, now, tries \\ 3) do
    existing = Store.lookup(ctx.store, addr, now)

    info =
      case state.pending do
        %{^addr => %{^key => %{info: info}}} -> info
        _ -> if(existing, do: existing.fields, else: %{})
      end

    {local_ip, local_port} = local(info)

    entry = %{
      game: if(existing, do: existing.game, else: game),
      hostname: Map.get(info, "hostname", ""),
      version: Map.get(info, "gamever", ""),
      clients: GS.int(info["numplayers"]) || 0,
      max_clients: GS.int(info["maxplayers"]) || 0,
      fields: info,
      local_ip: local_ip,
      local_port: local_port,
      instance: key,
      via: if(existing, do: existing.via, else: ctx.id),
      seen: now,
      expires: now + ctx.server_ttl,
      verified: if(existing, do: existing.verified, else: now)
    }

    case Store.put(ctx.store, addr, entry, now, existing) do
      :ok -> {:ok, if(existing, do: :updated, else: :added), entry}
      {:error, :changed} when tries > 1 -> register(addr, game, key, state, ctx, now, tries - 1)
      error -> error
    end
  end

  # The server's address on its own network, as clients on that network
  # reach it: localip0 and localport.
  defp local(info) do
    ip =
      case :inet.parse_ipv4strict_address(String.to_charlist(Map.get(info, "localip0", ""))) do
        {:ok, ip} -> ip
        _ -> nil
      end

    port = GS.int(info["localport"])
    {ip, if(port in 1..65_535//1, do: port)}
  end

  # Asking listed servers again.
  #
  # A heartbeat from a listed server, with its instance key, has it asked
  # again, which is what keeps it listed: only a reply refreshes the
  # expiry. Heartbeats can be forged with a listed server's address, so
  # that happens at most once a minute; a heartbeat inside the minute has
  # the server asked when the minute is over.
  #
  # statechanged 2, which a server sends as it exits, can be forged too,
  # so it isn't taken as one: the server is asked, and dropped if it
  # doesn't answer within 10 seconds of that. The check shares the
  # once-a-minute allowance with heartbeats. An exit inside the minute has
  # the check wait for its end. The challenge a server answered to
  # register counts as its first.
  #
  # state.deferred is addr => {due, :poll | :check}, state.checks addr =>
  # when the check's query went out. Both are this listener's: a server is
  # only asked through the listener it is listed through.

  @gap {1, 60_000, 1}
  @check_window 10_000

  defp poll_for_heartbeat(state, addr, now) do
    case RateLimit.take({:qr2, :poll, addr}, @gap, 1, now) do
      :ok -> {:now, sent(state, addr, now, :poll)}
      {:error, wait} -> {:later, defer(state, addr, now + wait, :poll)}
    end
  end

  defp poll_for_shutdown(state, addr, now) do
    if Map.has_key?(state.checks, addr) do
      {:skip, state}
    else
      case RateLimit.take({:qr2, :poll, addr}, @gap, 1, now) do
        :ok -> {:now, sent(state, addr, now, :check)}
        {:error, wait} -> {:later, defer(state, addr, now + wait, :check)}
      end
    end
  end

  defp registered(addr, now), do: RateLimit.drain({:qr2, :poll, addr}, @gap, now)

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
  # servers whose put-off poll or check is due. A server that restarts
  # sends statechanged 2 and, a moment later, a heartbeat with a new
  # instance key, which is asked about at once.
  defp due_polls(ctx, now, state) do
    {done, checks} = Map.split_with(state.checks, fn {_, at} -> at + @check_window <= now end)

    state =
      Enum.reduce(done, %{state | checks: checks}, fn {addr, at}, state ->
        Store.drop_unless_seen(ctx.store, addr, at, ctx.id)
        %{state | deferred: Map.delete(state.deferred, addr)}
      end)

    {due, deferred} = Map.split_with(state.deferred, fn {_, {at, _}} -> at <= now end)
    state = %{state | deferred: deferred}
    via = ctx.id

    Enum.reduce(due, {[], state}, fn {addr, {_, kind}}, {polls, state} ->
      with %{via: ^via} <- Store.lookup(ctx.store, addr, now),
           :ok <- RateLimit.take({:qr2, :poll, addr}, @gap, 1, now) do
        checks = if kind == :check, do: Map.put_new(state.checks, addr, now), else: state.checks
        {[addr | polls], %{state | checks: checks}}
      else
        {:error, wait} -> {polls, defer(state, addr, now + wait, kind)}
        _ -> {polls, state}
      end
    end)
  end
end
