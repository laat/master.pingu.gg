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
    a heartbeat every 60 seconds. It is listed at the connection's IP and the port
    its heartbeat names, for as long as the connection lasts: TCP has
    proved the IP, and the port only matters to that IP. A connection
    that sends nothing for 150 seconds is closed, and its server dropped.
  - A client (`UT2K4CLIENT`) sends a verification, gets `VERIFIED`, and
    asks for the list, with filters, or the message of the day, and the
    connection is closed after the answer.

  A listener process owns the socket; an acceptor hands each connection to
  a task under a `Task.Supervisor`, which takes at most 4,096 at once.
  The listener counts them by IP: an IP can have as many open as it can
  list servers (`max_per_ip`), and 8 more.
  """
  use GenServer
  require Logger

  alias Exmaster.{Addr, RateLimit, Store, UE2}

  @game "ut2004"
  @server "UT2K4SERVER"
  @client "UT2K4CLIENT"

  @max_connections 4_096
  @client_slots 8
  # Per IP: 10 connections at once, then one a second.
  @connect_limit {1, 1_000, 10}
  # Lists per IP, as list queries to the other masters: 5 at once, then
  # one every 3 seconds.
  @list_limit {1, 3_000, 5}
  # The handshake, and a client's request after it, have to be done this
  # long after connecting. A client's connection is closed this long after
  # it opened, whatever it is doing, so one that reads slowly can't keep a
  # slot.
  @timeout 10_000
  @lifetime 15_000
  # UT2004 heartbeats every 60 seconds.
  @idle 150_000
  # A server's heartbeats are stored at most this often; one in between
  # waits for the gap to end, and a later one replaces it.
  @gap 10_000
  @max_frame 32_768

  @hostname_length 127
  @name_length 63

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
    # What each connection needs; :idle and :gap are for tests.
    conf = %{
      store: Keyword.get(opts, :store, store()),
      idle: Keyword.get(opts, :idle, @idle),
      gap: Keyword.get(opts, :gap, @gap)
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
        {:ok, tasks} = Task.Supervisor.start_link(max_children: @max_connections)
        me = self()
        spawn_link(fn -> accept(lsock, me) end)
        Logger.info("UT2004 master listening on inet port #{port}")

        per_ip =
          Keyword.get_lazy(opts, :max_per_ip, fn ->
            Application.fetch_env!(:exmaster, :max_per_ip)
          end) +
            @client_slots

        {:ok,
         %{
           lsock: lsock,
           port: port,
           tasks: tasks,
           conf: conf,
           per_ip: per_ip,
           conns: %{},
           ips: %{}
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
         {:ok, pid} <- Task.Supervisor.start_child(state.tasks, fn -> serve(state.conf) end) do
      Process.monitor(pid)

      {:reply, {:ok, pid},
       %{
         state
         | conns: Map.put(state.conns, pid, ip),
           ips: Map.update(state.ips, ip, 1, &(&1 + 1))
       }}
    else
      _ -> {:reply, :refused, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, state) do
    {ip, conns} = Map.pop(state.conns, pid)

    ips =
      case Map.fetch!(state.ips, ip) do
        1 -> Map.delete(state.ips, ip)
        n -> Map.put(state.ips, ip, n - 1)
      end

    {:noreply, %{state | conns: conns, ips: ips}}
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
        try do
          converse(sock, conf)
        after
          :gen_tcp.close(sock)
        end
    after
      1_000 -> :ok
    end
  end

  # A peer that has gone (a scanner that connects and resets) makes a
  # send or peername fail, which ends the conversation like any refusal.
  defp converse(sock, conf) do
    deadline = Exmaster.now() + @timeout

    with {:ok, {ip, _}} <- :inet.peername(sock),
         :ok <- send_frame(sock, UE2.string(challenge())),
         {:ok, hello, buf} <- next_frame(sock, "", deadline),
         {:ok, name, version} <- UE2.parse_hello(hello) do
      case name do
        @server -> server(sock, buf, ip, version, conf, deadline)
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

  defp server(sock, buf, ip, version, conf, deadline) do
    with :ok <- send_frame(sock, UE2.string("APPROVED")),
         {:ok, _flags, buf} <- next_frame(sock, buf, deadline),
         :ok <- send_frame(sock, @detected_ports) do
      state = %{
        ip: ip,
        version: version,
        store: conf.store,
        idle: conf.idle,
        gap: conf.gap,
        addr: nil,
        listed: false,
        refused: nil,
        pending: nil,
        stored_at: nil
      }

      sock |> uplink(buf, Exmaster.now() + conf.idle, state) |> drop()
    end
  end

  # Frames until the connection closes or idles: heartbeats (1), stats
  # (2) and the version of the server's packages (4), the last two
  # ignored. A heartbeat waits as pending until the gap since the last
  # stored one is over.
  defp uplink(sock, buf, idle, state) do
    now = Exmaster.now()

    due =
      cond do
        state.pending == nil -> idle
        state.stored_at == nil -> now
        true -> state.stored_at + state.gap
      end

    cond do
      state.pending && due <= now ->
        uplink(sock, buf, idle, store_heartbeat(state.pending, %{state | pending: nil}, now))

      idle <= now ->
        Logger.debug("ue2: #{who(state)} idle, closing")
        state

      true ->
        case next_frame(sock, buf, min(due, idle)) do
          {:ok, <<1, heartbeat::binary>>, buf} ->
            uplink(sock, buf, Exmaster.now() + state.idle, %{state | pending: heartbeat})

          {:ok, _, buf} ->
            uplink(sock, buf, Exmaster.now() + state.idle, state)

          {:timeout, buf} ->
            uplink(sock, buf, idle, state)

          :error ->
            state
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
      register(hb, addr, %{state | addr: addr, stored_at: now}, now)
    else
      _ ->
        Logger.debug("ue2: a heartbeat from #{who(state)} that doesn't parse")
        %{state | stored_at: now}
    end
  end

  # Writes the entry if the server's current one is still what it was read
  # as: another connection may have written it in between.
  defp register(hb, addr, state, now, tries \\ 3) do
    existing = Store.lookup(state.store, addr, now)
    values = UE2.filter_values(hb)
    mutators = UE2.mutators(hb)

    entry = %{
      game: @game,
      version: Integer.to_string(state.version),
      hostname: String.slice(hb.hostname, 0, @hostname_length),
      map: String.slice(hb.map, 0, @name_length),
      gametype: String.slice(hb.gametype, 0, @name_length),
      skill: String.slice(hb.skill, 0, @name_length),
      clients: hb.players |> max(0) |> min(255),
      max_clients: hb.max_players |> max(0) |> min(255),
      # UT2004 sends 0: its query port is the game port's next.
      query_port: if(hb.query_port in 1..65_535//1, do: hb.query_port, else: hb.port + 1),
      flags: UE2.flags(values, mutators),
      filters: values,
      mutators: mutators,
      via: self(),
      seen: now,
      expires: now + state.idle
    }

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

  # Drops the server this connection listed, unless another has listed it
  # since.
  defp drop(%{addr: addr} = state) when addr != nil,
    do: Store.drop_unless_seen(state.store, addr, Exmaster.now() + 1, self())

  defp drop(_state), do: :ok

  # A client: its verification, then one request, the list (0) or the
  # message of the day (1).
  defp client(sock, buf, ip, store, deadline) do
    {:ok, _} = :timer.kill_after(@lifetime)

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
  # reply budget is reserved before the list is made, as the other masters
  # reserve it.
  defp list(sock, ip, query, store) do
    now = Exmaster.now()

    with {:ok, filters} <- UE2.parse_query(query),
         {:limit, :ok} <- {:limit, RateLimit.take({:ue2, :list, ip}, @list_limit, 1, now)},
         {:budget, :ok} <- {:budget, RateLimit.reserve_reply(now)} do
      entries =
        for {addr, entry} <- Enum.sort(Store.all(store, now, @game)),
            UE2.matches?(entry, filters),
            do: UE2.frame(UE2.encode_entry(addr, entry))

      size = IO.iodata_length(entries)

      with {:budget, :ok} <- {:budget, RateLimit.charge_reply(size, now)},
           :ok <- send_frame(sock, <<length(entries)::little-32, 1>>) do
        Logger.debug("ue2: list for #{:inet.ntoa(ip)}, #{length(entries)} servers")
        :gen_tcp.send(sock, entries)
      end
    else
      {:budget, _} -> Logger.debug("ue2: a list over the reply budget")
      _ -> :ok
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
