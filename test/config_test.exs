defmodule Exmaster.ConfigTest do
  use ExUnit.Case, async: true

  alias Exmaster.Config

  test "listeners" do
    assert Config.listeners!("q3:27950, q3:27960=UrbanTerror,q2:127.0.0.1:27900,qw:27000,") == [
             [
               protocol: Exmaster.Q3.Master,
               ip: nil,
               port: 27950,
               label: nil,
               store: :exmaster_q3
             ],
             [
               protocol: Exmaster.Q3.Master,
               ip: nil,
               port: 27960,
               label: "UrbanTerror",
               store: :exmaster_q3_UrbanTerror
             ],
             [
               protocol: Exmaster.Q2.Master,
               ip: {127, 0, 0, 1},
               port: 27900,
               label: nil,
               store: :exmaster_q2
             ],
             [protocol: Exmaster.QW.Master, ip: nil, port: 27000, label: nil, store: :exmaster_qw]
           ]

    assert [[protocol: Exmaster.Q3.Master, ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 27950] ++ _] =
             Config.listeners!("q3:[::1]:27950")

    assert Config.listeners!("") == []

    assert Config.listeners!("gs:27900,gsl:127.0.0.1:28900") == [
             [
               protocol: Exmaster.GS.Master,
               ip: nil,
               port: 27900,
               label: nil,
               store: :exmaster_gs
             ],
             [
               protocol: Exmaster.GS.ListServer,
               ip: {127, 0, 0, 1},
               port: 28900,
               label: nil,
               store: :exmaster_gs
             ]
           ]

    assert Config.listeners!("ue2:28902") == [
             [
               protocol: Exmaster.UE2.Master,
               ip: nil,
               port: 28902,
               label: nil,
               store: :exmaster_ue2
             ]
           ]
  end

  test "a q2 and a gs listener on one address and port share a socket" do
    q2gs = [protocol: Exmaster.Q2GS, ip: nil, port: 27900, label: nil, store: :exmaster_q2]

    assert Config.listeners!("q3:27950,gs:27900,gsl:28900,q2:27900") == [
             [
               protocol: Exmaster.Q3.Master,
               ip: nil,
               port: 27950,
               label: nil,
               store: :exmaster_q3
             ],
             q2gs,
             [
               protocol: Exmaster.GS.ListServer,
               ip: nil,
               port: 28900,
               label: nil,
               store: :exmaster_gs
             ]
           ]

    assert Config.listeners!("q2:127.0.0.1:27900,gs:127.0.0.1:27900") ==
             [List.keyreplace(q2gs, :ip, 0, {:ip, {127, 0, 0, 1}})]

    # On other addresses or ports they don't.
    assert [[protocol: Exmaster.Q2.Master] ++ _, [protocol: Exmaster.GS.Master] ++ _] =
             Config.listeners!("q2:127.0.0.1:27900,gs:127.0.0.2:27900")

    assert [[protocol: Exmaster.Q2.Master] ++ _, [protocol: Exmaster.GS.Master] ++ _] =
             Config.listeners!("q2:27900,gs:27901")
  end

  test "each label has a store, shared by its listeners" do
    listeners = Config.listeners!("q3:27950,q3:27960=UrbanTerror,q3:[::1]:27960=UrbanTerror")

    assert Config.stores(listeners) == [
             {:q3, :exmaster_q3},
             {:q2, :exmaster_q2},
             {:qw, :exmaster_qw},
             {:gs, :exmaster_gs},
             {:ue2, :exmaster_ue2},
             {"UrbanTerror", :exmaster_q3_UrbanTerror}
           ]
  end

  test "bad specs" do
    assert_raise ArgumentError, ~r/IPv4 only/, fn -> Config.listeners!("qw:[::]:27000") end
    assert_raise ArgumentError, ~r/IPv4 only/, fn -> Config.listeners!("gsl:[::]:28900") end
    assert_raise ArgumentError, ~r/IPv4 only/, fn -> Config.listeners!("ue2:[::]:28902") end
    assert_raise ArgumentError, ~r/labels are for q3/, fn -> Config.listeners!("ue2:28902=x") end
    assert_raise ArgumentError, ~r/labels are for q3/, fn -> Config.listeners!("q2:27900=Q2") end

    for bad <- ["q4:27950", "q3", "q3:x", "q3:70000", "q3:27950=bad label", "q3:nohost:1"] do
      assert_raise ArgumentError, fn -> Config.listeners!(bad) end
    end
  end
end
