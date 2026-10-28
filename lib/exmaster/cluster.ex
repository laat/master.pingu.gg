defmodule Exmaster.Cluster do
  @moduledoc """
  Keeps this node connected to the other nodes in `peers`
  (`EXMASTER_PEERS`), trying every 5 seconds, so their stores can share
  their servers (see `Exmaster.Store`). Started only when there are peers.
  """
  use GenServer
  require Logger

  @interval 5_000

  def start_link(peers), do: GenServer.start_link(__MODULE__, peers, name: __MODULE__)

  @impl true
  def init(peers) do
    if Node.alive?() do
      :ok = :net_kernel.monitor_nodes(true)
      send(self(), :connect)
    else
      Logger.warning("peers set, but this node isn't distributed; see README.md")
    end

    {:ok, List.delete(peers, node())}
  end

  @impl true
  def handle_info(:connect, peers) do
    for p <- peers, p not in Node.list(), do: Node.connect(p)
    Process.send_after(self(), :connect, @interval)
    {:noreply, peers}
  end

  def handle_info({:nodeup, node}, peers) do
    Logger.info("node #{node} connected")
    {:noreply, peers}
  end

  def handle_info({:nodedown, node}, peers) do
    Logger.warning("node #{node} disconnected")
    {:noreply, peers}
  end
end
