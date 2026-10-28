defmodule Exmaster.UE2.Master do
  @moduledoc """
  The Unreal Engine 2 master, as Unreal Tournament 2004 knows it, on TCP
  28902 by default. Game servers and clients both connect to it; the
  wire format is in `Exmaster.UE2`. See `docs/ut2004.md`.

  The master speaks first, with a challenge. The other side answers with
  its CD key's hashes (not checked: only Epic's masters could, and the
  masters players use now don't either), its name and version, and is
  approved. Then:

  - A game server (`UT2K4SERVER`) sends two flags, gets the frame of
    ports OpenSpy's master sends, and keeps the connection open, sending
    a heartbeat every 60 seconds. It is listed at the connection's IP and
    the port its heartbeat names, for as long as the connection lasts:
    TCP has proved the IP, and the port only matters to that IP. A
    connection that hasn't had a heartbeat listed for 150 seconds is
    closed, and its server dropped.
  - A client (`UT2K4CLIENT`) sends a verification, gets `VERIFIED`, and
    asks for the list, with filters, or the message of the day, and the
    connection is closed after the answer.

  A listener process owns the socket; an acceptor hands each connection to
  a task under a `Task.Supervisor`. The listener counts them: 256 at once
  in the handshake or with a client, and 4,096 servers' that have done
  it, so servers can't take the slots clients need. An IP can have as
  many open as it can list servers (`max_per_ip`), and 8 more.
  Connections are closed 15 seconds after they open, but for servers'
  once their handshake is done.
  """
  use GenServer
  require Logger

  alias Exmaster.{Addr, RateLimit, Store, UE2}

  @game "ut2004"
  @server "UT2K4SERVER"
  @client "UT2K4CLIENT"

  @max_uplinks 4_096
  @max_others 256
  @client_slots 8
  # Per IP: 10 connections at once, then one a second.
  @connect_limit {1, 1_000, 10}
  # Lists per IP, as list queries to the other masters: 5 at once, then
  # one every 3 seconds.
  @list_limit {1, 3_000, 5}
  # The handshake, and a client's request after it, have to be done this
  # long after connecting. A connection is closed this long after it
  # opened, whatever it is doing, unless it is a server's that has done
  # its handshake, so one that reads slowly can't keep a slot.
  @timeout 10_000
  @lifetime 15_000
  # UT2004 heartbeats every 60 seconds.
  @idle 150_000
  # A server's heartbeats are stored at most this often; one in between
  # waits for the gap to end, and a later one replaces it.
  @gap 10_000
  @max_frame 32_768
  # A list goes out in chunks of this size, each paid for from the reply
  # budget before it is sent.
  @chunk 65_536

  @hostname_bytes 127
  @name_bytes 63

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.get(opts, :ip), Keyword.get(opts, :port, 0)},
      start: {__MODULE__, :start_link, [opts]}
    }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def store, do: :exmaster_ue2

  @doc "The port the listener is bound to, for listeners started on port 0."
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip)
    # What each connection needs. :idle, :gap, :lifetime, :max_uplinks
    # and :max_others are for tests.
    conf = %{
      owner: self(),
      store: Keyword.get(opts, :store, store()),
      idle: Keyword.get(opts, :idle, @idle),
      gap: Keyword.get(opts, :gap, @gap),
      lifetime: Keyword.get(opts, :lifetime, @lifetime)
    }

    max = %{
      uplink: Keyword.get(opts, :max_uplinks, @max_uplinks),
      other: Keyword.get(opts, :max_others, @max_others)
    }

    # Accepted sockets inherit these.
    sock_opts = [
      :binary,
      :inet,
      active: false,
      reuseaddr: true,
      backlog: 128,
      nodelay: true,
      send_timeout: 5_000,
      send_timeout_close: true
    ]

    sock_opts = if ip, do: [ip: ip] ++ sock_opts, else: sock_opts

    case :gen_tcp.listen(Keyword.get(opts, :port, 0), sock_opts) do
      {:ok, lsock} ->
        {:ok, port} = :inet.port(lsock)

        {:ok, tasks} =
          Task.Supervisor.start_link(max_children: max.uplink + max.other)

        me = self()
        spawn_link(fn -> accept(lsock, me) end)
        Logger.info("UT2004 master listening on inet port #{port}")

        per_ip =
          Keyword.get_lazy(opts, :max_per_ip, fn ->
            Application.fetch_env!(:exmaster, :max_per_ip)
          end) + @client_slots

        {:ok,
         %{
           lsock: lsock,
           port: port,
           tasks: tasks,
           conf: conf,
           per_ip: per_ip,
           conns: %{},
           ips: %{},
           counts: %{uplink: 0, other: 0},
           max: max
         }}

      {:error, reason} ->
        {:stop, {:listen, "UT2004", ip, Keyword.get(opts, :port), reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  # A connection from ip wants a task.
  def handle_call({:start, ip}, _from, state) do
    with true <- Map.get(state.ips, ip, 0) < state.per_ip,
         true <- state.counts.other < state.max.other,
         {:ok, pid} <- Task.Supervisor.start_child(state.tasks, fn -> serve(state.conf) end) do
      Process.monitor(pid)

      {:reply, {:ok, pid},
       %{
         state
         | conns: Map.put(state.conns, pid, {ip, :other}),
           ips: Map.update(state.ips, ip, 1, &(&1 + 1)),
           counts: Map.update!(state.counts, :other, &(&1 + 1))
       }}
    else
      _ -> {:reply, :refused, state}
    end
  end

  # A connection has done a server's handshake and wants a server's slot.
  def handle_call(:uplink, {pid, _}, state) do
    case state.conns do
      %{^pid => {ip, :other}} when state.counts.uplink < state.max.uplink ->
        counts = %{uplink: state.counts.uplink + 1, other: state.counts.other - 1}
        {:reply, :ok, %{state | conns: Map.put(state.conns, pid, {ip, :uplink}), counts: counts}}

      _ ->
        {:reply, :full, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, state) do
    {{ip, kind}, conns} = Map.pop(state.conns, pid)

    ips =
      case Map.fetch!(state.ips, ip) do
        1 -> Map.delete(state.ips, ip)
        n -> Map.put(state.ips, ip, n - 1)
      end

    {:noreply,
     %{state | conns: conns, ips: ips, counts: Map.update!(state.counts, kind, &(&1 - 1))}}
  end

  defp accept(lsock, owner) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        hand_off(sock, owner)
        accept(lsock, owner)

      {:error, reason} ->
        exit({:accept, reason})
    end
  end

  defp hand_off(sock, owner) do
    with {:ok, {ip, _}} <- :inet.peername(sock),
         :ok <- RateLimit.take({:ue2, :connect, ip}, @connect_limit, 1, Exmaster.now()),
         {:ok, pid} <- GenServer.call(owner, {:start, ip}),
         :ok <- :gen_tcp.controlling_process(sock, pid) do
      send(pid, {:socket, sock})
    else
      _ -> :gen_tcp.close(sock)
    end
  end

  defp serve(conf) do
    receive do
      {:socket, sock} ->
        # Killed, the task takes the socket, which it owns, with it.
        {:ok, kill} = :timer.kill_after(conf.lifetime)

        try do
          converse(sock, conf, kill)
        after
          :gen_tcp.close(sock)
        end
    after
      1_000 -> :ok
    end
  end

  # A peer that has gone (a scanner that connects and resets) makes a
  # send or peername fail, which ends the conversation like any refusal.
  defp converse(sock, conf, kill) do
    deadline = Exmaster.now() + @timeout

    with {:ok, {ip, _}} <- :inet.peername(sock),
         :ok <- send_frame(sock, UE2.string(challenge())),
         {:ok, hello, buf} <- next_frame(sock, "", deadline),
         {:ok, name, version} <- UE2.parse_hello(hello) do
      case name do
        @server -> server(sock, buf, ip, version, conf, kill, deadline)
        @client -> client(sock, buf, ip, conf.store, deadline)
        _ -> send_frame(sock, UE2.string("DENIED"))
      end
    end
  end

  # A challenge for the CD key; nothing checks the answer. qstat takes up
  # to 8 characters.
  defp challenge,
    do: for(<<b <- :crypto.strong_rand_bytes(8)>>, into: "", do: <<?0 + rem(b, 10)>>)

  # The flags after approval are whether the server thinks it is behind
  # NAT and whether it uplinks to GameSpy too. The server waits for the
  # ports the master saw it on before it heartbeats; what it does with
  # them isn't known, and they don't change what it heartbeats. These are
  # what OpenSpy's master sends every server: UT2004's default query port,
  # game port and GameSpy query port, after 120, whose meaning isn't known
  # either.
  @detected_ports <<1, 120::little-32, 7778::little-32, 7777::little-32, 7787::little-32>>

  defp server(sock, buf, ip, version, conf, kill, deadline) do
    with :ok <- send_frame(sock, UE2.string("APPROVED")),
         {:ok, _flags, buf} <- next_frame(sock, buf, deadline),
         :ok <- GenServer.call(conf.owner, :uplink),
         {:ok, :cancel} <- :timer.cancel(kill),
         :ok <- send_frame(sock, @detected_ports) do
      now = Exmaster.now()

      state = %{
        ip: ip,
        version: version,
        store: conf.store,
        idle: conf.idle,
        gap: conf.gap,
        # Orders this node's connections: an older one doesn't take a
        # server from a newer one.
        conn: :erlang.unique_integer([:monotonic]),
        idle_at: now + conf.idle,
        addr: nil,
        listed: false,
        refused: nil,
        pending: nil,
        stored_at: nil
      }

      sock |> uplink(buf, state) |> drop()
    end
  end

  # Frames until the connection closes or idles: heartbeats (1), stats
  # (2) and the version of the server's packages (4), the last two
  # ignored. A heartbeat waits as pending until the gap since the last
  # stored one is over. Only a heartbeat that lists the server puts off
  # idling, so a connection can't keep its slot with frames that list
  # nothing.
  defp uplink(sock, buf, state) do
    now = Exmaster.now()

    due =
      cond do
        state.pending == nil -> state.idle_at
        state.stored_at == nil -> now
        true -> state.stored_at + state.gap
      end

    cond do
      state.pending && due <= now ->
        uplink(sock, buf, store_heartbeat(state.pending, %{state | pending: nil}, now))

      state.idle_at <= now ->
        Logger.debug("ue2: #{who(state)} idle, closing")
        state

      true ->
        case next_frame(sock, buf, min(due, state.idle_at)) do
          {:ok, <<1, heartbeat::binary>>, buf} -> uplink(sock, buf, %{state | pending: heartbeat})
          {:ok, _, buf} -> uplink(sock, buf, state)
          {:timeout, buf} -> uplink(sock, buf, state)
          :error -> state
        end
    end
  end

  defp who(%{addr: nil, ip: ip}), do: :inet.ntoa(ip)
  defp who(%{addr: addr}), do: Addr.to_string(addr)

  defp store_heartbeat(payload, state, now) do
    with {:ok, hb} <- UE2.parse_heartbeat(payload),
         true <- hb.port in 1..65_534//1 do
      addr = {state.ip, hb.port}
      if state.addr not in [nil, addr], do: drop(state)
      state = register(hb, addr, %{state | addr: addr, stored_at: now}, now)
      if state.listed, do: %{state | idle_at: now + state.idle}, else: state
    else
      _ ->
        Logger.debug("ue2: a heartbeat from #{who(state)} that doesn't parse")
        %{state | stored_at: now}
    end
  end

  # Writes the entry if the server's current one is still what it was read
  # as: another connection may have written it in between. A server that
  # a newer connection lists is left to it: an old connection of a server
  # that reconnected may still be open, and heartbeat late.
  defp register(hb, addr, state, now, tries \\ 3) do
    existing = Store.lookup(state.store, addr, now)
    values = UE2.filter_values(hb)
    mutators = UE2.mutators(hb)

    entry = %{
      game: @game,
      version: Integer.to_string(state.version),
      hostname: UE2.cut(hb.hostname, @hostname_bytes),
      map: UE2.cut(hb.map, @name_bytes),
      gametype: UE2.cut(hb.gametype, @name_bytes),
      skill: UE2.cut(hb.skill, @name_bytes),
      clients: hb.players |> max(0) |> min(255),
      max_clients: hb.max_players |> max(0) |> min(255),
      # UT2004 sends 0: its query port is the game port's next.
      query_port: if(hb.query_port in 1..65_535//1, do: hb.query_port, else: hb.port + 1),
      flags: UE2.flags(values, mutators),
      filters: values,
      mutators: mutators,
      via: self(),
      conn: state.conn,
      seen: now,
      expires: now + state.idle
    }

    case existing && existing.conn > state.conn do
      true ->
        Logger.debug("ue2: #{Addr.to_string(addr)} is listed through a newer connection")
        %{state | listed: false, refused: nil}

      _ ->
        case Store.put(state.store, addr, entry, now, existing) do
          :ok ->
            unless state.listed,
              do: Logger.info("ue2: #{Addr.to_string(addr)} listed, version=#{entry.version}")

            %{state | listed: true, refused: nil}

          {:error, :changed} when tries > 1 ->
            register(hb, addr, state, now, tries - 1)

          {:error, reason} ->
            if state.refused != reason,
              do: Logger.warning("ue2: #{Addr.to_string(addr)} not listed: #{reason}")

            %{state | listed: false, refused: reason}
        end
    end
  end

  # Drops the server this connection listed, unless another has listed it
  # since.
  defp drop(%{addr: addr} = state) when addr != nil,
    do: Store.drop_unless_seen(state.store, addr, Exmaster.now() + 1, self())

  defp drop(_state), do: :ok

  # A client: its verification, then one request, the list (0) or the
  # message of the day (1).
  defp client(sock, buf, ip, store, deadline) do
    with :ok <- send_frame(sock, [UE2.string("APPROVED"), <<3::little-32>>]),
         {:ok, _verification, buf} <- next_frame(sock, buf, deadline),
         :ok <- send_frame(sock, UE2.string("VERIFIED")),
         {:ok, request, _} <- next_frame(sock, buf, deadline) do
      case request do
        <<0, query::binary>> -> list(sock, ip, query, store)
        <<1, _::binary>> -> send_frame(sock, [UE2.string(""), <<0::little-32>>])
        _ -> :ok
      end
    end
  end

  # The list: a frame with the count and 1, then a frame a server. The
  # least a reply costs is reserved before the list is made, as the other
  # masters reserve it; the rest is paid a chunk at a time, waiting for
  # the budget when it runs out, so a list larger than its burst still
  # goes out, at its rate, until the connection's 15 seconds are up.
  defp list(sock, ip, query, store) do
    now = Exmaster.now()

    with {:ok, filters} <- UE2.parse_query(query),
         {:limit, :ok} <- {:limit, RateLimit.take({:ue2, :list, ip}, @list_limit, 1, now)},
         {:budget, :ok} <- {:budget, RateLimit.reserve_reply(now)} do
      entries =
        for {addr, entry} <- Enum.sort(Store.all(store, now, @game)),
            UE2.matches?(entry, filters),
            do: UE2.frame(UE2.encode_entry(addr, entry))

      Logger.debug("ue2: list for #{:inet.ntoa(ip)}, #{length(entries)} servers")

      with :ok <- send_frame(sock, <<length(entries)::little-32, 1>>),
           do: send_paid(sock, chunks(entries), RateLimit.min_reply())
    else
      {:budget, _} -> Logger.debug("ue2: a list over the reply budget")
      _ -> :ok
    end
  end

  # Frames in chunks of at most @chunk bytes (or one frame), with their
  # sizes.
  defp chunks(frames) do
    frames
    |> Enum.chunk_while(
      {[], 0},
      fn frame, {acc, size} ->
        n = IO.iodata_length(frame)

        if acc != [] and size + n > @chunk,
          do: {:cont, {Enum.reverse(acc), size}, {[frame], n}},
          else: {:cont, {[frame | acc], size + n}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {acc, size} -> {:cont, {Enum.reverse(acc), size}, {[], 0}}
      end
    )
  end

  # Sends each chunk once the budget has paid for it; credit is what the
  # reservation has paid for already.
  defp send_paid(_sock, [], _credit), do: :ok

  defp send_paid(sock, [{chunk, size} | rest], credit) do
    with :ok <- pay(max(size - credit, 0)),
         :ok <- :gen_tcp.send(sock, chunk),
         do: send_paid(sock, rest, max(credit - size, 0))
  end

  defp pay(0), do: :ok

  defp pay(bytes) do
    case RateLimit.spend_reply(bytes, Exmaster.now()) do
      :ok ->
        :ok

      {:error, wait} ->
        Process.sleep(wait)
        pay(bytes)
    end
  end

  defp send_frame(sock, payload), do: :gen_tcp.send(sock, UE2.frame(payload))

  # The next frame: {:ok, payload, what follows it}, {:timeout, what came
  # of it so far} at the deadline, or :error when the connection closes or
  # a frame's length is out of bounds.
  defp next_frame(sock, buf, deadline) do
    case buf do
      <<len::little-32, _::binary>> when len == 0 or len > @max_frame ->
        :error

      <<len::little-32, payload::binary-size(len), rest::binary>> ->
        {:ok, payload, rest}

      _ ->
        wait = deadline - Exmaster.now()

        if wait > 0 do
          case :gen_tcp.recv(sock, 0, wait) do
            {:ok, data} -> next_frame(sock, buf <> data, deadline)
            {:error, :timeout} -> {:timeout, buf}
            {:error, _} -> :error
          end
        else
          {:timeout, buf}
        end
    end
  end
end
