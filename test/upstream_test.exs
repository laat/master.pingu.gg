defmodule Exmaster.UpstreamTest do
  use ExUnit.Case

  alias Exmaster.{Addr, Config, Listener, Q2, Q3, QW, RateLimit, Store, Upstream}
  import Exmaster.TestHelpers

  @master {{198, 51, 100, 1}, 27950}
  @other {{198, 51, 100, 2}, 27950}
  @ttl 900_000
  @info %{"protocol" => "68", "sv_maxclients" => "16", "clients" => "3", "hostname" => "test"}

  setup do
    for s <- [:exmaster_q3, :exmaster_q2, :exmaster_qw], do: Store.clear(s)
    RateLimit.clear()
    :ok
  end

  defp ctx(store),
    do: %{
      id: {{0, 0, 0, 0}, 27950},
      port: 27950,
      label: nil,
      store: store,
      masters: [],
      challenge_ttl: 5_000,
      server_ttl: @ttl
    }

  defp server(n), do: {{203, 0, 113, n}, 27960}

  defp q3_list(addrs, ext \\ false) do
    [packet] = Q3.encode_list(addrs, ext)
    packet
  end

  describe "Upstream" do
    test "queries go out 2 seconds apart, and 5 apart to one master" do
      u = Upstream.pull(Upstream.new(), [{@master, :a}, {@master, :b}, {@other, :c}])
      assert {[{@master, :a}], u} = Upstream.due(u, 0)
      assert {[], u} = Upstream.due(u, 1_999)
      # The next is to the same master: it waits for its 5 seconds.
      assert {[], u} = Upstream.due(u, 2_000)
      assert {[{@master, :b}], u} = Upstream.due(u, 5_000)
      assert {[{@other, :c}], u} = Upstream.due(u, 7_000)
      assert {[], _} = Upstream.due(u, 100_000)
    end

    test "monotonic times may be negative" do
      u = Upstream.pull(Upstream.new(), [{@master, :a}, {@master, :b}])
      assert {[{@master, :a}], u} = Upstream.due(u, -1_000_000)
      assert {[], u} = Upstream.due(u, -996_000)
      assert {[{@master, :b}], _} = Upstream.due(u, -995_000)
    end

    test "a new round drops what is left of the last" do
      u = Upstream.pull(Upstream.new(), [{@master, :a}, {@other, :b}])
      {_, u} = Upstream.due(u, 0)
      u = Upstream.pull(u, [{@other, :c}])
      assert {[{@other, :c}], _} = Upstream.due(u, 2_000)
    end

    test "a reply is taken for 10 seconds after its master was asked, as the last query's" do
      u = Upstream.pull(Upstream.new(), [{@master, :a}, {@master, :b}])
      assert Upstream.asked(u, @master, 0) == nil
      {_, u} = Upstream.due(u, 0)
      assert Upstream.asked(u, @master, 10_000) == :a
      assert Upstream.asked(u, @master, 10_001) == nil
      assert Upstream.asked(u, @other, 0) == nil
      {_, u} = Upstream.due(u, 5_000)
      assert Upstream.asked(u, @master, 6_000) == :b
    end

    test "servers are queued once, public ones only, and handed out 50 a tick" do
      lan = [{{10, 0, 0, 1}, 27960}, {{127, 0, 0, 1}, 27960}, {{192, 168, 1, 2}, 27960}]
      addrs = for n <- 1..60, do: server(n)
      u = Upstream.listed(Upstream.new(), lan ++ addrs, :a)
      u = Upstream.listed(u, [server(1), server(61)], :b)

      {first, u} = Upstream.probes(u)
      assert length(first) == 50
      assert hd(first) == {server(1), :a}
      {rest, u} = Upstream.probes(u)
      assert rest == for(n <- 51..60, do: {server(n), :a}) ++ [{server(61), :b}]
      assert {[], u} = Upstream.probes(u)
      # Handed out, it can be queued again.
      assert {[{_, :c}], _} = u |> Upstream.listed([server(1)], :c) |> Upstream.probes()
    end
  end

  test "public addresses" do
    for ip <- [
          {0, 0, 0, 0},
          {10, 1, 2, 3},
          {100, 64, 0, 1},
          {127, 0, 0, 1},
          {169, 254, 1, 1},
          {172, 16, 0, 1},
          {172, 31, 255, 255},
          {192, 168, 0, 1},
          {224, 0, 0, 1},
          {255, 255, 255, 255},
          {0, 0, 0, 0, 0, 0, 0, 0},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFD00, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          {0xFF02, 0, 0, 0, 0, 0, 0, 1}
        ],
        do: refute(Addr.public?({ip, 27960}), inspect(ip))

    for ip <- [{1, 1, 1, 1}, {100, 128, 0, 1}, {172, 32, 0, 1}, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}],
        do: assert(Addr.public?({ip, 27960}), inspect(ip))

    refute Addr.public?({{1, 1, 1, 1}, 0})
  end

  describe "Q3.decode_list" do
    test "reads what encode_list writes, IPv6 too" do
      v6 = {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 5}, 26000}
      addrs = [server(1), server(2), v6]
      assert Q3.decode_list(payload(q3_list(addrs, true))) == addrs
      assert Q3.decode_list(payload(q3_list(addrs))) == [server(1), server(2)]
    end

    test "skips port 0, takes IPv4-mapped entries as IPv4, and stops at junk" do
      mapped = <<?/, 0::80, 0xFFFF::16, 203, 0, 113, 9, 27960::16>>
      bin = "\\" <> <<203, 0, 113, 1, 0::16>> <> mapped <> "\\" <> <<203, 0, 113, 2, 27960::16>>
      assert Q3.decode_list(bin <> "junk\\" <> <<1, 2, 3, 4, 5::16>>) == [server(9), server(2)]
    end

    test "Call of Duty's NULs and bare EOT, Daemon's numbering and tags" do
      cod = <<0, ?\\, 203, 0, 113, 1, 27960::16>> <> "\\EOT"
      assert Q3.decode_list(cod) == [server(1)]

      daemon =
        "1\x003\x00[featured]\\" <>
          <<203, 0, 113, 1, 27960::16>> <> "[official]\\" <> <<203, 0, 113, 2, 27960::16>>

      assert Q3.decode_list(daemon) == [server(1), server(2)]
      assert Q3.decode_list("1") == []
    end
  end

  defp payload("\xFF\xFF\xFF\xFFgetserversExtResponse" <> rest), do: rest
  defp payload("\xFF\xFF\xFF\xFFgetserversResponse" <> rest), do: rest

  describe "Quake 3" do
    alias Exmaster.Q3.Master

    test "a query's class: its game, or its protocol's, or Quake 3's" do
      class = fn line ->
        {:ok, u} = Master.upstream(String.split(line))
        u.class
      end

      assert class.("getservers 68 empty full") == {:known, "Quake3Arena"}
      assert class.("getservers 84") == {:known, "et"}
      assert class.("getservers 60") == {:known, "wolfmp"}
      # JK2: its servers heartbeat Quake 3's tag.
      assert class.("getservers 16") == {:known, "Quake3Arena"}
      assert class.("getservers Tremulous 70") == {:known, "Tremulous"}
      assert class.("getserversExt Xonotic 3 empty full") == :darkplaces

      assert {:ok, %{port: 27950, packet: "\xFF\xFF\xFF\xFFgetserversExt Xonotic 3 empty full"}} =
               Master.upstream(String.split("getserversExt Xonotic 3 empty full"))

      assert {:error, _} = Master.upstream([])
      assert {:error, _} = Master.upstream(["getinfo", "68"])
      assert {:error, _} = Master.upstream(["getservers"])
    end

    defp pulled(line, ctx) do
      {:ok, u} = Master.upstream(String.split(line))
      state = Master.init(0)
      {[], state} = Master.pull([{@master, u}], ctx, 0, state)
      {sends, state} = Master.tick(ctx, 0, state)
      assert sends == [{u.packet, @master}]
      {state, u}
    end

    defp list_from(state, from, addrs, ctx, now) do
      {[], state} = Master.handle_packet(q3_list(addrs), from, ctx, now, state)
      state
    end

    defp answer(ctx, state, addr, challenge, info, now) do
      payload = "\n" <> infostring(Map.put(info, "challenge", challenge))
      Master.handle_packet("\xFF\xFF\xFF\xFFinfoResponse" <> payload, addr, ctx, now, state)
    end

    test "servers on an upstream's list are asked, and listed once they answer" do
      ctx = ctx(:exmaster_q3)
      {state, _} = pulled("getservers 84 empty full", ctx)
      state = list_from(state, @master, [server(1), server(2)], ctx, 1_000)
      assert Store.all(:exmaster_q3, 1_000) == []

      {sends, state} = Master.tick(ctx, 1_000, state)

      assert [{"\xFF\xFF\xFF\xFFgetinfo " <> c1, a1}, {"\xFF\xFF\xFF\xFFgetinfo " <> _, a2}] =
               sends

      assert {a1, a2} == {server(1), server(2)}

      # ET servers send their game name; one that didn't would still be et,
      # as the query implies.
      {[], state} = answer(ctx, state, server(1), c1, %{@info | "protocol" => "84"}, 1_000)
      assert %{game: "et", protocol: 84} = Store.lookup(:exmaster_q3, server(1), 1_000)

      # Server 2 doesn't answer, and isn't listed.
      {[], _} = Master.tick(ctx, 2_000, state)
      assert Store.lookup(:exmaster_q3, server(2), 2_000) == nil
    end

    test "a list from an address that wasn't asked, or too late, is ignored" do
      ctx = ctx(:exmaster_q3)
      {state, _} = pulled("getservers 68", ctx)
      state = list_from(state, @other, [server(1)], ctx, 1_000)
      state = list_from(state, @master, [server(2)], ctx, 10_001)
      assert {[], _} = Master.tick(ctx, 10_001, state)
    end

    test "a listed server on a list is asked again at most once a minute" do
      ctx = ctx(:exmaster_q3)
      {state, u} = pulled("getservers 68", ctx)
      state = list_from(state, @master, [server(1)], ctx, 0)
      {[{"\xFF\xFF\xFF\xFFgetinfo " <> c, _}], state} = Master.tick(ctx, 0, state)
      {[], state} = answer(ctx, state, server(1), c, @info, 0)

      # The next round, inside the minute: asked when it is over.
      {[], state} = Master.pull([{@master, u}], ctx, 10_000, state)
      {[_query], state} = Master.tick(ctx, 10_000, state)
      state = list_from(state, @master, [server(1)], ctx, 10_000)
      assert {[], state} = Master.tick(ctx, 10_000, state)
      assert {[{"\xFF\xFF\xFF\xFFgetinfo " <> _, _}], _} = Master.tick(ctx, 60_000, state)
    end
  end

  describe "Quake 2 and QuakeWorld" do
    test "Quake 2: servers on a list get status, and are listed by their reply" do
      alias Exmaster.Q2.Master
      ctx = ctx(:exmaster_q2)
      {:ok, u} = Master.upstream([])
      assert u == %{port: 27900, packet: "query\n"}
      assert {:error, _} = Master.upstream(["query"])

      {[], state} = Master.pull([{@master, u}], ctx, 0, Master.init(0))
      {[{"query\n", @master}], state} = Master.tick(ctx, 0, state)

      [list] = Q2.encode_list([server(1), {{127, 0, 0, 1}, 27910}])
      {[], state} = Master.handle_packet(list, @master, ctx, 0, state)
      {[{"\xFF\xFF\xFF\xFFstatus\n", addr}], state} = Master.tick(ctx, 0, state)
      assert addr == server(1)

      status = "\xFF\xFF\xFF\xFFprint\n\\maxclients\\8\\hostname\\q2\n0 0 \"p\"\n"
      {[], _} = Master.handle_packet(status, server(1), ctx, 0, state)
      assert %{game: "Quake2", clients: 1} = Store.lookup(:exmaster_q2, server(1), 0)
    end

    test "QuakeWorld: servers on a list get status, and are listed by their reply" do
      alias Exmaster.QW.Master
      ctx = ctx(:exmaster_qw)
      {:ok, u} = Master.upstream([])
      assert u == %{port: 27000, packet: "c\n"}

      {[], state} = Master.pull([{@master, u}], ctx, 0, Master.init(0))
      {[{"c\n", @master}], state} = Master.tick(ctx, 0, state)

      [list] = QW.encode_list([server(1)])
      # From anyone else it is nothing.
      {[], state} = Master.handle_packet(list, @other, ctx, 0, state)
      {[], state} = Master.tick(ctx, 0, state)
      {[], state} = Master.handle_packet(list, @master, ctx, 0, state)
      {[{"\xFF\xFF\xFF\xFFstatus\n", addr}], state} = Master.tick(ctx, 0, state)
      assert addr == server(1)

      status = "\xFF\xFF\xFF\xFFn\\maxclients\\8\\hostname\\qw\n"
      {[], _} = Master.handle_packet(status, server(1), ctx, 0, state)
      assert %{game: "QuakeWorld"} = Store.lookup(:exmaster_qw, server(1), 0)
    end
  end

  describe "Config.upstreams!" do
    @file_text """
    # Upstream masters.
    q3              dpmaster.deathmask.net        getservers Xonotic 3 empty full
    q3=UrbanTerror  master.urbanterror.info:27900 getservers 68 empty full  # UrT
    q3=CoD4         cod4master.activision.com:20810 getservers 6

    q2              master.quakeservers.net
    qw              192.0.2.1:27001
    """

    test "each listener gets its master's lines; lines nobody takes are left" do
      listeners = Config.listeners!("q3:27950,q3:27951,q3:27960=UrbanTerror,q2:27900,gs:27900")
      {listeners, left} = Config.upstreams!(@file_text, listeners)

      assert [q3, q3b, urt, shared] = listeners
      assert [%{host: "dpmaster.deathmask.net", port: 27950, class: :darkplaces}] = q3[:upstreams]
      assert q3b[:upstreams] == []

      assert [%{host: "master.urbanterror.info", port: 27900, label: "UrbanTerror"}] =
               urt[:upstreams]

      # Quake 2 is on a socket shared with GameSpy.
      assert shared[:protocol] == Exmaster.Shared
      assert [%{master: Exmaster.Q2.Master, port: 27900}] = shared[:upstreams]

      assert [%{label: "CoD4"} = cod4, %{host: "192.0.2.1", port: 27001} = qw] = left
      assert Config.master_name(cod4) == "q3=CoD4"
      assert Config.master_name(qw) == "qw"
    end

    test "bad lines" do
      for {line, message} <- [
            {"q3 host", "getservers"},
            {"q3 host getservers", "getservers"},
            {"q2 host query", "no query"},
            {"q2=Label host", "labels are for q3"},
            {"q3=bad\\label host getservers 68", "invalid label"},
            {"gs host", "want q3"},
            {"q3", "want q3"},
            {"q3 [::1]:27950 getservers 68", "host[:port]"},
            {"q3 host:0 getservers 68", "bad port"}
          ] do
        error = assert_raise ArgumentError, fn -> Config.upstreams!("\n" <> line, []) end
        assert error.message =~ "upstreams line 2: "
        assert error.message =~ message, line
      end
    end
  end

  describe "Listener" do
    @localhost {127, 0, 0, 1}

    test "a round asks each upstream through the listener's socket" do
      {:ok, master} = :gen_udp.open(0, [:binary, active: false, ip: @localhost])
      {:ok, port} = :inet.port(master)

      {listeners, []} =
        Config.upstreams!("q2 127.0.0.1:#{port}\n", Config.listeners!("q2:127.0.0.1:0"))

      pid = start_supervised!({Listener, hd(listeners)}, id: make_ref())
      listener_port = Listener.port(pid)
      send(pid, :pull)

      assert {:ok, {@localhost, ^listener_port, "query\n"}} = :gen_udp.recv(master, 0, 3_000)
    end
  end
end
