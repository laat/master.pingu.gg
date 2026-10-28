defmodule Exmaster.QWTest do
  use ExUnit.Case

  alias Exmaster.{QW, RateLimit, Store}
  alias Exmaster.QW.Master
  import Exmaster.TestHelpers

  @server {{203, 0, 113, 5}, 27500}
  @status "\xFF\xFF\xFF\xFFstatus\n"
  @ttl 900_000
  @info %{
    "hostname" => "qw test",
    "map" => "dm4",
    "maxclients" => "16",
    "*version" => "MVDSV 0.36"
  }
  @clients [
    ~s(1 12 30 25 "player" "base" 4 4 "red"),
    ~s(2 -9999 3 -666 "\\s\\spec" "" 0 0 ""),
    ~s(3 0 1 30 "other" "" 0 0)
  ]

  setup do
    Store.clear(:exmaster_qw)
    RateLimit.clear()

    ctx = %{
      id: {{0, 0, 0, 0}, 27000},
      port: 27000,
      label: nil,
      store: :exmaster_qw,
      challenge_ttl: 5_000,
      server_ttl: @ttl
    }

    {:ok, ctx: ctx, state: Master.init(0)}
  end

  defp oob(s), do: "\xFF\xFF\xFF\xFF" <> s
  defp reply(info), do: oob("n" <> infostring(info) <> "\n" <> Enum.join(@clients, "\n") <> "\n")

  defp register(ctx, state, addr, info, now \\ 0) do
    {[{@status, ^addr}], state} = Master.handle_packet("a\n1\n2\n", addr, ctx, now, state)
    {[], state} = Master.handle_packet(reply(info), addr, ctx, now, state)
    state
  end

  describe "wire" do
    test "classify" do
      assert QW.classify("c\n") == :query
      assert QW.classify(oob("c\n")) == :query
      # qstat's.
      assert QW.classify("c\n\0") == :query
      assert QW.classify("cx") == :other
      assert QW.classify("a\n12\n3\n") == :heartbeat
      assert QW.classify(oob("a\n12\n3\n")) == :heartbeat
      assert QW.classify("C\n") == :shutdown
      assert QW.classify("C\n\0") == :shutdown
      assert QW.classify(oob("n\\a\\b")) == {:status, "\\a\\b"}
      assert QW.classify("n\\a\\b") == :other
      assert QW.classify("connect") == :other
    end

    test "parse_status leaves spectators out" do
      assert {%{"map" => "dm4"}, 2} =
               QW.parse_status(infostring(@info) <> "\n" <> Enum.join(@clients, "\n"))
    end

    test "game" do
      assert QW.game(%{"*gamedir" => "Fortress"}) == "QWTF"
      assert QW.game(%{"teamplay" => "21?TeamFortress"}) == "QWTF"
      assert QW.game(%{"*gamedir" => "qw", "teamplay" => "2"}) == "QuakeWorld"
    end
  end

  test "a server that answers status is listed", %{ctx: ctx, state: state} do
    state = register(ctx, state, @server, @info)

    assert %{game: "QuakeWorld", clients: 2, max_clients: 16, version: "MVDSV 0.36"} =
             Store.lookup(:exmaster_qw, @server, 0)

    {[{list, _}], _} = Master.handle_packet("c\n", {{10, 0, 0, 1}, 50_000}, ctx, 0, state)
    assert decode_ipv4_lists([list], "d\n") == [@server]
  end

  test "an unasked reply lists nothing", %{ctx: ctx, state: state} do
    {[], _} = Master.handle_packet(reply(@info), @server, ctx, 0, state)
    assert Store.all(:exmaster_qw, 0) == []
  end

  test "a shutdown has the server asked, and dropped if it doesn't answer", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state, @server, @info)
    {[{@status, @server}], state} = Master.handle_packet("C\n", @server, ctx, 61_000, state)
    {[], _} = Master.tick(ctx, 71_000, state)
    assert Store.lookup(:exmaster_qw, @server, 71_000) == nil
  end

  test "a server that restarts during a check is asked again when the check drops it", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state, @server, @info)
    {[{@status, @server}], state} = Master.handle_packet("C\n", @server, ctx, 60_000, state)
    {[], state} = Master.handle_packet("a\n1\n0\n", @server, ctx, 62_000, state)
    {[{@status, @server}], state} = Master.tick(ctx, 70_000, state)
    assert Store.lookup(:exmaster_qw, @server, 70_000) == nil
    {[], _} = Master.handle_packet(reply(@info), @server, ctx, 70_100, state)
    assert Store.lookup(:exmaster_qw, @server, 70_100)
  end

  test "a heartbeat within a minute of the last poll is put off", %{ctx: ctx, state: state} do
    state = register(ctx, state, @server, @info)

    {[{@status, @server}], state} =
      Master.handle_packet("a\n2\n2\n", @server, ctx, 61_000, state)

    {[], state} = Master.handle_packet("a\n3\n2\n", @server, ctx, 62_000, state)
    {[{@status, @server}], state} = Master.tick(ctx, 121_000, state)
    {[], _} = Master.handle_packet(reply(@info), @server, ctx, 121_500, state)
    assert Store.lookup(:exmaster_qw, @server, 121_500).seen == 121_500
  end
end
