defmodule Exmaster.Q2Test do
  use ExUnit.Case

  alias Exmaster.{Q2, RateLimit, Store}
  alias Exmaster.Q2.Master
  import Exmaster.TestHelpers

  @server {{203, 0, 113, 5}, 27910}
  @status "\xFF\xFF\xFF\xFFstatus\n"
  @ttl 900_000
  @info %{"hostname" => "q2 test", "mapname" => "q2dm1", "maxclients" => "8", "protocol" => "34"}

  setup do
    Store.clear(:exmaster_q2)
    RateLimit.clear()

    ctx = %{
      id: {{0, 0, 0, 0}, 27900},
      port: 27900,
      label: nil,
      store: :exmaster_q2,
      challenge_ttl: 5_000,
      server_ttl: @ttl
    }

    {:ok, ctx: ctx, state: Master.init(0)}
  end

  defp oob(s), do: "\xFF\xFF\xFF\xFF" <> s

  defp print(info, players \\ []),
    do: oob("print\n" <> infostring(info) <> "\n" <> Enum.join(players, "\n"))

  defp register(ctx, state, addr, info, now \\ 0) do
    {[{@status, ^addr}], state} =
      Master.handle_packet(oob("heartbeat\n" <> infostring(info) <> "\n"), addr, ctx, now, state)

    {[], state} = Master.handle_packet(print(info, [~s(0 50 "player")]), addr, ctx, now, state)
    state
  end

  defp list(ctx, state, now \\ 0) do
    n = System.unique_integer([:positive])
    from = {{10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}, 50_000}
    {sends, _} = Master.handle_packet("query\n", from, ctx, now, state)
    decode_ipv4_lists(Enum.map(sends, &elem(&1, 0)), "servers ")
  end

  describe "wire" do
    test "split" do
      assert Q2.split("query\n") == {:plain, "query", ""}
      assert Q2.split(oob("heartbeat\n\\a\\b\n")) == {:oob, "heartbeat", "\\a\\b\n"}
      assert Q2.split(oob("shutdown")) == {:oob, "shutdown", ""}
    end

    test "parse_status" do
      assert Q2.parse_status(~s(\\hostname\\x\\maxclients\\8\n0 50 "a"\n3 20 "b"\n)) ==
               {%{"hostname" => "x", "maxclients" => "8"}, 2}

      assert Q2.parse_status("Server is full.\n") == {%{}, 0}
    end

    test "encode_list" do
      addrs = for i <- 1..400, do: {{10, 0, div(i, 256), rem(i, 256)}, 27910}
      packets = Q2.encode_list(addrs)
      assert length(packets) == 2
      assert Enum.all?(packets, &(byte_size(&1) <= 1400))
      assert decode_ipv4_lists(packets, "servers ") == addrs
      assert Q2.encode_list([]) == [oob("servers ")]
    end

    test "game" do
      assert Q2.game(%{"game" => "action"}) == "ActionQuake2"
      assert Q2.game(%{"actionversion" => "2.81"}) == "ActionQuake2"
      assert Q2.game(%{"gamename" => "baseq2"}) == "Quake2"
    end
  end

  test "a server that answers status is listed", %{ctx: ctx, state: state} do
    state = register(ctx, state, @server, @info)

    assert %{game: "Quake2", clients: 1, max_clients: 8, protocol: 34} =
             Store.lookup(:exmaster_q2, @server, 0)

    assert list(ctx, state) == [@server]
    # Also asked with the out-of-band prefix.
    {sends, _} = Master.handle_packet(oob("query\n"), {{10, 9, 9, 9}, 1}, ctx, 0, state)
    assert decode_ipv4_lists(Enum.map(sends, &elem(&1, 0)), "servers ") == [@server]
  end

  test "a heartbeat alone, a print nobody asked for, or a late one, list nothing", %{
    ctx: ctx,
    state: state
  } do
    {[{@status, @server}], state} =
      Master.handle_packet(oob("heartbeat\n"), @server, ctx, 0, state)

    assert Store.all(:exmaster_q2, 0) == []
    other = {{203, 0, 113, 6}, 27910}
    {[], state} = Master.handle_packet(print(@info), other, ctx, 0, state)
    {[], state} = Master.handle_packet(print(@info), @server, ctx, 10_001, state)
    assert Store.all(:exmaster_q2, 10_001) == []
    # Nor a print that isn't a status.
    {[_], state} = Master.handle_packet(oob("heartbeat\n"), @server, ctx, 20_000, state)
    {[], _} = Master.handle_packet(oob("print\nServer is full.\n"), @server, ctx, 20_000, state)
    assert Store.all(:exmaster_q2, 20_000) == []
  end

  test "one status, one reply", %{ctx: ctx, state: state} do
    {[_], state} = Master.handle_packet(oob("heartbeat\n"), @server, ctx, 0, state)
    {[], state} = Master.handle_packet(print(@info), @server, ctx, 0, state)

    {[], _} =
      Master.handle_packet(print(%{@info | "hostname" => "forged"}), @server, ctx, 0, state)

    assert Store.lookup(:exmaster_q2, @server, 0).hostname == "q2 test"
  end

  test "heartbeats keep a server listed; without them it expires", %{ctx: ctx, state: state} do
    state = register(ctx, state, @server, @info)
    state = register(ctx, state, @server, @info, 600_000)
    assert list(ctx, state, @ttl + 1) == [@server]
    assert list(ctx, state, 600_000 + @ttl) == []
  end

  test "a shutdown has the server asked, and dropped if it doesn't answer", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state, @server, @info)

    # The query it answered to register starts its minute.
    {[], state} = Master.handle_packet(oob("shutdown"), @server, ctx, 1_000, state)
    {[{@status, @server}], state} = Master.tick(ctx, 60_000, state)
    {[], state} = Master.handle_packet(print(@info), @server, ctx, 60_100, state)
    {[], state} = Master.tick(ctx, 70_000, state)
    assert Store.lookup(:exmaster_q2, @server, 70_000)
    {[_], state} = Master.handle_packet(oob("shutdown"), @server, ctx, 130_000, state)
    {[], _} = Master.tick(ctx, 140_000, state)
    assert Store.lookup(:exmaster_q2, @server, 140_000) == nil
  end

  test "a server that restarts during a check is asked again when the check drops it", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state, @server, @info)

    {[{@status, @server}], state} =
      Master.handle_packet(oob("shutdown"), @server, ctx, 60_000, state)

    # The new instance's startup ping, put off.
    {[], state} = Master.handle_packet(oob("ping"), @server, ctx, 63_000, state)
    {[{@status, @server}], state} = Master.tick(ctx, 70_000, state)
    assert Store.lookup(:exmaster_q2, @server, 70_000) == nil
    {[], _} = Master.handle_packet(print(@info), @server, ctx, 70_100, state)
    assert Store.lookup(:exmaster_q2, @server, 70_100)
  end

  test "flood protection", %{ctx: ctx, state: state} do
    client = {{198, 51, 100, 7}, 50_000}
    for _ <- 1..5, do: assert({[_], _} = Master.handle_packet("query\n", client, ctx, 0, state))
    assert {[], _} = Master.handle_packet("query\n", client, ctx, 0, state)

    sent =
      for p <- 1..70,
          do:
            Master.handle_packet(oob("heartbeat\n"), {{192, 0, 2, 1}, p}, ctx, 0, state)
            |> elem(0)
            |> length()

    assert Enum.sum(sent) == 64
  end
end
