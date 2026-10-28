defmodule Exmaster.GS.ListServer do
  @moduledoc """
  The GameSpy master's list side: a TCP socket, 28900 by default, that
  gives clients the servers `Exmaster.GS.Master` lists. See
  `docs/gamespy.md`.

  On connecting, a client gets `\\basic\\\\secure\\<challenge>`. It sends
  its game, `\\enctype\\` and a `\\validate\\` of the challenge, then
  `\\list\\cmp\\gamename\\<game>\\final\\`, and gets the list and the
  connection closed. The asking game can be another than the listed one. The list is 6 bytes a server, IPv4 address and query
  port, and `\\final\\`; with `\\enctype\\2`, as Battlefield 1942 asks,
  encrypted under the asking game's key (`Exmaster.GS.Enctype2`). Without
  `cmp` it is text, `\\ip\\a.b.c.d:port` a server. `\\where\\` filters are
  ignored, as by the master BF1942's players use now: clients filter
  themselves. So is the client's `\\validate\\`: the keys are public.

  A listener process owns the socket; an acceptor hands each connection to
  a task under a `Task.Supervisor` that takes at most 64 at once.
  """
  use GenServer
  require Logger

  alias Exmaster.{Addr, GS, RateLimit, Store}
  alias Exmaster.GS.Enctype2

  @max_connections 64
  # Per IP: 5 connections at once, then one every 3 seconds, as list
  # queries to the other masters.
  @connect_limit {1, 3_000, 5}
  # A client has this long from connecting to ask, and this much to say.
  @timeout 5_000
  @max_request 2_048

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.get(opts, :ip), Keyword.get(opts, :port, 0)},
      start: {__MODULE__, :start_link, [opts]}
    }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The store the lists come from, the GameSpy master's."
  def store, do: Exmaster.GS.Master.store()

  @doc "The port the listener is bound to, for listeners started on port 0."
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip)
    store = Keyword.get(opts, :store, store())
    sock_opts = [:binary, :inet, active: false, reuseaddr: true, backlog: 128]
    sock_opts = if ip, do: [ip: ip] ++ sock_opts, else: sock_opts

    case :gen_tcp.listen(Keyword.get(opts, :port, 0), sock_opts) do
      {:ok, lsock} ->
        {:ok, port} = :inet.port(lsock)
        {:ok, tasks} = Task.Supervisor.start_link(max_children: @max_connections)
        me = self()
        spawn_link(fn -> accept(lsock, tasks, store, me) end)
        Logger.info("GameSpy list server listening on inet port #{port}")
        {:ok, %{lsock: lsock, port: port}}

      {:error, reason} ->
        {:stop, {:listen, "GameSpy lists", ip, Keyword.get(opts, :port), reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  defp accept(lsock, tasks, store, owner) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        hand_off(sock, tasks, store)
        accept(lsock, tasks, store, owner)

      {:error, reason} ->
        exit({:accept, reason})
    end
  end

  defp hand_off(sock, tasks, store) do
    with {:ok, {ip, _}} <- :inet.peername(sock),
         :ok <- RateLimit.take({:gs, :connect, ip}, @connect_limit, 1, Exmaster.now()),
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
        try do
          converse(sock, store)
        after
          :gen_tcp.close(sock)
        end
    after
      1_000 -> :ok
    end
  end

  defp converse(sock, store) do
    deadline = Exmaster.now() + @timeout
    :ok = :gen_tcp.send(sock, "\\basic\\\\secure\\" <> random_challenge())

    with {:ok, hello, request} <- read(sock, "", deadline),
         {:ok, list} <- list(request, hello, store) do
      {:ok, {ip, _} = peer} = :inet.peername(sock)
      now = Exmaster.now()

      with :ok <- RateLimit.reserve_reply(now),
           :ok <- RateLimit.charge_reply(byte_size(list), now) do
        Logger.debug("gs: list for #{Addr.to_string(peer)}, #{byte_size(list)} bytes")
        :gen_tcp.send(sock, list)
      else
        _ -> Logger.debug("gs: list for #{:inet.ntoa(ip)} over the reply budget")
      end
    end
  end

  # Reads until the client has sent its \list\ request and \final\ after
  # it: {:ok, the hello before it, the request}.
  defp read(sock, buf, deadline) do
    with [head, tail] <- :binary.split(buf, "\\list\\"),
         [list, _] <- :binary.split(tail, "\\final\\") do
      {:ok, GS.parse(head), GS.parse("\\list\\" <> list)}
    else
      _ ->
        wait = deadline - Exmaster.now()

        with true <- wait > 0 and byte_size(buf) < @max_request,
             {:ok, data} <- :gen_tcp.recv(sock, 0, wait) do
          read(sock, buf <> data, deadline)
        else
          _ -> :error
        end
    end
  end

  # Any client may list any game, as GameSpy's masters let it: qstat asks
  # as GameSpy Arcade (gamespy2). Encrypting takes the asking game's key.
  defp list(request, hello, store) do
    addrs =
      store
      |> Store.all(Exmaster.now(), request["gamename"])
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    body =
      if request["list"] == "cmp", do: GS.encode_list(addrs), else: GS.encode_text_list(addrs)

    case {hello["enctype"], GS.key(hello["gamename"])} do
      {"2", key} when key != nil -> {:ok, Enctype2.encode(body, key)}
      {e, _} when e in [nil, "0"] -> {:ok, body <> "\\final\\"}
      _ -> :error
    end
  end

  defp random_challenge,
    do: for(<<b <- :crypto.strong_rand_bytes(6)>>, into: "", do: <<?A + rem(b, 26)>>)
end
