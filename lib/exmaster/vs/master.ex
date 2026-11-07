defmodule Exmaster.VS.Master do
  @moduledoc """
  Vintage Story's master, HTTP over TCP. Game servers post JSON to
  `register`, `heartbeat` and `unregister`, and clients get `list`, under
  whatever path the master's URL has: the endpoint is a request path's
  last segment. The JSON is in `Exmaster.VS`; see `docs/vintagestory.md`.

  A server is listed at the connection's IP and the port it registers:
  TCP has proved the IP, and the port only matters to that IP. It has to
  take a TCP connection on that port first, so servers clients can't
  reach aren't listed. Its token is its port, and a heartbeat from the
  same IP keeps it listed for 5 minutes more; the game heartbeats every 2.
  A heartbeat for a server that isn't listed gets `invalid`, and the game
  registers again. One that another node lists is taken over, with what
  that node has.

  The game unregisters without its token, so the master can't tell which
  of the servers at an IP stopped. 10 seconds later it connects to each
  of them it lists, and drops those that don't take the connection and
  haven't heartbeat since.

  Each connection is one request, and is closed after the reply. A
  listener process owns the socket; an acceptor hands each connection to
  a task under a `Task.Supervisor`. 256 at once, 8 from an IP, closed 15
  seconds after they open; time a list waits for the reply budget doesn't
  count, up to a minute of it (`Exmaster.Paid`).
  """
  use GenServer
  require Logger

  alias Exmaster.{Addr, Paid, RateLimit, Store, VS}

  @game "vintagestory"

  @max_conns 256
  @max_per_ip 8
  # Per IP: 64 connections at once, then one a second. The game registers
  # once, as it starts, and doesn't try again if the master doesn't
  # answer, so a host that starts all its servers at once has to get
  # through.
  @connect_limit {1, 1_000, 64}
  # Lists per IP, as list queries to the other masters: 5 at once, then
  # one every 3 seconds.
  @list_limit {1, 3_000, 5}
  # Connections to servers, to see they take them, per IP, as the other
  # masters' queries to servers that aren't listed: 64 at once, then one a
  # second.
  @probe_limit {1, 1_000, 64}
  # Unregistrations that have the servers at an IP checked: 4 at once,
  # then one every 10 seconds. Each checks every server at its IP.
  @unregister_limit {1, 10_000, 4}
  # The request has to be in this long after connecting. A connection is
  # closed this long after it opened, whatever it is doing, so one that
  # reads slowly can't keep a slot.
  @timeout 10_000
  @lifetime 15_000
  @ttl 300_000
  @probe_timeout 3_000
  # A server unregisters as it begins to shut down, and closes its port a
  # moment later.
  @unregister_wait 10_000
  @max_headers 64
  @max_body 65_536

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.get(opts, :ip), Keyword.get(opts, :port, 0)},
      start: {__MODULE__, :start_link, [opts]}
    }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def store, do: :exmaster_vs

  @doc "The port the listener is bound to, for listeners started on port 0."
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip)
    # What each connection needs. :ttl, :unregister_wait and :lifetime
    # are for tests.
    conf = %{
      owner: self(),
      store: Keyword.get(opts, :store, store()),
      ttl: Keyword.get(opts, :ttl, @ttl),
      unregister_wait: Keyword.get(opts, :unregister_wait, @unregister_wait),
      lifetime: Keyword.get(opts, :lifetime, @lifetime)
    }

    # Accepted sockets inherit these. The request line and headers are
    # read as Erlang parses HTTP, the body raw.
    sock_opts = [
      :binary,
      :inet,
      active: false,
      packet: :http_bin,
      packet_size: 8_192,
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
        {:ok, tasks} = Task.Supervisor.start_link(max_children: @max_conns)
        me = self()
        spawn_link(fn -> accept(lsock, me) end)
        Logger.info("Vintage Story master listening on inet port #{port}")
        {:ok, %{lsock: lsock, port: port, tasks: tasks, conf: conf, conns: %{}, ips: %{}}}

      {:error, reason} ->
        {:stop, {:listen, "Vintage Story", ip, Keyword.get(opts, :port), reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  # A connection from ip wants a task.
  def handle_call({:start, ip}, _from, state) do
    with true <- Map.get(state.ips, ip, 0) < @max_per_ip,
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
         :ok <- RateLimit.take({:vs, :connect, ip}, @connect_limit, 1, Exmaster.now()),
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
        ends = Exmaster.now() + conf.lifetime
        {:ok, kill} = :timer.kill_after(conf.lifetime)

        try do
          request(sock, conf, {kill, ends})
        after
          :gen_tcp.close(sock)
        end
    after
      1_000 -> :ok
    end
  end

  # A peer that has gone makes a recv, send or peername fail, which ends
  # the request like any refusal.
  defp request(sock, conf, life) do
    deadline = Exmaster.now() + @timeout

    with {:ok, {ip, _}} <- :inet.peername(sock),
         {:ok, method, path, length} <- head(sock, deadline) do
      case {method, VS.endpoint(path)} do
        {:GET, "list"} ->
          list(sock, ip, conf.store, life)

        {:POST, endpoint} when endpoint in ["register", "heartbeat", "unregister"] ->
          case body(sock, length, deadline) do
            {:ok, body} -> post(endpoint, body, sock, ip, conf, life)
            {:error, status} -> respond(sock, status, VS.reply("error", "bad request"))
            :error -> :ok
          end

        {_, endpoint} when endpoint in ["list", "register", "heartbeat", "unregister"] ->
          respond(sock, 405, VS.reply("error", "method not allowed"))

        _ ->
          respond(sock, 404, VS.reply("error", "not found"))
      end
    else
      {:error, status} -> respond(sock, status, VS.reply("error", "bad request"))
      _ -> :ok
    end
  end

  # The request line and headers: `{:ok, method, path, content length}`,
  # `{:error, status}` for a request that can't be served, or :error when
  # the connection closes or the deadline passes.
  defp head(sock, deadline) do
    case recv(sock, deadline) do
      {:ok, {:http_request, method, {:abs_path, path}, _}} ->
        headers(sock, method, path, deadline)

      {:ok, {:http_request, _, _, _}} ->
        {:error, 400}

      {:ok, {:http_error, _}} ->
        {:error, 400}

      _ ->
        :error
    end
  end

  defp headers(sock, method, path, deadline, length \\ 0, n \\ 0)

  defp headers(_sock, _method, _path, _deadline, _length, @max_headers), do: {:error, 431}

  defp headers(sock, method, path, deadline, length, n) do
    case recv(sock, deadline) do
      {:ok, :http_eoh} ->
        {:ok, method, path, length}

      {:ok, {:http_header, _, :"Content-Length", _, value}} ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> headers(sock, method, path, deadline, length, n + 1)
          _ -> {:error, 400}
        end

      # The game sends its JSON with a length; a chunked body isn't read.
      {:ok, {:http_header, _, :"Transfer-Encoding", _, _}} ->
        {:error, 411}

      {:ok, {:http_header, _, _, _, _}} ->
        headers(sock, method, path, deadline, length, n + 1)

      {:ok, {:http_error, _}} ->
        {:error, 400}

      _ ->
        :error
    end
  end

  defp body(_sock, length, _deadline) when length > @max_body, do: {:error, 413}
  defp body(_sock, 0, _deadline), do: {:ok, ""}

  defp body(sock, length, deadline) do
    with :ok <- :inet.setopts(sock, packet: :raw),
         {:ok, body} <- recv(sock, length, deadline) do
      {:ok, body}
    else
      _ -> :error
    end
  end

  defp recv(sock, length \\ 0, deadline) do
    wait = deadline - Exmaster.now()
    if wait > 0, do: :gen_tcp.recv(sock, length, wait), else: {:error, :timeout}
  end

  defp respond(sock, status, body) do
    :gen_tcp.send(sock, [response_head(status, IO.iodata_length(body)), body])
  end

  defp response_head(status, length) do
    reason =
      case status do
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        405 -> "Method Not Allowed"
        411 -> "Length Required"
        413 -> "Content Too Large"
        429 -> "Too Many Requests"
        431 -> "Request Header Fields Too Large"
        503 -> "Service Unavailable"
      end

    "HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\n" <>
      "Content-Length: #{length}\r\nConnection: close\r\n\r\n"
  end

  # The list. The least a reply costs is reserved before the list is
  # made, as the other masters reserve it; the rest is paid a chunk at a
  # time, waiting for the budget when it runs out, so a list larger than
  # its burst still goes out, at its rate. The time it waits moves the
  # connection's end, which Exmaster.Paid keeps from here on in place of
  # the kill timer.
  defp list(sock, ip, store, {kill, ends}) do
    now = Exmaster.now()

    with {:limit, :ok} <- {:limit, RateLimit.take({:vs, :list, ip}, @list_limit, 1, now)},
         {:budget, :ok} <- {:budget, RateLimit.reserve_reply(now)} do
      entries = for {_, entry} <- Enum.sort(Store.all(store, now, @game)), do: entry.json
      parts = VS.list(entries)
      length = parts |> Enum.map(&IO.iodata_length/1) |> Enum.sum()
      Logger.debug("vs: list for #{:inet.ntoa(ip)}, #{length(entries)} servers")

      :timer.cancel(kill)

      with :ok <- :gen_tcp.send(sock, response_head(200, length)),
           do: Paid.send(sock, Paid.chunks(parts), RateLimit.min_reply(), ends)
    else
      {:limit, _} ->
        respond(sock, 429, VS.reply("error", "too many requests"))

      {:budget, _} ->
        Logger.debug("vs: a list over the reply budget")
        respond(sock, 503, VS.reply("error", "busy"))
    end
  end

  defp post("register", body, sock, ip, conf, _life) do
    reply =
      case VS.parse_register(body) do
        {:ok, server} -> register(server, ip, conf, Exmaster.now())
        {:error, reason} -> VS.reply("error", reason)
      end

    respond(sock, 200, reply)
  end

  defp post("heartbeat", body, sock, ip, conf, _life) do
    reply =
      case VS.parse_heartbeat(body) do
        {:ok, hb} -> heartbeat(hb, ip, conf, Exmaster.now())
        {:error, reason} -> VS.reply("error", reason)
      end

    respond(sock, 200, reply)
  end

  # The reply first: the game doesn't wait for it. Then the check, once
  # the server has had time to close its port.
  defp post("unregister", body, sock, ip, conf, {kill, _}) do
    case VS.parse_unregister(body) do
      {:ok, port} ->
        respond(sock, 200, VS.reply("ok", nil))
        :gen_tcp.close(sock)
        :timer.cancel(kill)
        unregister(port, ip, conf, Exmaster.now())

      {:error, reason} ->
        respond(sock, 200, VS.reply("error", reason))
    end
  end

  defp register(server, ip, conf, now) do
    addr = {ip, server.port}
    existing = Store.lookup(conf.store, addr, now)

    cond do
      existing == nil and RateLimit.take({:vs, :probe, ip}, @probe_limit, 1, now) != :ok ->
        VS.reply("error", "too many registrations, try again later")

      existing == nil and not reachable?(addr) ->
        Logger.debug("vs: #{Addr.to_string(addr)} doesn't take connections")
        VS.reply("error", "port #{server.port} doesn't take connections from the master")

      true ->
        players = if existing, do: existing.clients, else: 0

        case put(addr, server, players, existing, conf, Exmaster.now()) do
          :ok ->
            unless existing,
              do:
                Logger.info("vs: #{Addr.to_string(addr)} listed, version=#{server.game_version}")

            VS.reply("ok", VS.token(server.port))

          {:error, reason} ->
            Logger.warning("vs: #{Addr.to_string(addr)} not listed: #{reason}")
            VS.reply("error", "not listed: #{reason}")
        end
    end
  end

  defp heartbeat(hb, ip, conf, now) do
    addr = {ip, hb.port}
    existing = Store.lookup(conf.store, addr, now)

    case existing || Store.lookup_replica(conf.store, addr, now) do
      nil ->
        VS.reply("invalid", nil)

      listed ->
        case put(addr, listed.server, hb.players, existing, conf, now) do
          :ok -> VS.reply("ok", nil)
          {:error, reason} -> VS.reply("error", "not listed: #{reason}")
        end
    end
  end

  # Writes the entry if the server's current one is still what it was read
  # as: another request may have written it in between.
  defp put(addr, server, players, existing, conf, now, tries \\ 3) do
    entry = %{
      game: @game,
      version: server.game_version,
      hostname: server.name,
      clients: players,
      max_clients: server.max_players,
      server: server,
      json: VS.encode_entry(addr, server, players),
      via: conf.owner,
      seen: now,
      expires: now + conf.ttl
    }

    case Store.put(conf.store, addr, entry, now, existing) do
      {:error, :changed} when tries > 1 ->
        existing = Store.lookup(conf.store, addr, now)
        put(addr, server, players, existing, conf, now, tries - 1)

      result ->
        result
    end
  end

  # Without a port, every server this node lists at the IP is checked.
  defp unregister(port, ip, conf, now) do
    addrs =
      case port do
        nil -> for {addr, _} <- Store.on_ip(conf.store, ip, now), do: addr
        port -> if Store.lookup(conf.store, {ip, port}, now), do: [{ip, port}], else: []
      end

    with [_ | _] <- addrs,
         :ok <- RateLimit.take({:vs, :unregister, ip}, @unregister_limit, 1, now),
         :ok <- RateLimit.take({:vs, :probe, ip}, @probe_limit, length(addrs), now) do
      Process.sleep(conf.unregister_wait)

      addrs
      |> Task.async_stream(&{&1, reachable?(&1)},
        max_concurrency: length(addrs),
        timeout: @probe_timeout + 1_000
      )
      |> Enum.each(fn
        {:ok, {addr, false}} -> Store.drop_unless_seen(conf.store, addr, now + 1, conf.owner)
        _ -> :ok
      end)
    end
  end

  defp reachable?({ip, port}) do
    case :gen_tcp.connect(ip, port, [:binary, active: false], @probe_timeout) do
      {:ok, s} ->
        :gen_tcp.close(s)
        true

      {:error, _} ->
        false
    end
  end
end
