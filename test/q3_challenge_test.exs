defmodule Exmaster.Q3.ChallengeTest do
  use ExUnit.Case, async: true

  alias Exmaster.Q3.Challenge

  @key :crypto.strong_rand_bytes(32)
  @addr {{203, 0, 113, 5}, 27960}
  @ttl 5_000
  @via {{0, 0, 0, 0}, 27950}

  test "a challenge is 11 characters from the allowed set and checks once issued" do
    c = Challenge.issue(@addr, 3, @via, 12_345, @ttl, @key)
    assert byte_size(c) == 11
    assert c |> :binary.bin_to_list() |> Enum.all?(&(&1 in 33..126 and &1 not in ~c(\\/;"%)))
    assert Challenge.check(@addr, c, @via, 12_345, @ttl, @key) == {:ok, 3}
  end

  test "it carries its class" do
    for class <- 0..5 do
      c = Challenge.issue(@addr, class, @via, 0, @ttl, @key)
      assert Challenge.check(@addr, c, @via, 0, @ttl, @key) == {:ok, class}
    end
  end

  test "it only checks for its address, listener, class and key" do
    c = Challenge.issue(@addr, 2, @via, 0, @ttl, @key)
    assert Challenge.check({{203, 0, 113, 5}, 27961}, c, @via, 0, @ttl, @key) == :error
    assert Challenge.check({{203, 0, 113, 6}, 27960}, c, @via, 0, @ttl, @key) == :error
    assert Challenge.check(@addr, c, {{0, 0, 0, 0}, 27900}, 0, @ttl, @key) == :error
    assert Challenge.check(@addr, c, @via, 0, @ttl, :crypto.strong_rand_bytes(32)) == :error
    # Another class character with the same MAC.
    <<_, mac::binary>> = c
    assert Challenge.check(@addr, <<?#, mac::binary>>, @via, 0, @ttl, @key) == :error
  end

  test "listeners on one port and different addresses don't share challenges" do
    a = {{192, 0, 2, 1}, 27950}
    b = {{192, 0, 2, 2}, 27950}
    c = Challenge.issue(@addr, 0, a, 0, @ttl, @key)
    assert {:ok, 0} = Challenge.check(@addr, c, a, 0, @ttl, @key)
    assert Challenge.check(@addr, c, b, 0, @ttl, @key) == :error
  end

  test "it lives between one and two TTLs" do
    c = Challenge.issue(@addr, 0, @via, 4_999, @ttl, @key)
    assert {:ok, 0} = Challenge.check(@addr, c, @via, 9_999, @ttl, @key)
    assert Challenge.check(@addr, c, @via, 10_000, @ttl, @key) == :error

    c = Challenge.issue(@addr, 0, @via, 5_000, @ttl, @key)
    assert {:ok, 0} = Challenge.check(@addr, c, @via, 14_999, @ttl, @key)
    assert Challenge.check(@addr, c, @via, 4_999, @ttl, @key) == :error
  end

  test "negative clocks" do
    c = Challenge.issue(@addr, 1, @via, -12_000, @ttl, @key)
    assert {:ok, 1} = Challenge.check(@addr, c, @via, -8_000, @ttl, @key)
  end

  test "garbage" do
    for bad <- [nil, "", "short", String.duplicate("x", 11), String.duplicate("x", 12)] do
      assert Challenge.check(@addr, bad, @via, 0, @ttl, @key) == :error
    end
  end
end
