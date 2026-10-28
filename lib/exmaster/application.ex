defmodule Exmaster.Application do
  @moduledoc """
  The supervision tree:

      Exmaster.Supervisor
      ├── Exmaster.RateLimit        token buckets, in ETS
      ├── Exmaster.Store            :exmaster_q3, :exmaster_q2, :exmaster_qw
      └── Exmaster.Listeners        an Exmaster.Listener per socket

  The stores own the server lists, so a listener that restarts loses
  nothing; a store that restarts starts empty, and servers come back with
  their next heartbeat.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Exmaster.Q3.Challenge.init_key()
    listeners = Exmaster.Config.listeners!(Application.fetch_env!(:exmaster, :listen))

    children = [
      Exmaster.RateLimit,
      {Exmaster.Store, name: :exmaster_q3},
      {Exmaster.Store, name: :exmaster_q2},
      {Exmaster.Store, name: :exmaster_qw},
      %{
        id: Exmaster.Listeners,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             Enum.map(listeners, &{Exmaster.Listener, &1}),
             [strategy: :one_for_one, name: Exmaster.Listeners, max_restarts: 10, max_seconds: 10]
           ]}
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Exmaster.Supervisor)
  end
end
