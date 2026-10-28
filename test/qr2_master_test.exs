defmodule Exmaster.QR2.MasterTest do
  use ExUnit.Case

  alias Exmaster.{GS, RateLimit, Store}
  alias Exmaster.QR2.Master

  @ip {203, 0, 113, 5}
  @server {@ip, 23_000}
  @key <<1, 2, 3, 4>>
  @ttl 900_000

  setup do
    Store.clear(:exmaster_qr2)
    RateLimit.clear()

    ctx = %{
      id: {{0, 0, 0, 0}, 27_900},
      port: 27_900,
      label: nil,
      store: :exmaster_qr2,
      masters: [],
      challenge_ttl: 5_000,
      server_ttl: @ttl
    }

    {:ok, ctx: ctx, state: Master.init(0)}
  end

  defp heartbeat(ctx, state, now, opts \\ []) do
    keys = [
      {"localip0", "192.168.1.26"},
      {"localport", "23000"},
      {"statechanged", Keyword.get(opts, :statechanged, "3")},
      {"gamename", Keyword.get(opts, :game, "bfvietnam")},
      {"hostname", Keyword.get(opts, :hostname, "exmaster test")},
      {"numplayers", "3"},
      {"maxplayers", "32"},
      {"gamever", "v1.21"}
    ]

    payload = Enum.map(keys, fn {k, v} -> [k, 0, v, 0] end)
    data = IO.iodata_to_binary([3, Keyword.get(opts, :key, @key), payload, 0, 0, 0])
    Master.handle_packet(data, Keyword.get(opts, :from, @server), ctx, now, state)
  end

  defp answer(ctx, state, challenge, now, opts \\ []) do
    key = Keyword.get(opts, :key, @key)
    response = GS.validate(challenge, Keyword.get(opts, :secret, "h2P9dJ"))
    from = Keyword.get(opts, :from, @server)
    Master.handle_packet(<<1, key::binary, response::binary, 0>>, from, ctx, now, state)
  end

  defp challenge(sends, key \\ @key) do
    [{<<0xFE, 0xFD, 1, ^key::binary-4, challenge::binary-20, 0>>, @server}] = sends
    challenge
  end

  # Heartbeats and answers the challenge.
  defp register(ctx, state, now \\ 0) do
    {sends, state} = heartbeat(ctx, state, now)

    {[{<<0xFE, 0xFD, 0x0A, @key::binary>>, @server}], state} =
      answer(ctx, state, challenge(sends), now)

    state
  end

  test "a server that answers its challenge is listed, as its heartbeat said", %{
    ctx: ctx,
    state: state
  } do
    {sends, state} = heartbeat(ctx, state, 0)
    # 6 characters of HMAC, no options, the address in hex: 203.0.113.5:23000.
    assert challenge(sends) =~ ~r/\A[A-Za-z0-9]{6}00CB00710559D8\z/
    assert Store.lookup(:exmaster_qr2, @server, 0) == nil

    {[{<<0xFE, 0xFD, 0x0A, @key::binary>>, @server}], _} =
      answer(ctx, state, challenge(sends), 0)

    assert %{
             game: "bfvietnam",
             hostname: "exmaster test",
             version: "v1.21",
             clients: 3,
             max_clients: 32,
             local_ip: {192, 168, 1, 26},
             local_port: 23_000,
             instance: @key,
             fields: %{"mapname" => _} = fields
           } =
             Map.update!(
               Store.lookup(:exmaster_qr2, @server, 0),
               :fields,
               &Map.put(&1, "mapname", "")
             )

    assert fields["gamever"] == "v1.21"
  end

  test "wrong, late, other keys' and other instances' answers aren't listed", %{
    ctx: ctx,
    state: state
  } do
    {sends, state} = heartbeat(ctx, state, 0)
    c = challenge(sends)
    {[], state} = answer(ctx, state, c, 0, secret: "HpWx9z")
    # The instance key is in the challenge: another one's reply is wrong.
    {[], state} = answer(ctx, state, c, 0, key: <<9, 9, 9, 9>>)
    {[], state} = answer(ctx, state, c, 0, from: {@ip, 23_001})
    {[], state} = answer(ctx, state, c, 10_000)
    assert Store.lookup(:exmaster_qr2, @server, 10_000) == nil
    {[_], _} = answer(ctx, state, c, 9_999)
    assert Store.lookup(:exmaster_qr2, @server, 9_999)
  end

  test "other games and other packets get nothing", %{ctx: ctx, state: state} do
    assert {[], _} = heartbeat(ctx, state, 0, game: "bfield1942")
    assert {[], _} = Master.handle_packet(<<8, @key::binary>>, @server, ctx, 0, state)
    assert {[], _} = Master.handle_packet(<<3, @key::binary, "x", 0>>, @server, ctx, 0, state)
    assert {[], _} = Master.handle_packet("\\heartbeat\\23000", @server, ctx, 0, state)
  end

  test "an available check is answered for a game it lists", %{ctx: ctx, state: state} do
    from = {@ip, 41_205}

    assert {[{<<0xFE, 0xFD, 9, 0::32>>, ^from}], _} =
             Master.handle_packet(<<9, 0::32, "bfvietnam", 0>>, from, ctx, 0, state)

    assert {[], _} = Master.handle_packet(<<9, 0::32, "other", 0>>, from, ctx, 0, state)
  end

  test "forged heartbeats, with another instance key, change nothing the server answers", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state)
    {[], state} = heartbeat(ctx, state, 30_000, statechanged: "0", hostname: "real")

    # A forger, who doesn't know the instance key, heartbeats as the server:
    # it is asked about with the forger's key, which the server ignores.
    {sends, state} = heartbeat(ctx, state, 31_000, key: <<6, 6, 6, 6>>, hostname: "forged")
    challenge(sends, <<6, 6, 6, 6>>)

    # The minute's poll goes with the server's own key, and takes the
    # server's own heartbeat.
    {sends, state} = Master.tick(ctx, 60_000, state)
    {[_], _} = answer(ctx, state, challenge(sends), 60_100)
    assert %{hostname: "real", instance: @key} = Store.lookup(:exmaster_qr2, @server, 60_100)
  end

  test "a listed server's heartbeats have it asked at most once a minute", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state)
    {[], state} = heartbeat(ctx, state, 30_000, statechanged: "1", hostname: "later")
    {[], state} = Master.tick(ctx, 59_000, state)
    {sends, state} = Master.tick(ctx, 60_000, state)
    {[_], state} = answer(ctx, state, challenge(sends), 60_100)
    assert %{hostname: "later"} = Store.lookup(:exmaster_qr2, @server, @ttl + 60_000)
    assert {[{_, @server}], _} = heartbeat(ctx, state, 130_000, statechanged: "0")
  end

  test "statechanged 2 has the server asked with its own key, and dropped if it doesn't answer",
       %{ctx: ctx, state: state} do
    state = register(ctx, state)

    # Forged, with another key: the check goes out with the listed one, and
    # the server answers it.
    {sends, state} = heartbeat(ctx, state, 61_000, statechanged: "2", key: <<6, 6, 6, 6>>)
    {[_], state} = answer(ctx, state, challenge(sends), 61_200)
    {[], state} = Master.tick(ctx, 71_000, state)
    assert Store.lookup(:exmaster_qr2, @server, 71_000)

    # Real: no answer.
    {[_], state} = heartbeat(ctx, state, 130_000, statechanged: "2")
    {[], _} = Master.tick(ctx, 140_000, state)
    assert Store.lookup(:exmaster_qr2, @server, 140_000) == nil
  end

  test "a poll put off while an exit check is out stays, if the server answers the check", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state)
    # A forged exit, which the server answers; then its own heartbeat, put
    # off to the minute's end.
    {sends, state} = heartbeat(ctx, state, 61_000, statechanged: "2")
    {[_], state} = answer(ctx, state, challenge(sends), 61_200)
    {[], state} = heartbeat(ctx, state, 65_000, statechanged: "1", hostname: "changed")
    {[], state} = Master.tick(ctx, 71_000, state)
    {sends, state} = Master.tick(ctx, 122_000, state)
    {[_], _} = answer(ctx, state, challenge(sends), 122_100)
    assert Store.lookup(:exmaster_qr2, @server, 122_100).hostname == "changed"
  end

  # UT3 puts its settings in mapname, 521 bytes of them.
  test "values are kept to 1 KB, and a server's keys to 2 KB in all", %{ctx: ctx, state: state} do
    settings = String.duplicate("s", 521)
    long = String.duplicate("l", 2_000)

    keys = [
      {"gamename", "bfvietnam"},
      {"mapname", settings},
      {"first", long},
      {"second", long},
      {"third", "x"}
    ]

    payload = Enum.map(keys, fn {k, v} -> [k, 0, v, 0] end)
    data = IO.iodata_to_binary([3, @key, payload, 0])
    {sends, state} = Master.handle_packet(data, @server, ctx, 0, state)
    {[_], _} = answer(ctx, state, challenge(sends), 0)

    fields = Store.lookup(:exmaster_qr2, @server, 0).fields
    assert fields["mapname"] == settings
    # Copies, not views into the 5 KB packet.
    assert :binary.referenced_byte_size(fields["mapname"]) == 521
    assert fields["first"] == binary_part(long, 0, 1_024)
    refute Map.has_key?(fields, "second")
    refute Map.has_key?(fields, "third")
  end

  test "a local address that isn't text is no local address", %{ctx: ctx, state: state} do
    data = <<3, @key::binary, "gamename", 0, "bfvietnam", 0, "localip0", 0, 0xFF, 0xFE, 0, 0>>
    {sends, state} = Master.handle_packet(data, @server, ctx, 0, state)
    {[_], _} = answer(ctx, state, challenge(sends), 0)
    assert %{local_ip: nil} = Store.lookup(:exmaster_qr2, @server, 0)
  end

  test "a restarted server, with a new instance key, is asked at once and keeps its entry", %{
    ctx: ctx,
    state: state
  } do
    state = register(ctx, state)
    {[_], state} = heartbeat(ctx, state, 61_000, statechanged: "2")
    # The new instance heartbeats a moment later, and answers.
    {sends, state} = heartbeat(ctx, state, 62_000, key: <<5, 5, 5, 5>>, hostname: "new")
    c = challenge(sends, <<5, 5, 5, 5>>)
    {[_], state} = answer(ctx, state, c, 62_100, key: <<5, 5, 5, 5>>)

    assert %{instance: <<5, 5, 5, 5>>, hostname: "new"} =
             Store.lookup(:exmaster_qr2, @server, 62_100)

    # The old instance's check finds it seen since.
    {[], _} = Master.tick(ctx, 71_000, state)
    assert Store.lookup(:exmaster_qr2, @server, 71_000)
  end

  test "heartbeats are kept aside for 75 seconds, two an address", %{ctx: ctx, state: state} do
    state = register(ctx, state)
    {_, state} = heartbeat(ctx, state, 10_000, key: <<6, 6, 6, 6>>)
    {_, state} = heartbeat(ctx, state, 11_000, key: <<7, 7, 7, 7>>)
    assert Map.keys(state.pending[@server]) |> Enum.sort() == [@key, <<7, 7, 7, 7>>]
    {[], state} = Master.tick(ctx, 74_999, state)
    assert map_size(state.pending[@server]) == 2
    {[], state} = Master.tick(ctx, 75_000, state)
    assert Map.keys(state.pending[@server]) == [<<7, 7, 7, 7>>]
    {[], state} = Master.tick(ctx, 86_000, state)
    assert state.pending == %{}
  end
end
