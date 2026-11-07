defmodule Exmaster.TCPAcceptTest do
  @moduledoc """
  A TCP listener's acceptor survives a connection it can't hand off. While
  `Exmaster.RateLimit` restarts its table is gone, and an acceptor that
  raised on it took its listener and every connection the listener held
  with it.
  """
  use ExUnit.Case

  @localhost {127, 0, 0, 1}

  @listeners [
    {Exmaster.GS.ListServer, []},
    {Exmaster.SB.ListServer, []},
    {Exmaster.GP.Server, [password: "pingu"]},
    {Exmaster.UE2.Master, []},
    {Exmaster.VS.Master, []}
  ]

  setup do
    on_exit(fn -> Supervisor.restart_child(Exmaster.Supervisor, Exmaster.RateLimit) end)
  end

  for {mod, opts} <- @listeners do
    test "#{inspect(mod)} keeps listening while RateLimit is down" do
      pid = start_supervised!({unquote(mod), [ip: @localhost, port: 0] ++ unquote(opts)})
      ref = Process.monitor(pid)
      port = unquote(mod).port(pid)
      :ok = Supervisor.terminate_child(Exmaster.Supervisor, Exmaster.RateLimit)

      {:ok, s} = :gen_tcp.connect(@localhost, port, [:binary, active: false])
      assert {:error, :closed} = :gen_tcp.recv(s, 0, 1_000)
      refute_receive {:DOWN, ^ref, _, _, _}, 100

      {:ok, _} = Supervisor.restart_child(Exmaster.Supervisor, Exmaster.RateLimit)
      assert unquote(mod).port(pid) == port
    end
  end
end
