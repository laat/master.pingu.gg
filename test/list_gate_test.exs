defmodule Exmaster.ListGateTest do
  use ExUnit.Case

  alias Exmaster.ListGate

  @a {198, 51, 100, 1}
  @b {198, 51, 100, 2}
  @c {198, 51, 100, 3}

  # A process that asks for weight for a client at ip and holds what it
  # gets until it is stopped, admitted again at other weights as it is
  # sent them: {pid, the answer}.
  defp holder(ip, weight) do
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:admitted, ListGate.admit(ip, weight)})
        hold(parent, ip)
      end)

    assert_receive {:admitted, answer}
    {pid, answer}
  end

  defp hold(parent, ip) do
    receive do
      :stop ->
        :ok

      {:weigh, weight} ->
        send(parent, {:admitted, ListGate.admit(ip, weight)})
        hold(parent, ip)
    end
  end

  defp weigh(pid, weight) do
    send(pid, {:weigh, weight})
    assert_receive {:admitted, answer}
    answer
  end

  defp stop(pids) do
    Enum.each(pids, &send(&1, :stop))
    eventually(fn -> :sys.get_state(ListGate).total == 0 end)
  end

  defp eventually(f, tries \\ 100) do
    case f.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(10)
        eventually(f, tries - 1)

      result ->
        result
    end
  end

  test "lists are admitted up to the capacity together, and one larger than it alone" do
    cap = ListGate.capacity()
    {a, :ok} = holder(@a, cap - 10)
    {b, :ok} = holder(@b, 10)
    {c, :busy} = holder(@c, 1)
    {d, :ok} = holder(@c, 0)
    stop([a, b, c, d])

    {e, :ok} = holder(@a, cap * 4)
    {f, :busy} = holder(@b, 1)
    stop([e, f])
  end

  test "an IP's lists have a share of the capacity, but for its first" do
    share = ListGate.per_ip()
    {a, :ok} = holder(@a, share * 2)
    {b, :busy} = holder(@a, 1)
    {c, :ok} = holder(@b, share - 1)
    {d, :ok} = holder(@b, 1)
    {e, :busy} = holder(@b, 1)
    {f, :ok} = holder(@c, 1)
    stop([a, b, c, d, e, f])
  end

  test "a list admitted again is weighed again, and keeps its weight if refused" do
    cap = ListGate.capacity()
    {a, :ok} = holder(@a, 10)
    {b, :ok} = holder(@b, cap - 20)
    assert weigh(a, 30) == :busy
    assert :sys.get_state(ListGate).total == cap - 10
    assert weigh(a, 20) == :ok
    assert weigh(a, 5) == :ok
    assert :sys.get_state(ListGate).total == cap - 15
    stop([a, b])
  end

  test "a list's weight is freed when its process ends, however it ends" do
    cap = ListGate.capacity()
    {a, :ok} = holder(@a, cap)
    {b, :busy} = holder(@b, 1)
    Process.exit(a, :kill)
    eventually(fn -> :sys.get_state(ListGate).total == 0 end)
    assert :sys.get_state(ListGate).ips == %{}
    {c, :ok} = holder(@b, cap)
    stop([b, c])
  end
end
