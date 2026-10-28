defmodule Exmaster.Q3WireTest do
  use ExUnit.Case, async: true

  alias Exmaster.Q3
  import Exmaster.TestHelpers

  test "split_command keeps \\ and / and drops one space or newline" do
    assert Q3.split_command("\xFF\xFF\xFF\xFFheartbeat QuakeArena-1\n") ==
             {:ok, "heartbeat", "QuakeArena-1\n"}

    assert Q3.split_command("\xFF\xFF\xFF\xFFinfoResponse\n\\challenge\\x") ==
             {:ok, "infoResponse", "\\challenge\\x"}

    assert Q3.split_command("\xFF\xFF\xFF\xFFgetserversResponse\\abc") ==
             {:ok, "getserversResponse", "\\abc"}

    assert Q3.split_command("\xFF\xFF\xFF\xFFgetserversExtResponse/abc") ==
             {:ok, "getserversExtResponse", "/abc"}

    assert Q3.split_command("\xFF\xFF\xFF\xFFgetservers") == {:ok, "getservers", ""}
    assert Q3.split_command("getservers 68") == :error
  end

  test "parse_info" do
    assert Q3.parse_info("\\a\\1\\b\\2\n") == %{"a" => "1", "b" => "2"}
    assert Q3.parse_info("a\\1\\a\\3") == %{"a" => "3"}
    assert Q3.parse_info("\\a\\1\\dangling") == %{"a" => "1"}
    assert Q3.parse_info("") == %{}
  end

  test "ints" do
    assert Q3.int("16") == 16
    assert Q3.int("16x") == nil
    assert Q3.int(nil) == nil
    assert Q3.leading_int("3n") == 3
    assert Q3.leading_int("x") == nil
  end

  test "trim" do
    assert Q3.trim(" QuakeArena-1\n\0") == "QuakeArena-1"
  end

  test "valid_name?" do
    assert Q3.valid_name?("QuakeArena-1", 63)
    refute Q3.valid_name?("", 63)
    refute Q3.valid_name?("a b", 63)
    refute Q3.valid_name?("a\\b", 63)
    refute Q3.valid_name?(String.duplicate("a", 64), 63)
    refute Q3.valid_name?("é", 63)
  end

  describe "parse_query" do
    test "anonymous" do
      assert {:ok, q} = Q3.parse_query("68 empty full", false)
      assert %{game: nil, protocol: 68, empty: true, full: true, ipv4: true, ipv6: false} = q
    end

    test "named, DarkPlaces style" do
      assert {:ok, %{game: "Nexuiz", protocol: 3, empty: false, full: true}} =
               Q3.parse_query("Nexuiz 3 full", false)
    end

    test "gametypes" do
      assert {:ok, %{gametype: "4"}} = Q3.parse_query("68 ctf", false)
      assert {:ok, %{gametype: "3"}} = Q3.parse_query("68 team", false)
      assert {:ok, %{gametype: "7"}} = Q3.parse_query("68 gametype=7", false)
    end

    test "getserversExt families" do
      assert {:ok, %{ipv4: true, ipv6: true}} = Q3.parse_query("Quake3Arena 68", true)
      assert {:ok, %{ipv4: false, ipv6: true}} = Q3.parse_query("Quake3Arena 68 ipv6", true)
      # Old ioquake3 builds send no game name.
      assert {:ok, %{game: nil, ipv6: true}} = Q3.parse_query("68 empty ipv6", true)
      # getservers is IPv4 only, whatever it says.
      assert {:ok, %{ipv4: true, ipv6: false}} = Q3.parse_query("68 ipv6", false)
    end

    test "bad" do
      assert Q3.parse_query("", false) == :error
      assert Q3.parse_query("Quake3Arena", false) == :error
      assert Q3.parse_query("Quake3Arena x", false) == :error
    end
  end

  describe "encode_list" do
    test "an empty list is one packet with EOT" do
      assert Q3.encode_list([], false) == ["\xFF\xFF\xFF\xFFgetserversResponse\\EOT\0\0\0"]
    end

    test "entries" do
      [p] = Q3.encode_list([{{1, 2, 3, 4}, 2048}, {{0, 0, 0, 0, 0, 0, 0, 1}, 27960}], true)

      assert p ==
               "\xFF\xFF\xFF\xFFgetserversExtResponse\\" <>
                 <<1, 2, 3, 4, 8, 0>> <>
                 "/" <> <<0::120, 1, 27960::16>> <> "\\EOT\0\0\0"

      [p] = Q3.encode_list([{{0, 0, 0, 0, 0, 0, 0, 1}, 27960}], false)
      assert p == "\xFF\xFF\xFF\xFFgetserversResponse\\EOT\0\0\0"
    end

    test "long lists are split, every packet with the header, EOT on the last" do
      addrs = for i <- 1..500, do: {{10, 0, div(i, 256), rem(i, 256)}, 27960}
      packets = Q3.encode_list(addrs, false)
      assert length(packets) > 1
      assert Enum.all?(packets, &(byte_size(&1) <= 1400))
      assert Enum.all?(packets, &String.starts_with?(&1, "\xFF\xFF\xFF\xFFgetserversResponse\\"))
      assert decode_q3_lists(packets) == addrs
    end
  end
end
