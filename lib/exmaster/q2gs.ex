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

  Each master keeps its own state and store; ticks run both.
  """
  @behaviour Exmaster.Protocol

  alias Exmaster.{GS, Q2}

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
    {q2_sends, q2} = Q2.Master.tick(ctx, now, state.q2)
    {gs_sends, gs} = GS.Master.tick(gs_ctx(ctx), now, state.gs)
    {q2_sends ++ gs_sends, %{state | q2: q2, gs: gs}}
  end

  # The listener's ctx carries Quake 2's store; GameSpy lists into its own.
  defp gs_ctx(ctx), do: %{ctx | store: GS.Master.store()}
end
