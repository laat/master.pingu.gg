defmodule Exmaster.Listener do
  @moduledoc """
  A UDP socket and the master protocol that answers on it, in one
  process. Packets come in as messages (`{:active, 100}`, re-armed on
  `:udp_passive`, so a flood waits in the socket's buffer rather than in
  the mailbox) and are handled one at a time. Replies go out through the
  same socket: a server behind NAT may only take packets from the address
  it sent its heartbeat to, and a client expects the list from the address
  it asked.

  Protocols with a dual-stack family listen on `::` with `ipv6_v6only`
  off, and fall back to IPv4 where there is no IPv6.

  A packet that makes the protocol raise is dropped, and logged at most
  once a minute. Letting it crash the listener would let anyone who finds
  such a packet restart it in a loop until the supervisor gave up.
  """
  use GenServer
  require Logger

  alias Exmaster.{Addr, RateLimit}

  @tick 1_000
  @active 100

  def child_spec(opts) do
    %{
      id: {Keyword.fetch!(opts, :protocol), Keyword.get(opts, :ip), Keyword.get(opts, :port, 0)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The port the listener is bound to, for listeners started on port 0."
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(opts) do
    protocol = Keyword.fetch!(opts, :protocol)
    ip = Keyword.get(opts, :ip)

    case open(protocol.family(), ip, Keyword.get(opts, :port, 0)) do
      {:ok, family, socket} ->
        {:ok, {_, port} = id} = :inet.sockname(socket)

        ctx = %{
          id: Addr.unmap(id),
          port: port,
          label: Keyword.get(opts, :label),
          store: Keyword.get(opts, :store, protocol.store()),
          masters: Keyword.get(opts, :masters, []),
          challenge_ttl: Application.fetch_env!(:exmaster, :challenge_ttl),
          server_ttl: Application.fetch_env!(:exmaster, :server_ttl)
        }

        Logger.info(
          "#{name(protocol, ctx)} master listening on #{family} port #{port}" <>
            if(ctx.label, do: ", label #{ctx.label}", else: "")
        )

        Process.send_after(self(), :tick, @tick)

        {:ok,
         %{
           socket: socket,
           family: family,
           protocol: protocol,
           ctx: ctx,
           pstate: protocol.init(Exmaster.now())
         }}

      {:error, reason} ->
        {:stop, {:listen, protocol.name(), ip, Keyword.get(opts, :port), reason}}
    end
  end

  # A shared socket is named for its masters: "Quake 2 and GameSpy".
  defp name(protocol, %{masters: []}), do: protocol.name()

  defp name(_protocol, %{masters: masters}) do
    {last, rest} = masters |> Enum.map(& &1.name()) |> List.pop_at(-1)
    if rest == [], do: last, else: Enum.join(rest, ", ") <> " and " <> last
  end

  defp open(family, ip, port) do
    opts = [:binary, active: @active, recbuf: 1_048_576, buffer: 65_536]

    case {family, ip} do
      {_, {_, _, _, _}} ->
        open_socket(:inet, port, [ip: ip] ++ opts)

      {:inet, nil} ->
        open_socket(:inet, port, opts)

      {:inet6, nil} ->
        with {:error, _} <- open_socket(:inet6, port, [ipv6_v6only: false] ++ opts),
             do: open_socket(:inet, port, opts)

      {_, ip} ->
        open_socket(:inet6, port, [ip: ip, ipv6_v6only: false] ++ opts)
    end
  end

  defp open_socket(family, port, opts) do
    with {:ok, socket} <- :gen_udp.open(port, [family | opts]), do: {:ok, family, socket}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.ctx.port, state}

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = state) do
    from = Addr.unmap({ip, port})
    now = Exmaster.now()

    handle = fn -> state.protocol.handle_packet(data, from, state.ctx, now, state.pstate) end

    {:noreply,
     run(state, now, handle, fn ->
       "packet from #{Addr.to_string(from)}: #{inspect(binary_slice(data, 0, 256))}"
     end)}
  end

  def handle_info({:udp_passive, socket}, %{socket: socket} = state) do
    :ok = :inet.setopts(socket, active: @active)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick)
    now = Exmaster.now()
    tick = fn -> state.protocol.tick(state.ctx, now, state.pstate) end
    {:noreply, run(state, now, tick, fn -> "tick" end)}
  end

  defp run(state, now, f, what) do
    {sends, pstate} =
      try do
        f.()
      rescue
        e ->
          crashed(state, now, what, Exception.format(:error, e, __STACKTRACE__))
          {[], state.pstate}
      catch
        kind, reason ->
          crashed(state, now, what, Exception.format(kind, reason, __STACKTRACE__))
          {[], state.pstate}
      end

    Enum.each(sends, &deliver(state, &1))
    %{state | pstate: pstate}
  end

  defp crashed(state, now, what, error) do
    if RateLimit.take({:crash_log, state.ctx.id}, {1, 60_000, 1}, 1, now) == :ok do
      Logger.error("#{state.protocol.name()}: #{what.()} failed:\n#{error}")
    end
  end

  defp deliver(%{family: :inet6} = state, {packet, {{_, _, _, _} = ip, port}}),
    do: deliver(state, {packet, {Addr.map_v4(ip), port}})

  defp deliver(state, {packet, {ip, port}}) do
    case :gen_udp.send(state.socket, ip, port, packet) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("send to #{inspect(ip)}:#{port} failed: #{inspect(reason)}")
    end
  end
end
