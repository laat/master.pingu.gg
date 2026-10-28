defmodule Exmaster.Q2GSTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias Exmaster.{Q2GS, RateLimit}

  setup do
    RateLimit.clear()

    ctx = %{
      id: {{127, 0, 0, 1}, 27_900},
      port: 27_900,
      label: nil,
      store: :exmaster_q2,
      challenge_ttl: 5_000,
      server_ttl: 900_000
    }

    {:ok, ctx: ctx}
  end

  test "a tick that raises in one master keeps the other's", %{ctx: ctx} do
    Exmaster.Store.clear(:exmaster_q2)
    state = Q2GS.init(0)

    # A poll that is due, for a server no longer listed: Quake 2's tick
    # drops it. GameSpy's state is broken, so its tick raises.
    q2 = %{state.q2 | deferred: %{{{203, 0, 113, 1}, 27_910} => {500, :poll}}}
    broken = %{state | q2: q2, gs: :broken}

    log =
      capture_log(fn ->
        assert {[], %{q2: %{deferred: deferred}, gs: :broken}} = Q2GS.tick(ctx, 1_000, broken)
        assert deferred == %{}
      end)

    assert log =~ "GameSpy: tick failed"
  end
end
