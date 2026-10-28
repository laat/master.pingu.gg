defmodule Exmaster.Q2GS do
  @moduledoc """
  The Quake 2 and GameSpy masters on one socket. Both games heartbeat UDP
  27900 and neither can be told another port, so without this they need
  an address each. `Exmaster.Config` makes one of these for a `q2` and a
  `gs` listener on the same address and port.

  The first bytes tell the packets apart. Quake 2 takes the first word of
  a packet as its command, so nothing it sends starts with `\\`, and
  everything GameSpy's first protocol sends does:

  | Starts with | Goes to |
  |---|---|
  | `\\hb\\` | nobody: the All-Seeing Eye's heartbeat, which BF1942 sends to the same port |
  | `\\` | `Exmaster.GS.Master`: heartbeats and the replies to `\\secure\\` |
  | anything else | `Exmaster.Q2.Master`: out-of-band packets and `query` |

  Each master keeps its own state and store. A tick runs both, each on its
  own: if one raises, its state stays as it was and the other's tick still
  counts, as if each had a socket of its own. A packet goes to one of them
  only, so the listener's own rescue does for packets.
  """
  @behaviour Exmaster.Protocol

  alias Exmaster.{GS, Q2, RateLimit}
  require Logger

  @impl true
  def name, do: "Quake 2 and GameSpy"

  @impl true
  def family, do: :inet

  @impl true
  def store, do: Q2.Master.store()

  @impl true
  def init(now), do: %{q2: Q2.Master.init(now), gs: GS.Master.init(now)}

  @impl true
  def handle_packet("\\hb\\" <> _, _from, _ctx, _now, state), do: {[], state}

  def handle_packet("\\" <> _ = data, from, ctx, now, state) do
    {sends, gs} = GS.Master.handle_packet(data, from, gs_ctx(ctx), now, state.gs)
    {sends, %{state | gs: gs}}
  end

  def handle_packet(data, from, ctx, now, state) do
    {sends, q2} = Q2.Master.handle_packet(data, from, ctx, now, state.q2)
    {sends, %{state | q2: q2}}
  end

  @impl true
  def tick(ctx, now, state) do
    {q2_sends, q2} = isolated(Q2.Master, ctx, now, state.q2)
    {gs_sends, gs} = isolated(GS.Master, gs_ctx(ctx), now, state.gs)
    {q2_sends ++ gs_sends, %{state | q2: q2, gs: gs}}
  end

  # One master's tick; if it raises, nothing it would have sent and its
  # old state, logged at most once a minute per master.
  defp isolated(master, ctx, now, pstate) do
    master.tick(ctx, now, pstate)
  rescue
    e -> failed(master, ctx, now, pstate, Exception.format(:error, e, __STACKTRACE__))
  catch
    kind, reason ->
      failed(master, ctx, now, pstate, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp failed(master, ctx, now, pstate, error) do
    if RateLimit.take({:crash_log, ctx.id, master}, {1, 60_000, 1}, 1, now) == :ok do
      Logger.error("#{master.name()}: tick failed:\n#{error}")
    end

    {[], pstate}
  end

  # The listener's ctx carries Quake 2's store; GameSpy lists into its own.
  defp gs_ctx(ctx), do: %{ctx | store: GS.Master.store()}
end
