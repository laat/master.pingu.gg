defmodule Exmaster.Shared do
  @moduledoc """
  Masters on one socket: Quake 2's, GameSpy's first protocol's and QR2's
  (`Exmaster.QR2`), whose games all heartbeat UDP 27900 and can't be told
  another port, so without this they need an address each.
  `Exmaster.Config` makes one of these for two or three `q2`, `gs` and
  `qr2` listeners on the same address and port; `ctx.masters` says which.

  The first bytes tell the packets apart. Quake 2 takes the first word of
  a packet as its command, so nothing it sends starts with `\\` or a byte
  under 10; everything GameSpy's first protocol sends starts with `\\`,
  and everything a QR2 server sends with its packet type, 1 to 9, and its
  4-byte instance key:

  | Starts with | Goes to |
  |---|---|
  | `\\hb\\` | nobody: the All-Seeing Eye's heartbeat, which BF1942 sends to the same port |
  | `\\` | `Exmaster.GS.Master`: heartbeats and the replies to `\\secure\\` |
  | a byte from 1 to 9, and 4 more | `Exmaster.QR2.Master`: heartbeats, replies to challenges, available checks, keepalives |
  | anything else | `Exmaster.Q2.Master`: out-of-band packets and `query` |

  A packet for a master that isn't one of them is dropped. Each master
  keeps its own state and store. A tick runs each, on its own: if one
  raises, its state stays as it was and the others' ticks still count, as
  if each had a socket of its own. A packet goes to one of them only, so
  the listener's own rescue does for packets.
  """
  @behaviour Exmaster.Protocol

  alias Exmaster.{GS, Q2, QR2, RateLimit}
  require Logger

  @masters [Q2.Master, GS.Master, QR2.Master]

  @doc "The masters that can share a socket, in the order they are named."
  def masters, do: @masters

  @impl true
  def name, do: "Shared"

  @impl true
  def family, do: :inet

  @impl true
  def store, do: Q2.Master.store()

  @impl true
  def init(now), do: Map.new(@masters, &{&1, &1.init(now)})

  @impl true
  def handle_packet(data, from, ctx, now, state) do
    with master when master != :none <- master_for(data),
         true <- master in ctx.masters do
      {sends, pstate} = master.handle_packet(data, from, ctx_for(master, ctx), now, state[master])
      {sends, %{state | master => pstate}}
    else
      _ -> {[], state}
    end
  end

  defp master_for("\\hb\\" <> _), do: :none
  defp master_for("\\" <> _), do: GS.Master
  defp master_for(<<type, _::binary-4, _::binary>>) when type in 1..9, do: QR2.Master
  defp master_for(_), do: Q2.Master

  @impl true
  def tick(ctx, now, state) do
    Enum.reduce(ctx.masters, {[], state}, fn master, {sends, state} ->
      {more, pstate} = isolated(master, ctx_for(master, ctx), now, state[master])
      {sends ++ more, %{state | master => pstate}}
    end)
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

  # Each master lists into its own store.
  defp ctx_for(master, ctx), do: %{ctx | store: master.store()}
end
