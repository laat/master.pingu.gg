defmodule Exmaster.GP.Server do
  @moduledoc """
  GameSpy Presence's login (gpcm), on TCP 29900 by default, for the QR2
  games that log in before they heartbeat: Unreal Tournament 3's servers
  won't heartbeat until they are logged in, and hold the connection open.
  Wire format in `Exmaster.GP`; see `docs/qr2.md`.

  Any name logs in with one password, public, `pingu` unless
  `gp_password` (`EXMASTER_GP_PASSWORD`) says another: the game checks
  that the master knows its password, so the master can't take any, and
  keeps no accounts. A name's profile id is a hash of it. A login is
  answered and the connection kept until the client logs out or has sent
  nothing for 5 minutes (it sends `\\ka\\` every 2); the rest of what it
  sends is ignored.

  A listener process owns the socket; an acceptor hands each connection
  to a task under a `Task.Supervisor`, which takes at most 4,096 at once.
  An IP can have 40 open, and open 10 at once, then one a second. A
  client has 10 seconds to log in.
  """
  use GenServer
  require Logger

  alias Exmaster.{Addr, GP, GS, RateLimit}

  @max_connections 4_096
  @per_ip 40
  @connect_limit {1, 1_000, 10}
  @timeout 10_000
  @idle 300_000
  @max_buffer 4_096

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.get(opts, :ip), Keyword.get(opts, :port, 0)},
      start: {__MODULE__, :start_link, [opts]}
    }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "No store: the login lists nothing."
  def store, do: nil

  @doc "The port the listener is bound to, for listeners started on port 0."
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip)

    # :idle is for tests.
    conf = %{
      hash:
        GP.password_hash(
          Keyword.get_lazy(opts, :password, fn ->
            Application.fetch_env!(:exmaster, :gp_password)
          end)
        ),
      idle: Keyword.get(opts, :idle, @idle)
    }

    # Accepted sockets inherit these.
    sock_opts = [
      :binary,
      :inet,
      active: false,
      reuseaddr: true,
      backlog: 128,
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
        Logger.info("GameSpy login listening on inet port #{port}")
        {:ok, %{lsock: lsock, port: port, tasks: tasks, conf: conf, conns: %{}, ips: %{}}}

      {:error, reason} ->
        {:stop, {:listen, "GameSpy login", ip, Keyword.get(opts, :port), reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:start, ip}, _from, state) do
    with true <- Map.get(state.ips, ip, 0) < @per_ip,
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
         :ok <- RateLimit.take({:gp, :connect, ip}, @connect_limit, 1, Exmaster.now()),
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

  # A client that has gone makes a send, recv or peername fail, which ends
  # the conversation like any refusal.
  defp converse(sock, conf) do
    challenge = for <<b <- :crypto.strong_rand_bytes(10)>>, into: "", do: <<?A + rem(b, 26)>>

    with {:ok, peer} <- :inet.peername(sock),
         :ok <- :gen_tcp.send(sock, GP.greeting(challenge)),
         {:ok, login, buf} <- login(sock, "", Exmaster.now() + @timeout) do
      log_in(sock, login, buf, challenge, peer, conf)
    end
  end

  # The first message that is a login, within the deadline.
  defp login(sock, buf, deadline) do
    case next(sock, buf, deadline) do
      {:ok, "\\login\\" <> _ = msg, buf} -> {:ok, GS.parse(msg), buf}
      {:ok, _, buf} -> login(sock, buf, deadline)
      other -> other
    end
  end

  defp log_in(sock, login, buf, challenge, peer, conf) do
    user = GP.user(login)
    client_challenge = login["challenge"]
    # UT3 sends more after the 32 characters of its response.
    response = binary_slice(login["response"] || "", 0, 32)

    cond do
      user == nil or client_challenge == nil ->
        :gen_tcp.send(sock, GP.error(260, "This master takes logins by name only.", login["id"]))

      response != GP.response(conf.hash, user, client_challenge, challenge) ->
        :gen_tcp.send(sock, GP.error(260, "The password provided is incorrect.", login["id"]))

      true ->
        name = login["uniquenick"] || login["user"]
        id = GP.profile_id(name)
        ticket = for <<b <- :crypto.strong_rand_bytes(22)>>, into: "", do: <<?a + rem(b, 26)>>
        proof = GP.proof(conf.hash, user, client_challenge, challenge)

        with :ok <-
               :gen_tcp.send(sock, GP.logged_in(name, id, proof, ticket <> "__", login["id"])) do
          Logger.info("gp: #{inspect(name)} logged in from #{Addr.to_string(peer)}")
          session(sock, buf, conf)
        end
    end
  end

  # The logged-in connection: kept until a logout, or nothing for a while.
  defp session(sock, buf, conf) do
    case next(sock, buf, Exmaster.now() + conf.idle) do
      {:ok, "\\logout\\" <> _, _} -> :ok
      {:ok, _, buf} -> session(sock, buf, conf)
      _ -> :ok
    end
  end

  # The next message: {:ok, message, what follows}, or :error when the
  # connection closes, idles past the deadline or sends too much without
  # ending a message.
  defp next(sock, buf, deadline) do
    case GP.split(buf) do
      {[msg | more], rest} ->
        {:ok, msg, Enum.map_join(more, &(&1 <> "\\final\\")) <> rest}

      {[], _} when byte_size(buf) > @max_buffer ->
        :error

      {[], _} ->
        wait = deadline - Exmaster.now()

        with true <- wait > 0,
             {:ok, data} <- :gen_tcp.recv(sock, 0, wait) do
          next(sock, buf <> data, deadline)
        else
          _ -> :error
        end
    end
  end
end
