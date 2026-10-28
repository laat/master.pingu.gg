defmodule Exmaster.ClusterTest do
  @moduledoc """
  Two nodes sharing their server lists: this one and a peer started with
  `:peer`, running the application.
  """
  use ExUnit.Case

  alias Exmaster.Store

  @store :exmaster_q3
  @peer :"exmaster_peer@127.0.0.1"

  setup_all do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start(:"exmaster_test@127.0.0.1", %{name_domain: :longnames})
    end

    opts = %{
      name: :exmaster_peer,
      host: ~c"127.0.0.1",
      longnames: true,
      # Not distribution, which would stop the peer when the test splits the nodes.
      connection: :standard_io,
      args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    }

    start_supervised!(%{id: :peer, start: {:peer, :start_link, [opts]}})
    env = [exmaster: Application.get_all_env(:exmaster), logger: [level: :warning]]
    :ok = :erpc.call(@peer, Application, :put_all_env, [env])
    {:ok, _} = :erpc.call(@peer, Application, :ensure_all_started, [:exmaster])
    :ok
  end

  setup do
    Store.clear(@store)
    :erpc.call(@peer, Store, :clear, [@store])
    wait_until(fn -> servers(node()) == [] and servers(@peer) == [] end)
    :ok
  end

  defp entry(now, opts \\ []),
    do:
      Map.merge(
        %{
          game: "Quake3Arena",
          clients: 1,
          seen: now,
          expires: now + 60_000,
          verified: now,
          protocols: %{68 => now}
        },
        Map.new(opts)
      )

  defp peer_now, do: :erpc.call(@peer, Exmaster, :now, [])
  defp servers(node), do: :erpc.call(node, Exmaster, :servers, [:q3])
  defp addresses(node), do: node |> servers() |> Enum.map(& &1.address)

  defp wait_until(f, tries \\ 100) do
    cond do
      f.() ->
        :ok

      tries == 0 ->
        flunk("timed out")

      true ->
        Process.sleep(20)
        wait_until(f, tries - 1)
    end
  end

  test "a server listed on one node is listed on the other, on its clock" do
    a = {{198, 51, 100, 1}, 27960}
    now = Exmaster.now()
    :ok = Store.put(@store, a, entry(now), now, nil)
    wait_until(fn -> addresses(@peer) == ["198.51.100.1:27960"] end)

    [%{expires_in: expires_in}] = servers(@peer)
    assert expires_in in 58..60
    # The peer's protocol times are moved onto its clock too.
    [{^a, e}] = :erpc.call(@peer, Store, :all, [@store, peer_now()])
    assert_in_delta e.protocols[68], peer_now(), 1_000

    # Only the node that listed it asks and checks it.
    assert :erpc.call(@peer, Store, :lookup, [@store, a, peer_now()]) == nil
    assert :erpc.call(@peer, Store, :local_count, [@store, peer_now()]) == 0
  end

  test "both ways, and drops" do
    a = {{198, 51, 100, 1}, 27960}
    b = {{198, 51, 100, 2}, 27960}
    now = Exmaster.now()
    :ok = Store.put(@store, a, entry(now, via: :x), now, nil)
    pnow = peer_now()
    :ok = :erpc.call(@peer, Store, :put, [@store, b, entry(pnow), pnow, nil])

    both = ["198.51.100.1:27960", "198.51.100.2:27960"]
    wait_until(fn -> addresses(node()) == both and addresses(@peer) == both end)

    {:dropped, _} = Store.drop_unless_seen(@store, a, Exmaster.now() + 1, :x)
    wait_until(fn -> addresses(@peer) == ["198.51.100.2:27960"] end)
  end

  test "a server both nodes list is listed once, as the last to hear from it has it" do
    a = {{198, 51, 100, 1}, 27960}
    now = Exmaster.now()
    :ok = Store.put(@store, a, entry(now - 5_000, clients: 1), now, nil)
    pnow = peer_now()
    :ok = :erpc.call(@peer, Store, :put, [@store, a, entry(pnow, clients: 7), pnow, nil])

    wait_until(fn -> match?([%{clients: 7}], servers(node())) end)
    assert [%{clients: 7}] = servers(@peer)
  end

  test "a store that starts again replaces what the others had from it" do
    a = {{198, 51, 100, 1}, 27960}
    pnow = peer_now()
    :ok = :erpc.call(@peer, Store, :put, [@store, a, entry(pnow), pnow, nil])
    wait_until(fn -> addresses(node()) == ["198.51.100.1:27960"] end)

    # Killed, so it can't send anything on the way out; it restarts empty.
    pid = :erpc.call(@peer, Process, :whereis, [@store])
    Process.exit(pid, :kill)
    wait_until(fn -> addresses(node()) == [] end)
  end

  test "after a split, each node's list replaces what the other had from it" do
    a = {{198, 51, 100, 1}, 27960}
    b = {{198, 51, 100, 2}, 27960}
    pnow = peer_now()
    :ok = :erpc.call(@peer, Store, :put, [@store, a, entry(pnow, via: :x), pnow, nil])
    wait_until(fn -> addresses(node()) == ["198.51.100.1:27960"] end)

    # While apart, the peer drops one server and lists another. Any call to
    # the peer would connect the nodes again, so it is told beforehand.
    script = """
    Process.sleep(300)
    now = Exmaster.now()
    {:dropped, _} = Exmaster.Store.drop_unless_seen(:exmaster_q3, #{inspect(a)}, now + 1, :x)
    e = %{game: "Quake3Arena", clients: 1, seen: now, expires: now + 60_000, protocols: %{68 => now}}
    :ok = Exmaster.Store.put(:exmaster_q3, #{inspect(b)}, e, now, nil)
    """

    :erpc.call(@peer, :erlang, :spawn, [Code, :eval_string, [script]])
    true = Node.disconnect(@peer)
    Process.sleep(600)
    # Kept through the split: the peer's node may still be up.
    assert addresses(node()) == ["198.51.100.1:27960"]

    true = Node.connect(@peer)
    wait_until(fn -> addresses(node()) == ["198.51.100.2:27960"] end)
  end
end
