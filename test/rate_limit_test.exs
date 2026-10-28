defmodule Exmaster.RateLimitTest do
  use ExUnit.Case, async: true

  alias Exmaster.RateLimit

  test "a burst, then one per interval" do
    key = make_ref()
    limit = {1, 3_000, 5}
    for _ <- 1..5, do: assert(RateLimit.take(key, limit, 1, 0) == :ok)
    assert RateLimit.take(key, limit, 1, 0) == {:error, 3_000}
    assert RateLimit.take(key, limit, 1, 2_999) == {:error, 1}
    assert RateLimit.take(key, limit, 1, 3_000) == :ok
    assert {:error, _} = RateLimit.take(key, limit, 1, 3_000)
    # Full again after 5 intervals.
    for _ <- 1..5, do: assert(RateLimit.take(key, limit, 1, 18_000) == :ok)
  end

  test "drain empties a bucket as of now, whatever it held" do
    key = make_ref()
    limit = {1, 60_000, 1}
    assert RateLimit.take(key, limit, 1, 0) == :ok
    # Spent until 60,000; drained at 50,000, it is spent until 110,000.
    assert RateLimit.drain(key, limit, 50_000) == :ok
    assert RateLimit.take(key, limit, 1, 109_999) == {:error, 1}
    assert RateLimit.take(key, limit, 1, 110_000) == :ok
    # Draining doesn't shorten a wait.
    assert RateLimit.drain(key, limit, 110_000) == :ok
    assert RateLimit.take(key, limit, 1, 169_999) == {:error, 1}
    assert RateLimit.drain(make_ref(), limit, 0) == :ok
  end

  test "costs larger than the burst never pass" do
    assert {:error, _} = RateLimit.take(make_ref(), {1, 1_000, 5}, 6, 0)
  end

  test "byte budgets" do
    key = make_ref()
    limit = {262_144, 1_000, 1_048_576}
    assert RateLimit.take(key, limit, 1_048_576, 0) == :ok
    assert {:error, _} = RateLimit.take(key, limit, 7_000, 0)
    assert RateLimit.take(key, limit, 262_144, 1_000) == :ok
  end

  test "small byte costs add up exactly" do
    key = make_ref()
    limit = {262_144, 1_000, 1_048_576}
    results = for _ <- 1..800, do: RateLimit.take(key, limit, 1_400, 0)
    assert Enum.count(results, &(&1 == :ok)) == div(1_048_576, 1_400)
    # One second later, 262,144 bytes more, no more.
    results = for _ <- 1..800, do: RateLimit.take(key, limit, 1_400, 1_000)
    assert Enum.count(results, &(&1 == :ok)) == div(262_144 + rem(1_048_576, 1_400), 1_400)
  end

  test "listeners spending from one bucket at once spend it once" do
    key = make_ref()
    limit = {1, 1_000_000, 1_000}

    results =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn -> for _ <- 1..500, do: RateLimit.take(key, limit, 1, 0) end)
      end)
      |> Enum.flat_map(&Task.await/1)

    assert Enum.count(results, &(&1 == :ok)) == 1_000
  end
end
