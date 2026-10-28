defmodule Exmaster.PaidTest do
  use ExUnit.Case

  alias Exmaster.{Paid, RateLimit}

  @localhost {127, 0, 0, 1}

  setup do
    RateLimit.clear()
    {:ok, l} = :gen_tcp.listen(0, [:binary, active: false, ip: @localhost])
    {:ok, port} = :inet.port(l)
    {:ok, c} = :gen_tcp.connect(@localhost, port, [:binary, active: false])
    {:ok, s} = :gen_tcp.accept(l)
    {:ok, client: c, server: s}
  end

  test "chunks of 64 KB at most, or one part" do
    part = :binary.copy("x", 30_000)
    assert [{[^part, ^part], 60_000}, {[^part], 30_000}] = Paid.chunks([part, part, part])

    big = :binary.copy("y", 70_000)
    assert [{["a"], 1}, {[^big], 70_000}, {["b"], 1}] = Paid.chunks(["a", big, "b"])
    assert Paid.chunks([]) == []
  end

  # On loopback the kernel buffers more than a test can send, so a slow
  # reader doesn't get there; this is the check, given an end.
  test "a list stops at its connection's end, moved by its waits for the budget", %{
    client: c,
    server: s
  } do
    now = Exmaster.now()
    chunks = [{"abc", 3}, {"def", 3}]

    assert Paid.send(s, chunks, 6, now - 1) == :error
    assert :gen_tcp.recv(c, 0, 100) == {:error, :timeout}
    assert Paid.send(s, chunks, 6, now - 1, 1_000) == :ok
    assert Paid.send(s, chunks, 6, now + 1_000) == :ok
    assert {:ok, "abcdefabcdef"} = :gen_tcp.recv(c, 12, 1_000)
  end

  test "it waits for the budget when it is spent", %{client: c, server: s} do
    # Spend the burst, 1 MB; 64 KB more takes about a quarter second.
    :ok = RateLimit.spend_reply(1_048_576, Exmaster.now())
    started = Exmaster.now()
    assert Paid.send(s, [{:binary.copy("z", 65_536), 65_536}], 0, started + 100) == :ok
    assert Exmaster.now() - started >= 200
    assert {:ok, _} = :gen_tcp.recv(c, 65_536, 1_000)
  end
end
