defmodule Exmaster.Application do
  @moduledoc """
  The supervision tree:

      Exmaster.Supervisor
      ├── Exmaster.RateLimit        token buckets, in ETS
      ├── Exmaster.PG               the pg scope the stores share their lists in
      ├── Exmaster.Store            :exmaster_q3, :exmaster_q2, :exmaster_qw,
      │                             :exmaster_gs, :exmaster_qr2, :exmaster_ue2,
      │                             and one per label, :exmaster_q3_<label>
      ├── Exmaster.Cluster          connects to the other nodes, if there are any
      └── Exmaster.Listeners        an Exmaster.Listener per UDP socket, and the
                                    TCP ones, Exmaster.GS.ListServer,
                                    Exmaster.SB.ListServer and
                                    Exmaster.UE2.Master

  The stores own the server lists, so a listener that restarts loses
  nothing; a store that restarts starts empty, and servers come back with
  their next heartbeat, or with the next node's list.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Exmaster.Q3.Challenge.init_key()
    Exmaster.GS.Master.init_key()
    Exmaster.QR2.Master.init_key()
    listeners = Exmaster.Config.listeners!(Application.fetch_env!(:exmaster, :listen))
    peers = Application.fetch_env!(:exmaster, :peers)

    listeners_sup = %{
      id: Exmaster.Listeners,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           Enum.map(listeners, &listener/1),
           [strategy: :one_for_one, name: Exmaster.Listeners, max_restarts: 10, max_seconds: 10]
         ]}
    }

    # One per master: Quake 3, Quake 2, QuakeWorld, GameSpy, QR2, UT2004,
    # and each label's.
    stores =
      for {name, store} <- Exmaster.Config.stores(listeners),
          do: {Exmaster.Store, name: store, label: to_string(name)}

    children =
      [
        Exmaster.RateLimit,
        %{id: Exmaster.PG, start: {:pg, :start_link, [Exmaster.Store.scope()]}}
      ] ++
        stores ++
        if(peers == [], do: [], else: [{Exmaster.Cluster, peers}]) ++
        [listeners_sup]

    Supervisor.start_link(children, strategy: :one_for_one, name: Exmaster.Supervisor)
  end

  # GameSpy lists and UT2004 go over TCP; everything else is a UDP master.
  defp listener(opts) do
    if opts[:protocol] in [Exmaster.GS.ListServer, Exmaster.SB.ListServer, Exmaster.UE2.Master],
      do: {opts[:protocol], opts},
      else: {Exmaster.Listener, opts}
  end
end
