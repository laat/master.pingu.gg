defmodule Exmaster.StoreTest do
  use ExUnit.Case, async: true

  alias Exmaster.Store

  setup do
    name = :"store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name, max_servers: 4, max_per_ip: 2, max_unknown_tag: 1})
    {:ok, store: name}
  end

  defp entry(now, opts \\ []),
    do:
      Map.merge(
        %{game: "Quake3Arena", clients: 0, seen: now, expires: now + 1_000},
        Map.new(opts)
      )

  test "put, lookup, expiry", %{store: s} do
    a = {{1, 1, 1, 1}, 1}
    assert Store.put(s, a, entry(0), 0, nil) == :ok
    assert %{game: "Quake3Arena"} = Store.lookup(s, a, 999)
    assert Store.lookup(s, a, 1_000) == nil
    assert Store.all(s, 999) |> length() == 1
    assert Store.all(s, 1_000) == []
    Store.sweep(s, 1_000)
    assert :ets.info(s, :size) == 0
  end

  test "limits", %{store: s} do
    assert Store.put(s, {{1, 1, 1, 1}, 1}, entry(0), 0, nil) == :ok
    assert Store.put(s, {{1, 1, 1, 1}, 2}, entry(0), 0, nil) == :ok
    assert Store.put(s, {{1, 1, 1, 1}, 3}, entry(0), 0, nil) == {:error, :too_many_on_ip}
    # Replacing a listed server isn't adding one.
    assert Store.put(s, {{1, 1, 1, 1}, 2}, entry(0, clients: 3), 0, entry(0)) == :ok
    assert Store.put(s, {{2, 2, 2, 2}, 1}, entry(0, unknown: true), 0, nil) == :ok

    assert Store.put(s, {{3, 3, 3, 3}, 1}, entry(0, unknown: true), 0, nil) ==
             {:error, :too_many_unknown_tags}

    assert Store.put(s, {{3, 3, 3, 3}, 1}, entry(0), 0, nil) == :ok
    assert Store.put(s, {{4, 4, 4, 4}, 1}, entry(0), 0, nil) == {:error, :full}
  end

  test "expired servers make room", %{store: s} do
    assert Store.put(s, {{1, 1, 1, 1}, 1}, entry(0), 0, nil) == :ok
    assert Store.put(s, {{1, 1, 1, 1}, 2}, entry(0), 0, nil) == :ok
    # Not swept yet, but expired.
    assert Store.put(s, {{1, 1, 1, 1}, 2}, entry(2_000), 2_000, nil) == :ok
    assert Store.put(s, {{1, 1, 1, 1}, 3}, entry(2_000), 2_000, nil) == {:error, :too_many_on_ip}
    Store.sweep(s, 2_500)
    assert Store.put(s, {{1, 1, 1, 1}, 3}, entry(2_500), 2_500, nil) == :ok
  end

  test "filtering by game", %{store: s} do
    Store.put(s, {{1, 1, 1, 1}, 1}, entry(0, game: "et"), 0, nil)
    Store.put(s, {{2, 2, 2, 2}, 1}, entry(0, game: "Xonotic"), 0, nil)
    Store.put(s, {{3, 3, 3, 3}, 1}, entry(0, game: "wolfmp"), 0, nil)
    assert Store.all(s, 0, "et") |> Enum.map(&elem(&1, 0)) == [{{1, 1, 1, 1}, 1}]
    assert Store.all(s, 0, "wolfmp") |> Enum.map(&elem(&1, 0)) == [{{3, 3, 3, 3}, 1}]
  end

  test "a put only replaces the entry it was built from", %{store: s} do
    a = {{1, 1, 1, 1}, 1}
    assert Store.put(s, a, entry(0), 0, nil) == :ok
    # Another listener wrote it first.
    assert Store.put(s, a, entry(0, clients: 1), 0, nil) == {:error, :changed}
    assert Store.put(s, a, entry(0, clients: 1), 0, entry(0, clients: 9)) == {:error, :changed}
    assert Store.put(s, a, entry(0, clients: 1), 0, entry(0)) == :ok
    # Gone since it was read.
    assert Store.put(s, {{1, 1, 1, 1}, 2}, entry(0), 0, entry(0)) == {:error, :changed}
  end

  test "a replacement can't take the unknown-tag cap past its limit", %{store: s} do
    assert Store.put(s, {{1, 1, 1, 1}, 1}, entry(0, unknown: true), 0, nil) == :ok
    assert Store.put(s, {{2, 2, 2, 2}, 1}, entry(0), 0, nil) == :ok

    assert Store.put(s, {{2, 2, 2, 2}, 1}, entry(0, unknown: true), 0, entry(0)) ==
             {:error, :too_many_unknown_tags}
  end

  test "drop_unless_seen", %{store: s} do
    a = {{1, 1, 1, 1}, 1}
    Store.put(s, a, entry(100, via: :a), 100, nil)
    assert Store.drop_unless_seen(s, a, 100, :a) == :kept
    # Listed through another listener.
    assert Store.drop_unless_seen(s, a, 101, :b) == :kept
    assert {:dropped, %{via: :a}} = Store.drop_unless_seen(s, a, 101, :a)
    assert Store.lookup(s, a, 100) == nil
  end

  # What another node's store sends: times on the OS clock.
  defp replica(s, msg) do
    send(s, {:replica, :"other@127.0.0.1", msg})
    :sys.get_state(s)
  end

  defp os_entry(in_ms, opts \\ []) do
    os = System.os_time(:millisecond)
    entry(0, [seen: os + in_ms - 60_000, expires: os + in_ms] ++ opts)
  end

  test "another node's servers, on this node's clock", %{store: s} do
    a = {{1, 1, 1, 1}, 1}
    replica(s, {:put, a, os_entry(60_000)})
    now = Exmaster.now()
    assert [{^a, %{expires: expires}}] = Store.all(s, now)
    assert_in_delta expires, now + 60_000, 1_000
    # Only this node's own servers are looked up and counted.
    assert Store.lookup(s, a, now) == nil
    assert Store.local_count(s, now) == 0

    replica(s, {:drop, a})
    assert Store.all(s, Exmaster.now()) == []
  end

  test "a copy that expired on the way isn't listed", %{store: s} do
    # Held up in transit or in a mailbox past its expiry at its node.
    replica(s, {:put, {{1, 1, 1, 1}, 1}, os_entry(-1)})
    assert Store.all(s, Exmaster.now()) == []
  end

  test "a node's list replaces what it sent before", %{store: s} do
    replica(s, {:put, {{1, 1, 1, 1}, 1}, os_entry(60_000)})
    replica(s, {:list, [{{{2, 2, 2, 2}, 1}, os_entry(60_000)}]})
    assert [{{{2, 2, 2, 2}, 1}, _}] = Store.all(s, Exmaster.now())
  end

  test "the newest copy of a server decides its game", %{store: s} do
    a = {{1, 1, 1, 1}, 1}
    now = Exmaster.now()
    :ok = Store.put(s, a, entry(now, expires: now + 30_000), now, nil)
    replica(s, {:put, a, os_entry(60_000, game: "UrbanTerror")})

    now = Exmaster.now()
    assert [{^a, %{game: "UrbanTerror"}}] = Store.all(s, now)
    assert Store.all(s, now, "Quake3Arena") == []
    assert [{^a, _}] = Store.all(s, now, "UrbanTerror")

    # The older copy, of the game asked for, is ignored the other way round too.
    replica(s, {:put, a, os_entry(10_000, game: "UrbanTerror")})
    now = Exmaster.now()
    assert [{^a, %{game: "Quake3Arena"}}] = Store.all(s, now, "Quake3Arena")
    assert Store.all(s, now, "UrbanTerror") == []
  end

  test "a store's name can't clash with another's replicas" do
    # The store of a listener labelled "replicas", next to this one.
    name = :"store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name}, id: :a)
    start_supervised!({Store, name: :"#{name}_replicas"}, id: :b)
  end
end
