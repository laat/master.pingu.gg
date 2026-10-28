defmodule Exmaster.GS.MasterTest do
  use ExUnit.Case

  alias Exmaster.{GS, RateLimit, Store}
  alias Exmaster.GS.Master

  @ip {203, 0, 113, 5}
  @server {@ip, 23_000}
  @ttl 900_000
  # From a Battlefield 1942 server's reply to \info\, cut short.
  @info "\\gameId\\bf1942\\hostname\\exmaster test\\hostport\\14567\\mapname\\berlin\\maxplayers\\16\\numplayers\\3\\version\\v1.612"

  setup do
    Store.clear(:exmaster_gs)
    RateLimit.clear()

    ctx = %{
      id: {{0, 0, 0, 0}, 27_900},
      port: 27_900,
      label: nil,
      store: :exmaster_gs,
      challenge_ttl: 5_000,
      server_ttl: @ttl
    }

    {:ok, ctx: ctx, state: Master.init(0)}
  end

  defp heartbeat(ctx, state, from, now, extra \\ "") do
    Master.handle_packet(
      "\\heartbeat\\23000\\gamename\\bfield1942" <> extra,
      from,
      ctx,
      now,
      state
    )
  end

  defp answer(ctx, state, from, challenge, now, key \\ "HpWx9z") do
    payload =
      @info <> "\\validate\\#{GS.validate(challenge, key)}\\weight\\10\\final\\\\queryid\\2.1"

    {[], state} = Master.handle_packet(payload, from, ctx, now, state)
    state
  end

  # Heartbeats from the query port and answers the challenge.
  defp register(ctx, state, now \\ 0) do
    {[{"\\info\\\\secure\\" <> challenge, @server}], state} = heartbeat(ctx, state, @server, now)
    answer(ctx, state, @server, challenge, now)
  end

  test "a server that answers its challenge is listed", %{ctx: ctx, state: state} do
    register(ctx, state)

    assert %{
             game: "bfield1942",
             hostname: "exmaster test",
             clients: 3,
             max_clients: 16,
             version: "v1.612"
           } = Store.lookup(:exmaster_gs, @server, 0)
  end

  test "the challenge goes to the query port the heartbeat names", %{ctx: ctx, state: state} do
    # Behind NAT, the heartbeat can come from another port.
    nat = {@ip, 40_000}
    {[{"\\info\\\\secure\\" <> challenge, @server}], state} = heartbeat(ctx, state, nat, 0)

    # A challenge is 16 characters, and only good at the address it went to.
    assert challenge =~ ~r/\A[A-Za-z0-9]{16}\z/
    state = answer(ctx, state, nat, challenge, 0)
    assert Store.lookup(:exmaster_gs, nat, 0) == nil
    answer(ctx, state, @server, challenge, 0)
    assert Store.lookup(:exmaster_gs, @server, 0)
  end

  test "wrong, late and other games' answers aren't listed", %{ctx: ctx, state: state} do
    {[{"\\info\\\\secure\\" <> challenge, _}], state} = heartbeat(ctx, state, @server, 0)
    state = answer(ctx, state, @server, challenge, 0, "kbeafe")
    state = answer(ctx, state, @server, "AAAAAAAAAAAAAAAA", 0)
    # A challenge lives one to two time buckets.
    state = answer(ctx, state, @server, challenge, 10_000)
    assert Store.lookup(:exmaster_gs, @server, 10_000) == nil
    answer(ctx, state, @server, challenge, 9_999)
    assert Store.lookup(:exmaster_gs, @server, 9_999)
  end

  test "ignores other packets", %{ctx: ctx, state: state} do
    # The All-Seeing Eye's heartbeat, which BF1942 sends to the same port.
    assert {[], _} = Master.handle_packet("\\hb\\14690\\bf1942", @server, ctx, 0, state)

    for hb <- [
          "\\heartbeat\\23000\\gamename\\bfvietnam",
          "\\heartbeat\\0\\gamename\\bfield1942",
          "\\heartbeat\\x\\gamename\\bfield1942",
          "\\heartbeat\\23000",
          "junk"
        ] do
      assert {[], _} = Master.handle_packet(hb, @server, ctx, 0, state)
    end
  end

  test "a listed server's heartbeats have it asked at most once a minute", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state)
    {[], state} = heartbeat(ctx, state, @server, 30_000)
    {[], state} = Master.tick(ctx, 59_000, state)
    {[{"\\info\\\\secure\\" <> challenge, @server}], state} = Master.tick(ctx, 60_000, state)
    state = answer(ctx, state, @server, challenge, 60_100)
    assert Store.lookup(:exmaster_gs, @server, @ttl + 60_000)
    assert {[{_, @server}], _} = heartbeat(ctx, state, @server, 130_000)
  end

  test "\\statechanged\\2 has the server asked, and dropped if it doesn't answer", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state)

    {[{"\\info\\\\secure\\" <> c, @server}], state} =
      heartbeat(ctx, state, @server, 61_000, "\\statechanged\\2")

    # Forged: the server answers, and stays.
    state = answer(ctx, state, @server, c, 61_200)
    {[], state} = Master.tick(ctx, 71_000, state)
    assert Store.lookup(:exmaster_gs, @server, 71_000)
    # Real: no answer.
    {[_], state} = heartbeat(ctx, state, @server, 130_000, "\\statechanged\\2")
    {[], _} = Master.tick(ctx, 140_000, state)
    assert Store.lookup(:exmaster_gs, @server, 140_000) == nil
  end

  # MOH:AA's heartbeat and its reply to \info\\secure\, from its query port.
  @moh {@ip, 12_300}
  @moh_heartbeat "\\heartbeat\\12300\\gamename\\mohaa\\statechanged\\"
  @moh_info "\\gamemode\\openplaying\\maxplayers\\14\\numplayers\\0\\gametype\\Round-Based-Match\\mapname\\dm/mohdm1\\hostport\\12203\\hostname\\exmaster-test"

  defp moh_answer(ctx, state, challenge, now, key) do
    payload = @moh_info <> "\\validate\\#{GS.validate(challenge, key)}\\final\\\\queryid\\3.1"
    {[], state} = Master.handle_packet(payload, @moh, ctx, now, state)
    state
  end

  test "Medal of Honor: Allied Assault, under its own key", %{ctx: ctx, state: state} do
    {[{"\\info\\\\secure\\" <> challenge, @moh}], state} =
      Master.handle_packet(@moh_heartbeat, @moh, ctx, 0, state)

    # Battlefield 1942's key doesn't answer a challenge for MOH:AA.
    state = moh_answer(ctx, state, challenge, 0, "HpWx9z")
    assert Store.lookup(:exmaster_gs, @moh, 0) == nil
    state = moh_answer(ctx, state, challenge, 0, "M5Fdwc")

    assert %{game: "mohaa", hostname: "exmaster-test", clients: 0, max_clients: 14} =
             Store.lookup(:exmaster_gs, @moh, 0)

    # Its heartbeat when it shuts down is the same as any other: the server
    # is asked again within the minute's allowance, not checked.
    {[], state} = Master.handle_packet(@moh_heartbeat, @moh, ctx, 30_000, state)
    {[{"\\info\\\\secure\\" <> _, @moh}], state} = Master.tick(ctx, 60_000, state)
    {[], _} = Master.tick(ctx, 70_000, state)
    assert Store.lookup(:exmaster_gs, @moh, 70_000)
  end
end
