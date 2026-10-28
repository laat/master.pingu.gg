defmodule Exmaster.Application do
  @moduledoc """
  The supervision tree:

      Exmaster.Supervisor
      ├── Exmaster.RateLimit        token buckets, in ETS
      ├── Exmaster.PG               the pg scope the stores share their lists in
      ├── Exmaster.Store            :exmaster_q3, :exmaster_q2, :exmaster_qw
      ├── Exmaster.Cluster          connects to the other nodes, if there are any
      └── Exmaster.Listeners        an Exmaster.Listener per socket

  The stores own the server lists, so a listener that restarts loses
  nothing; a store that restarts starts empty, and servers come back with
  their next heartbeat, or with the next node's list.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Exmaster.Q3.Challenge.init_key()
    listeners = Exmaster.Config.listeners!(Application.fetch_env!(:exmaster, :listen))
    peers = Application.fetch_env!(:exmaster, :peers)

    listeners_sup = %{
      id: Exmaster.Listeners,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           Enum.map(listeners, &{Exmaster.Listener, &1}),
           [strategy: :one_for_one, name: Exmaster.Listeners, max_restarts: 10, max_seconds: 10]
         ]}
    }

    children =
      [
        Exmaster.RateLimit,
        %{id: Exmaster.PG, start: {:pg, :start_link, [Exmaster.Store.scope()]}},
        {Exmaster.Store, name: :exmaster_q3},
        {Exmaster.Store, name: :exmaster_q2},
        {Exmaster.Store, name: :exmaster_qw}
      ] ++ if(peers == [], do: [], else: [{Exmaster.Cluster, peers}]) ++ [listeners_sup]

    Supervisor.start_link(children, strategy: :one_for_one, name: Exmaster.Supervisor)
  end
end
