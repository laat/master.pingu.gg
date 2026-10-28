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
    Store.put(s, {{2, 2, 2, 2}, 1}, entry(0, game: "ETLegacy"), 0, nil)
    Store.put(s, {{3, 3, 3, 3}, 1}, entry(0, game: "wolfmp"), 0, nil)
    assert Store.all(s, 0, ["et"]) |> Enum.map(&elem(&1, 0)) == [{{1, 1, 1, 1}, 1}]

    assert Store.all(s, 0, ["et", "ETLegacy"]) |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
             {{1, 1, 1, 1}, 1},
             {{2, 2, 2, 2}, 1}
           ]
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
end
