defmodule Exmaster.SharedTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Exmaster.{GS, Q2, QR2, RateLimit, Shared}

  setup do
    RateLimit.clear()

    ctx = %{
      id: {{127, 0, 0, 1}, 27_900},
      port: 27_900,
      label: nil,
      store: :exmaster_q2,
      masters: [Q2.Master, GS.Master],
      challenge_ttl: 5_000,
      server_ttl: 900_000
    }

    {:ok, ctx: ctx}
  end

  test "a tick that raises in one master keeps the other's", %{ctx: ctx} do
    Exmaster.Store.clear(:exmaster_q2)
    state = Shared.init(0)

    # A poll that is due, for a server no longer listed: Quake 2's tick
    # drops it. GameSpy's state is broken, so its tick raises.
    q2 = %{state[Q2.Master] | deferred: %{{{203, 0, 113, 1}, 27_910} => {500, :poll}}}
    broken = %{state | Q2.Master => q2, GS.Master => :broken}

    log =
      capture_log(fn ->
        assert {[], %{Q2.Master => %{deferred: deferred}, GS.Master => :broken}} =
                 Shared.tick(ctx, 1_000, broken)

        assert deferred == %{}
      end)

    assert log =~ "GameSpy: tick failed"
  end

  test "a packet for a master that isn't one of them is dropped", %{ctx: ctx} do
    state = Shared.init(0)
    heartbeat = <<3, 1, 2, 3, 4, "gamename", 0, "bfvietnam", 0, 0>>
    assert Shared.handle_packet(heartbeat, {{127, 0, 0, 1}, 23_000}, ctx, 0, state) == {[], state}

    ctx = %{ctx | masters: [QR2.Master]}

    assert {[{<<0xFE, 0xFD, 1, 1, 2, 3, 4, _::binary>>, _}], _} =
             Shared.handle_packet(heartbeat, {{127, 0, 0, 1}, 23_000}, ctx, 0, state)
  end
end
