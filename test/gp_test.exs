defmodule Exmaster.GPTest do
  use ExUnit.Case, async: true

  alias Exmaster.{GP, GS}

  # A UT3 server's login, captured on loopback against exmaster with the
  # password pingu, and the proof it took: it went on to heartbeat. With a
  # wrong proof it hangs up.
  @challenge "HBIOUOFJDI"
  @login "\\login\\\\challenge\\XBZsTAgM9ZAEzCCiMch2Qpdp5PCaGJXd\\uniquenick\\exmaster\\partnerid\\0\\response\\98ea7fac2a12c94f3e986c7371b127e9\\port\\-9275\\productid\\11097\\gamename\\ut3pc\\namespaceid\\64\\sdkrevision\\3\\id\\1"

  test "a UT3 server's login and the proof it took" do
    login = GS.parse(@login)
    h = GP.password_hash("pingu")
    assert GP.user(login) == "exmaster"
    assert GP.response(h, "exmaster", login["challenge"], @challenge) == login["response"]

    assert GP.proof(h, "exmaster", login["challenge"], @challenge) ==
             "2b977becb0998ab90c5790c8a92363aa"

    refute GP.response(GP.password_hash("other"), "exmaster", login["challenge"], @challenge) ==
             login["response"]
  end

  test "the user a login hashes" do
    assert GP.user(%{"uniquenick" => "a", "partnerid" => "0"}) == "a"
    assert GP.user(%{"uniquenick" => "a", "partnerid" => "11"}) == "11@a"
    assert GP.user(%{"user" => "nick@mail.example"}) == "nick@mail.example"
    assert GP.user(%{"authtoken" => "x", "uniquenick" => "a"}) == nil
    assert GP.user(%{"uniquenick" => ""}) == nil
  end

  test "messages, profile ids, replies" do
    assert GP.split("\\ka\\\\final\\\\status\\1\\final\\\\lo") ==
             {["\\ka\\", "\\status\\1"], "\\lo"}

    assert GP.split("\\ka\\") == {[], "\\ka\\"}

    id = GP.profile_id("exmaster")
    assert id == GP.profile_id("ExMaster")
    assert id in 1..2_147_483_648
    refute id == GP.profile_id("exmaster2")

    assert GP.greeting("ABC") == "\\lc\\1\\challenge\\ABC\\id\\1\\final\\"

    assert GP.logged_in("a", 7, "p", "t__", "1") ==
             "\\lc\\2\\sesskey\\7\\proof\\p\\userid\\7\\profileid\\7\\uniquenick\\a\\lt\\t__\\id\\1\\final\\" <>
               "\\bdy\\0\\list\\\\final\\\\blk\\0\\list\\\\final\\"

    assert GP.error(260, "no", nil) == "\\error\\\\err\\260\\fatal\\\\errmsg\\no\\id\\1\\final\\"
  end
end
