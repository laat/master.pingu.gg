defmodule Exmaster.SB.ListServer do
  @moduledoc """
  GameSpy's server browsing, the list side of QR2: a TCP socket, 28910 by
  default, that gives clients the servers `Exmaster.QR2.Master` lists.
  Wire format in `Exmaster.SB`; see `docs/gamespy.md`.

  A client sends a list request naming the game it wants and the game it
  is, and gets the list encrypted under the asking game's secret key, then
  the connection closed. Any client game the master knows may list any
  game; one it doesn't know can't be answered, as its key is needed. The
  filter is ignored. Other requests (a server's rules, a message for a
  server, updates as they come) aren't answered.

  A listener process owns the socket; an acceptor hands each connection to
  a task under a `Task.Supervisor` that takes at most 64 at once. A task
  has 5 seconds to read the request and is killed, with its socket, 10
  seconds after it started, but for the time its list waits for the reply
  budget (`Exmaster.Paid`).
  """
  use GenServer
  require Logger

  alias Exmaster.{Paid, QR2, RateLimit, SB, Store}
  alias Exmaster.SB.Crypt

  @max_connections 64
  # Per IP: 5 connections at once, then one every 3 seconds, as list
  # queries to the other masters.
  @connect_limit {1, 3_000, 5}
  @timeout 5_000
  @lifetime 10_000
  @max_request 1_024

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.get(opts, :ip), Keyword.get(opts, :port, 0)},
      start: {__MODULE__, :start_link, [opts]}
    }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The store the lists come from, the QR2 master's."
  def store, do: Exmaster.QR2.Master.store()

  @doc "The port the listener is bound to, for listeners started on port 0."
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip)
    store = Keyword.get(opts, :store, store())
    # Accepted sockets inherit these.
    sock_opts = [
      :binary,
      :inet,
      active: false,
      reuseaddr: true,
      backlog: 128,
      send_timeout: @timeout,
      send_timeout_close: true
    ]

    sock_opts = if ip, do: [ip: ip] ++ sock_opts, else: sock_opts

    case :gen_tcp.listen(Keyword.get(opts, :port, 0), sock_opts) do
      {:ok, lsock} ->
        {:ok, port} = :inet.port(lsock)
        {:ok, tasks} = Task.Supervisor.start_link(max_children: @max_connections)
        spawn_link(fn -> accept(lsock, tasks, store) end)
        Logger.info("GameSpy server browsing listening on inet port #{port}")
        {:ok, %{lsock: lsock, port: port}}

      {:error, reason} ->
        {:stop, {:listen, "GameSpy server browsing", ip, Keyword.get(opts, :port), reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept(lsock, tasks, store) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        hand_off(sock, tasks, store)
        accept(lsock, tasks, store)

      {:error, reason} ->
        exit({:accept, reason})
    end
  end

  defp hand_off(sock, tasks, store) do
    with {:ok, {ip, _}} <- :inet.peername(sock),
         :ok <- RateLimit.take({:sb, :connect, ip}, @connect_limit, 1, Exmaster.now()),
         {:ok, pid} <- Task.Supervisor.start_child(tasks, fn -> serve(store) end),
         :ok <- :gen_tcp.controlling_process(sock, pid) do
      send(pid, {:socket, sock})
    else
      _ -> :gen_tcp.close(sock)
    end
  end

  defp serve(store) do
    receive do
      {:socket, sock} ->
        # Killed, the task takes the socket, which it owns, with it.
        ends = Exmaster.now() + @lifetime
        {:ok, kill} = :timer.kill_after(@lifetime)

        try do
          converse(sock, store, {kill, ends})
        after
          :gen_tcp.close(sock)
        end
    after
      1_000 -> :ok
    end
  end

  # A client that has gone (a scanner that connects and resets) makes a
  # recv or peername fail, which ends the conversation like any refusal.
  # The reply budget is reserved before the list is made and encrypted, as
  # the other masters reserve it.
  defp converse(sock, store, {kill, ends}) do
    with {:ok, {ip, _}} <- :inet.peername(sock),
         {:ok, request} <- read(sock, "", Exmaster.now() + @timeout),
         {:ok, req} <- SB.parse_request(request),
         key when key != nil <- QR2.client_key(req.from),
         now = Exmaster.now(),
         {:budget, :ok} <- {:budget, RateLimit.reserve_reply(now)} do
      {header, crypt} = SB.crypt(req.challenge, key)
      {parts, count} = answer(req, req.source_ip || ip, store, now)
      Logger.debug("sb: #{inspect(req.game)} list for #{:inet.ntoa(ip)}, #{count} servers")
      :timer.cancel(kill)

      # The crypt header as it is, then the list a chunk at a time,
      # encrypted as it goes, so a long list is never all encrypted at once.
      encrypted =
        parts
        |> Paid.chunks()
        |> Stream.transform(crypt, fn {chunk, size}, crypt ->
          {cipher, crypt} = Crypt.encrypt(crypt, IO.iodata_to_binary(chunk))
          {[{cipher, size}], crypt}
        end)

      Paid.send(
        sock,
        Stream.concat([{header, byte_size(header)}], encrypted),
        RateLimit.min_reply(),
        ends
      )
    else
      {:budget, _} -> Logger.debug("sb: a list over the reply budget")
      _ -> :ok
    end
  end

  # The answer in parts, a server's record each, for Exmaster.Paid to
  # gather into chunks.
  defp answer(req, ip, store, now) do
    case QR2.default_port(req.game) do
      nil ->
        {[SB.error(ip, "This master doesn't list #{req.game}.")], 0}

      port when req.list? ->
        servers =
          store
          |> Store.all(now, req.game)
          |> Enum.sort()
          |> then(&if(req.max, do: Enum.take(&1, req.max), else: &1))

        {[SB.head(ip, port) | SB.encode_list(req.fields, servers, port)], length(servers)}

      port ->
        {[SB.head(ip, port)], 0}
    end
  end

  # Reads the request: a 2-byte length, counting itself, and the rest.
  defp read(sock, buf, deadline) do
    case buf do
      <<len::16, _::binary>> when len < 3 or len > @max_request ->
        :error

      <<len::16, rest::binary>> when byte_size(rest) >= len - 2 ->
        {:ok, binary_part(rest, 0, len - 2)}

      _ ->
        wait = deadline - Exmaster.now()

        with true <- wait > 0,
             {:ok, data} <- :gen_tcp.recv(sock, 0, wait) do
          read(sock, buf <> data, deadline)
        else
          _ -> :error
        end
    end
  end
end
