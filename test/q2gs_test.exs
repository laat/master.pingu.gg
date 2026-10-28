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
    state = Q2GS.init(0)
    {[], q2} = Exmaster.Q2.Master.tick(ctx, 1_000, state.q2)

    # GameSpy's state is broken, so its tick raises.
    broken = %{state | gs: :broken}

    log =
      capture_log(fn ->
        assert {[], %{q2: ^q2, gs: :broken}} = Q2GS.tick(ctx, 1_000, broken)
      end)

    assert log =~ "GameSpy: tick failed"
  end
end
