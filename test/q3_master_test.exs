defmodule Exmaster.Q3.MasterTest do
  use ExUnit.Case

  alias Exmaster.{Q3, RateLimit, Store}
  alias Exmaster.Q3.Master
  import Exmaster.TestHelpers

  @server {{203, 0, 113, 5}, 27960}
  @client {{198, 51, 100, 7}, 50_000}
  @ttl 900_000
  @info %{"protocol" => "68", "sv_maxclients" => "16", "clients" => "3", "hostname" => "test"}

  setup do
    Store.clear(:exmaster_q3)
    RateLimit.clear()

    ctx = %{
      id: {{0, 0, 0, 0}, 27950},
      port: 27950,
      label: nil,
      store: :exmaster_q3,
      challenge_ttl: 5_000,
      server_ttl: @ttl
    }

    {:ok, ctx: ctx, state: Master.init(0)}
  end

  defp packet(cmd, payload), do: "\xFF\xFF\xFF\xFF" <> cmd <> payload

  defp heartbeat(ctx, state, addr, tag, now) do
    Master.handle_packet(Q3.packet("heartbeat", [tag]), addr, ctx, now, state)
  end

  # Heartbeats and answers the getinfo with info; returns the state.
  defp register(ctx, state, addr, tag, info, now \\ 0) do
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> challenge, ^addr}], state} =
      heartbeat(ctx, state, addr, tag, now)

    answer(ctx, state, addr, challenge, info, now)
  end

  defp answer(ctx, state, addr, challenge, info, now) do
    payload = "\n" <> infostring(Map.put(info, "challenge", challenge))
    {[], state} = Master.handle_packet(packet("infoResponse", payload), addr, ctx, now, state)
    state
  end

  # Each from another client, so the flood protection stays out of it.
  defp list(ctx, state, cmd, query, now \\ 0, from \\ nil) do
    n = System.unique_integer([:positive])
    from = from || {{10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}, 50_000}
    {sends, _} = Master.handle_packet(Q3.packet(cmd, [query]), from, ctx, now, state)
    assert Enum.all?(sends, fn {_, to} -> to == from end)
    decode_q3_lists(Enum.map(sends, &elem(&1, 0)))
  end

  test "a server that answers its challenge is listed", %{ctx: ctx, state: state} do
    state = register(ctx, state, @server, "QuakeArena-1", @info)

    assert %{game: "Quake3Arena", protocol: 68, clients: 3, hostname: "test"} =
             Store.lookup(:exmaster_q3, @server, 0)

    assert list(ctx, state, "getservers", "68") == [@server]
    assert list(ctx, state, "getservers", "Quake3Arena 68") == [@server]
    assert list(ctx, state, "getserversExt", "Quake3Arena 68") == [@server]
    assert list(ctx, state, "getservers", "67") == []
    assert list(ctx, state, "getservers", "68 ffa") == [@server]
    assert list(ctx, state, "getservers", "68 ctf") == []
  end

  test "a heartbeat alone stores nothing", %{ctx: ctx, state: state} do
    {[_], _} = heartbeat(ctx, state, @server, "QuakeArena-1", 0)
    assert Store.all(:exmaster_q3, 0) == []
  end

  test "a wrong, stolen or late challenge doesn't list the server", %{ctx: ctx, state: state} do
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> challenge, _}], state} =
      heartbeat(ctx, state, @server, "QuakeArena-1", 0)

    answer(ctx, state, @server, "abcdefghijk", @info, 0)
    answer(ctx, state, {{203, 0, 113, 6}, 27960}, challenge, @info, 0)
    answer(ctx, state, @server, challenge, @info, 0) |> then(fn _ -> :ok end)
    assert Store.lookup(:exmaster_q3, {{203, 0, 113, 6}, 27960}, 0) == nil
    Store.clear(:exmaster_q3)
    answer(ctx, state, @server, challenge, @info, 10_000)
    assert Store.all(:exmaster_q3, 10_000) == []
    # From another listener.
    answer(%{ctx | id: {{0, 0, 0, 0}, 27900}}, state, @server, challenge, @info, 0)
    assert Store.all(:exmaster_q3, 0) == []
  end

  test "empty and full servers are left out unless asked for", %{ctx: ctx, state: state} do
    state = register(ctx, state, @server, "QuakeArena-1", %{@info | "clients" => "0"})
    full = {{203, 0, 113, 9}, 27960}
    state = register(ctx, state, full, "QuakeArena-1", %{@info | "clients" => "16"})
    assert list(ctx, state, "getservers", "68") == []
    assert list(ctx, state, "getservers", "68 empty") == [@server]
    assert list(ctx, state, "getservers", "68 empty full") == [@server, full]
  end

  test "ET clients always get empty and full servers", %{ctx: ctx, state: state} do
    info = %{@info | "protocol" => "84", "clients" => "0"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info)
    assert list(ctx, state, "getservers", "84") == [@server]
  end

  test "game names", %{ctx: ctx, state: state} do
    # Urban Terror heartbeats as Quake 3 and says nothing more, so on this
    # port it is Quake 3; its own is a labelled listener.
    urt = {{203, 0, 113, 10}, 27960}
    state = register(ctx, state, urt, "QuakeArena-1", Map.put(@info, "game", "q3ut4"))
    assert Store.lookup(:exmaster_q3, urt, 0).game == "Quake3Arena"

    # Smokin' Guns has a tag of its own.
    sg = {{203, 0, 113, 15}, 27960}
    state = register(ctx, state, sg, "smokinguns", Map.put(@info, "game", "smokinguns"))
    assert %{game: "smokinguns", unknown: false} = Store.lookup(:exmaster_q3, sg, 0)
    # As the ones that name it; and its IPv6 clients find them here too.
    sg2 = {{203, 0, 113, 16}, 27960}
    info = @info |> Map.put("game", "smokinguns") |> Map.put("gamename", "smokinguns")
    state = register(ctx, state, sg2, "smokinguns", info)
    assert list(ctx, state, "getserversExt", "smokinguns 68") == [sg, sg2]
    assert list(ctx, state, "getservers", "68") == [urt]

    # DarkPlaces names its game.
    xon = {{203, 0, 113, 11}, 26000}

    state =
      register(
        ctx,
        state,
        xon,
        "DarkPlaces",
        %{@info | "protocol" => "3"} |> Map.put("gamename", "Xonotic")
      )

    assert list(ctx, state, "getservers", "Xonotic 3") == [xon]

    # DarkPlaces without a name, and an unknown tag claiming a built-in game, are rejected.
    nameless = {{203, 0, 113, 12}, 26000}
    register(ctx, state, nameless, "DarkPlaces", @info)
    liar = {{203, 0, 113, 13}, 27960}
    register(ctx, state, liar, "Junk-1", Map.put(@info, "gamename", "Quake3Arena"))
    assert Store.lookup(:exmaster_q3, nameless, 0) == nil
    assert Store.lookup(:exmaster_q3, liar, 0) == nil

    # An unknown tag with a name of its own is fine, and counts as unknown.
    other = {{203, 0, 113, 14}, 27960}
    register(ctx, state, other, "Junk-1", Map.put(@info, "gamename", "Junk"))
    assert %{game: "Junk", unknown: true} = Store.lookup(:exmaster_q3, other, 0)
  end

  test "a labelled listener is a master of its own", %{ctx: plain, state: state} do
    start_supervised!({Store, name: :exmaster_q3_test_SmokinGuns})

    ctx = %{
      plain
      | label: "SmokinGuns",
        store: :exmaster_q3_test_SmokinGuns,
        id: {{0, 0, 0, 0}, 27961},
        port: 27961
    }

    state = register(ctx, state, @server, "smokinguns", @info)
    q3 = {{203, 0, 113, 9}, 27960}
    state = register(plain, state, q3, "QuakeArena-1", @info)

    assert Store.lookup(ctx.store, @server, 0).game == "SmokinGuns"
    assert Store.lookup(:exmaster_q3, @server, 0) == nil
    # Its clients ask anonymously over IPv4 and as smokinguns over IPv6; any
    # name gets the label's servers, and only those.
    assert list(ctx, state, "getservers", "68") == [@server]
    assert list(ctx, state, "getserversExt", "smokinguns 68") == [@server]
    assert list(ctx, state, "getservers", "Quake3Arena 68") == [@server]
    assert list(plain, state, "getservers", "68") == [q3]
  end

  test "a listener labelled with a built-in game keeps its rules", %{ctx: plain, state: state} do
    start_supervised!({Store, name: :exmaster_q3_test_et})
    ctx = %{plain | label: "et", store: :exmaster_q3_test_et, id: {{0, 0, 0, 0}, 27955}}
    info = %{@info | "protocol" => "84", "clients" => "0"}
    state = register(ctx, state, @server, "EnemyTerritory-1", info)
    # ET clients never ask for empty servers, and get them.
    assert list(ctx, state, "getservers", "84") == [@server]
  end

  test "Smokin' Guns' flatline is a flatline", %{ctx: ctx, state: state} do
    # No gamename: the tag alone names the game.
    state = register(ctx, state, @server, "smokinguns", @info)
    assert Store.lookup(:exmaster_q3, @server, 0)

    {[_], state} = heartbeat(ctx, state, @server, "smokingunsdead", 60_000)
    {[], _} = Master.tick(ctx, 70_000, state)
    assert Store.lookup(:exmaster_q3, @server, 70_000) == nil
  end

  test "servers are listed for every protocol they reported", %{ctx: ctx, state: state} do
    info = %{@info | "protocol" => "57"} |> Map.put("gamename", "wolfmp")
    state = register(ctx, state, @server, "Wolfenstein-1", info)
    state = register(ctx, state, @server, "Wolfenstein-1", %{info | "protocol" => "60"}, 60_000)
    assert list(ctx, state, "getservers", "57", 60_000) == [@server]
    assert list(ctx, state, "getservers", "60", 60_000) == [@server]
    # 57 was last reported more than server_ttl ago.
    state = register(ctx, state, @server, "Wolfenstein-1", %{info | "protocol" => "60"}, @ttl + 1)
    assert list(ctx, state, "getservers", "57", @ttl + 1) == []
  end

  test "rejects bad infoResponses", %{ctx: ctx, state: state} do
    for {key, value} <- [{"protocol", "x"}, {"sv_maxclients", "0"}, {"gametype", "a b"}] do
      register(ctx, state, @server, "QuakeArena-1", Map.put(@info, key, value))
    end

    assert Store.all(:exmaster_q3, 0) == []
    # Call of Duty leaves clients out when nobody's on.
    register(ctx, state, @server, "QuakeArena-1", Map.delete(@info, "clients"))
    assert Store.lookup(:exmaster_q3, @server, 0).clients == 0
  end

  test "servers expire unless they answer again", %{ctx: ctx, state: state} do
    state = register(ctx, state, @server, "QuakeArena-1", @info)
    assert list(ctx, state, "getservers", "68", @ttl - 1) == [@server]
    assert list(ctx, state, "getservers", "68", @ttl) == []
  end

  test "a listed server's heartbeats have it asked again, at most once a minute", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state, @server, "QuakeArena-1", @info)
    # The query it answered to register starts its minute.
    {[], state} = heartbeat(ctx, state, @server, "QuakeArena-1", 1_000)
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> c, @server}], state} = Master.tick(ctx, 60_000, state)
    state = answer(ctx, state, @server, c, %{@info | "clients" => "5"}, 60_000)
    assert Store.lookup(:exmaster_q3, @server, 60_000).clients == 5

    {[{"\xFF\xFF\xFF\xFFgetinfo " <> _, @server}], state} =
      heartbeat(ctx, state, @server, "QuakeArena-1", 120_000)

    # A heartbeat within the minute is put off to its end.
    {[], state} = heartbeat(ctx, state, @server, "QuakeArena-1", 140_000)
    {[], state} = heartbeat(ctx, state, @server, "QuakeArena-1", 150_000)
    {[], state} = Master.tick(ctx, 179_999, state)
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> _, @server}], state} = Master.tick(ctx, 180_000, state)
    {[], _} = Master.tick(ctx, 181_000, state)
  end

  test "a heartbeat with another tag doesn't reclassify a listed server", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state, @server, "QuakeArena-1", @info)

    {[{"\xFF\xFF\xFF\xFFgetinfo " <> c, @server}], state} =
      heartbeat(ctx, state, @server, "Junk-1", 61_000)

    answer(ctx, state, @server, c, @info, 61_000)

    assert %{class: {:known, "Quake3Arena"}, unknown: false} =
             Store.lookup(:exmaster_q3, @server, 61_000)
  end

  test "a flatline has the server asked, and dropped if it doesn't answer", %{
    ctx: ctx,
    state: state
  } do
    info = %{@info | "protocol" => "84"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info)

    {[{"\xFF\xFF\xFF\xFFgetinfo " <> c, @server}], state} =
      heartbeat(ctx, state, @server, "ETFlatline-1", 61_000)

    # Forged: the server answers, and stays.
    state = answer(ctx, state, @server, c, info, 61_200)
    {[], state} = Master.tick(ctx, 71_000, state)
    assert Store.lookup(:exmaster_q3, @server, 71_000)
    # Real: no answer.
    {[_], state} = heartbeat(ctx, state, @server, "ETFlatline-1", 130_000)
    {[], _} = Master.tick(ctx, 140_000, state)
    assert Store.lookup(:exmaster_q3, @server, 140_000) == nil
  end

  test "a listed server is only asked through the listener it is listed through", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state, @server, "QuakeArena-1", @info)
    other = %{ctx | id: {{0, 0, 0, 0}, 27901}, port: 27901}
    other_state = Master.init(0)
    # Behind NAT, the server may only take packets from the listener it
    # heartbeats; a check from another would go unanswered and drop it.
    {[], other_state} = heartbeat(other, other_state, @server, "QuakeArena-1", 1_000)
    {[], other_state} = heartbeat(other, other_state, @server, "WolfFlatline-1", 1_000)
    {[], _} = Master.tick(other, 20_000, other_state)
    assert Store.lookup(:exmaster_q3, @server, 20_000)
    # Its own listener still asks it.
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> _, @server}], _} =
      heartbeat(ctx, state, @server, "QuakeArena-1", 60_000)
  end

  test "a shutdown right after a poll waits for the minute, then gets its 10 seconds", %{
    ctx: ctx,
    state: state
  } do
    info = %{@info | "protocol" => "84"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info)

    {[{"\xFF\xFF\xFF\xFFgetinfo " <> c, @server}], state} =
      heartbeat(ctx, state, @server, "EnemyTerritory-1", 61_000)

    state = answer(ctx, state, @server, c, info, 61_100)
    # A forged flatline a moment later sends nothing yet: a second query
    # within a second could be dropped by the server's flood protection.
    {[], state} = heartbeat(ctx, state, @server, "ETFlatline-1", 61_200)
    {[], state} = Master.tick(ctx, 120_999, state)
    assert Store.lookup(:exmaster_q3, @server, 120_999)
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> c, @server}], state} = Master.tick(ctx, 121_000, state)
    # The 10 seconds start when the check goes out.
    state = answer(ctx, state, @server, c, info, 121_500)
    {[], _} = Master.tick(ctx, 132_000, state)
    assert Store.lookup(:exmaster_q3, @server, 132_000)
  end

  test "a flatline right after registering waits for the minute", %{ctx: ctx, state: state} do
    info = %{@info | "protocol" => "84"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info, 0)
    {[], state} = heartbeat(ctx, state, @server, "ETFlatline-1", 100)
    {[], state} = Master.tick(ctx, 10_100, state)
    assert Store.lookup(:exmaster_q3, @server, 10_100)
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> _, @server}], state} = Master.tick(ctx, 60_000, state)
    {[], _} = Master.tick(ctx, 70_000, state)
    assert Store.lookup(:exmaster_q3, @server, 70_000) == nil
  end

  test "a heartbeat poll that goes out first carries a waiting check", %{ctx: ctx, state: state} do
    info = %{@info | "protocol" => "84"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info, 0)
    {[], state} = heartbeat(ctx, state, @server, "ETFlatline-1", 1_000)
    # The heartbeat at the minute's end comes before the tick does.
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> _, @server}], state} =
      heartbeat(ctx, state, @server, "EnemyTerritory-1", 60_000)

    {[], state} = Master.tick(ctx, 60_000, state)
    {[], _} = Master.tick(ctx, 70_000, state)
    assert Store.lookup(:exmaster_q3, @server, 70_000) == nil
  end

  test "registering again starts a fresh minute", %{ctx: ctx, state: state} do
    info = %{@info | "protocol" => "84"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info, 0)
    # Dropped by a real shutdown at 70,010; its minute runs to 120,010.
    {[_], state} = heartbeat(ctx, state, @server, "ETFlatline-1", 60_010)
    {[], state} = Master.tick(ctx, 70_010, state)
    assert Store.lookup(:exmaster_q3, @server, 70_010) == nil
    # Back, through a heartbeat that isn't limited per server.
    state = register(ctx, state, @server, "EnemyTerritory-1", info, 119_910)
    # A forged flatline 100 ms later waits for the new minute.
    {[], _} = heartbeat(ctx, state, @server, "ETFlatline-1", 120_010)
  end

  test "a server that restarts during a check is asked again when the check drops it", %{
    ctx: ctx,
    state: state
  } do
    info = %{@info | "protocol" => "84"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info, 0)
    # The old instance's flatline; the new one's heartbeat is put off.
    {[_], state} = heartbeat(ctx, state, @server, "ETFlatline-1", 60_000)
    {[], state} = heartbeat(ctx, state, @server, "EnemyTerritory-1", 63_000)
    # The old instance doesn't answer: dropped, and the new one asked.
    {[{"\xFF\xFF\xFF\xFFgetinfo " <> c, @server}], state} = Master.tick(ctx, 70_000, state)
    assert Store.lookup(:exmaster_q3, @server, 70_000) == nil
    answer(ctx, state, @server, c, info, 70_100)
    assert Store.lookup(:exmaster_q3, @server, 70_100)
  end

  test "a check that goes out replaces one that was waiting", %{ctx: ctx, state: state} do
    info = %{@info | "protocol" => "84"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info, 0)
    {[], state} = heartbeat(ctx, state, @server, "ETFlatline-1", 1_000)

    {[{"\xFF\xFF\xFF\xFFgetinfo " <> c, @server}], state} =
      heartbeat(ctx, state, @server, "ETFlatline-1", 60_000)

    state = answer(ctx, state, @server, c, info, 60_100)
    # Nothing is left waiting, so nothing goes out at the next minute.
    {[], state} = Master.tick(ctx, 60_100, state)
    {[], state} = Master.tick(ctx, 70_000, state)
    {[], _} = Master.tick(ctx, 120_000, state)
    assert Store.lookup(:exmaster_q3, @server, 130_000)
  end

  test "a waiting check is dropped if the server is listed through another listener since", %{
    ctx: ctx,
    state: state
  } do
    info = %{@info | "protocol" => "84"} |> Map.put("gamename", "et")
    state = register(ctx, state, @server, "EnemyTerritory-1", info, 0)
    {[], state} = heartbeat(ctx, state, @server, "ETFlatline-1", 1_000)
    # The store restarts, and the server registers through another listener.
    Store.clear(:exmaster_q3)
    RateLimit.clear()
    other = %{ctx | id: {{0, 0, 0, 0}, 27901}, port: 27901}
    register(other, Master.init(0), @server, "EnemyTerritory-1", info, 2_000)
    {[], _} = Master.tick(ctx, 70_000, state)
    assert %{via: {{0, 0, 0, 0}, 27901}} = Store.lookup(:exmaster_q3, @server, 70_000)
  end

  test "replies through two listeners at once keep both protocols", %{ctx: ctx} do
    # RTCW servers rotate protocols; two listeners answering for one
    # server at the same moment both read its entry before either writes.
    start_supervised!({Store, name: :q3_race}, id: :q3_race)
    ctx = %{ctx | store: :q3_race}
    other = %{ctx | id: {{0, 0, 0, 0}, 27901}, port: 27901}
    info = %{@info | "protocol" => "57"} |> Map.put("gamename", "wolfmp")
    servers = for p <- 1..300, do: {{10, 1, div(p, 256), rem(p, 256)}, 27960}

    tasks =
      for {c, protocol} <- [{ctx, "57"}, {other, "60"}] do
        challenges =
          for addr <- servers do
            {[{"\xFF\xFF\xFF\xFFgetinfo " <> ch, _}], _} =
              heartbeat(c, Master.init(0), addr, "Wolfenstein-1", 0)

            {addr, ch}
          end

        fn ->
          for {addr, ch} <- challenges,
              do: answer(c, Master.init(0), addr, ch, %{info | "protocol" => protocol}, 0)
        end
      end

    tasks |> Enum.map(&Task.async/1) |> Enum.each(&Task.await/1)

    for addr <- servers do
      assert %{protocols: %{57 => _, 60 => _}} = Store.lookup(:q3_race, addr, 0)
    end
  end

  test "flood protection", %{ctx: ctx, state: state} do
    state = register(ctx, state, @server, "QuakeArena-1", @info)
    for _ <- 1..5, do: assert(list(ctx, state, "getservers", "68", 0, @client) == [@server])
    {[], _} = Master.handle_packet(Q3.packet("getservers", ["68"]), @client, ctx, 0, state)

    spoofed = {{192, 0, 2, 1}, 27960}

    replies =
      for p <- 1..70,
          do:
            heartbeat(ctx, state, put_elem(spoofed, 1, p), "QuakeArena-1", 0)
            |> elem(0)
            |> length()

    assert Enum.sum(replies) == 64
  end

  test "getserversExt lists IPv6 servers", %{ctx: ctx, state: state} do
    v6 = {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 27960}
    state = register(ctx, state, @server, "QuakeArena-1", @info)
    state = register(ctx, state, v6, "QuakeArena-1", @info)
    assert list(ctx, state, "getserversExt", "Quake3Arena 68") == [@server, v6]
    assert list(ctx, state, "getserversExt", "Quake3Arena 68 ipv6") == [v6]
    assert list(ctx, state, "getservers", "68") == [@server]
  end
end
