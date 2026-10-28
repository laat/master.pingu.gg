defmodule Exmaster.GP.ServerTest do
  @moduledoc "GameSpy's login over real sockets, as a UT3 server logs in."
  use ExUnit.Case

  alias Exmaster.{GP, GS, RateLimit}
  alias Exmaster.GP.Server

  @localhost {127, 0, 0, 1}

  setup do
    RateLimit.clear()
    :ok
  end

  defp start(opts \\ []) do
    pid = start_supervised!({Server, [ip: @localhost, port: 0, password: "pingu"] ++ opts})
    Server.port(pid)
  end

  defp connect(port) do
    {:ok, s} = :gen_tcp.connect(@localhost, port, [:binary, active: false])
    s
  end

  defp greeting(s) do
    {:ok, "\\lc\\1\\challenge\\" <> rest} = :gen_tcp.recv(s, 0, 1_000)
    [challenge, "1\\final\\"] = String.split(rest, "\\id\\")
    assert challenge =~ ~r/\A[A-Z]{10}\z/
    challenge
  end

  defp login(s, challenge, password, name \\ "exmaster") do
    cc = "XBZsTAgM9ZAEzCCiMch2Qpdp5PCaGJXd"
    response = GP.response(GP.password_hash(password), name, cc, challenge)

    :ok =
      :gen_tcp.send(
        s,
        "\\login\\\\challenge\\#{cc}\\uniquenick\\#{name}\\partnerid\\0\\response\\#{response}garbage" <>
          "\\port\\-9275\\productid\\11097\\gamename\\ut3pc\\namespaceid\\64\\sdkrevision\\3\\id\\1\\final\\"
      )

    cc
  end

  defp read_all(s, acc \\ "") do
    case :gen_tcp.recv(s, 0, 500) do
      {:ok, data} -> read_all(s, acc <> data)
      {:error, :timeout} -> {:open, acc}
      {:error, :closed} -> {:closed, acc}
    end
  end

  test "a login with the password is answered with the proof, and kept" do
    port = start()
    s = connect(port)
    challenge = greeting(s)
    cc = login(s, challenge, "pingu")

    assert {:open, reply} = read_all(s)
    {[lc2, bdy, blk], ""} = GP.split(reply)
    lc2 = GS.parse(lc2)
    assert lc2["lc"] == "2"
    assert lc2["proof"] == GP.proof(GP.password_hash("pingu"), "exmaster", cc, challenge)
    assert lc2["profileid"] == Integer.to_string(GP.profile_id("exmaster"))
    assert lc2["uniquenick"] == "exmaster"
    assert {bdy, blk} == {"\\bdy\\0\\list\\", "\\blk\\0\\list\\"}

    # What it sends after, keepalives included, is taken and ignored; a
    # logout ends it.
    :ok = :gen_tcp.send(s, "\\status\\2\\sesskey\\1\\final\\\\ka\\\\final\\")
    assert {:open, ""} = read_all(s)
    :ok = :gen_tcp.send(s, "\\logout\\\\sesskey\\1\\final\\")
    assert {:closed, ""} = read_all(s)
  end

  test "other passwords, and logins by token, are refused" do
    port = start()
    s = connect(port)
    login(s, greeting(s), "exmaster")
    assert {:closed, reply} = read_all(s)
    assert %{"err" => "260"} = GS.parse(reply)

    s = connect(port)
    greeting(s)
    :ok = :gen_tcp.send(s, "\\login\\\\challenge\\x\\authtoken\\t\\response\\r\\id\\1\\final\\")
    assert {:closed, reply} = read_all(s)
    assert %{"err" => "260"} = GS.parse(reply)
  end

  test "a session that sends nothing is closed" do
    port = start(idle: 300)
    s = connect(port)
    login(s, greeting(s), "pingu")
    assert {:closed, _} = read_all(s)
  end

  test "4 KB without the end of a message closes it" do
    port = start()
    s = connect(port)
    greeting(s)
    :ok = :gen_tcp.send(s, String.duplicate("x", 4_200))
    assert {:closed, ""} = read_all(s)
  end

  test "an IP has 40 connections" do
    port = start()

    open =
      for i <- 1..40 do
        if rem(i, 10) == 0, do: RateLimit.clear()
        s = connect(port)
        greeting(s)
        s
      end

    RateLimit.clear()
    s = connect(port)
    assert {:error, :closed} = :gen_tcp.recv(s, 0, 1_000)
    Enum.each(open, &:gen_tcp.close/1)
  end
end
