defmodule Exmaster.ConfigTest do
  use ExUnit.Case, async: true

  alias Exmaster.Config

  test "listeners" do
    assert Config.listeners!("q3:27950, q3:27900=UrbanTerror,q2:127.0.0.1:27900,qw:27000,") == [
             [protocol: Exmaster.Q3.Master, ip: nil, port: 27950, label: nil],
             [protocol: Exmaster.Q3.Master, ip: nil, port: 27900, label: "UrbanTerror"],
             [protocol: Exmaster.Q2.Master, ip: {127, 0, 0, 1}, port: 27900, label: nil],
             [protocol: Exmaster.QW.Master, ip: nil, port: 27000, label: nil]
           ]

    assert Config.listeners!("q3:[::1]:27950") == [
             [protocol: Exmaster.Q3.Master, ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 27950, label: nil]
           ]

    assert Config.listeners!("") == []
  end

  test "bad specs" do
    assert_raise ArgumentError, ~r/IPv4 only/, fn -> Config.listeners!("qw:[::]:27000") end
    assert_raise ArgumentError, ~r/labels are for q3/, fn -> Config.listeners!("q2:27900=Q2") end

    for bad <- ["q4:27950", "q3", "q3:x", "q3:70000", "q3:27950=bad label", "q3:nohost:1"] do
      assert_raise ArgumentError, fn -> Config.listeners!(bad) end
    end
  end
end
