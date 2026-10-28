defmodule Exmaster.UE2Test do
  use ExUnit.Case, async: true

  alias Exmaster.UE2

  # What a UT2004 3369 server sent, captured on loopback: its challenge
  # response, with no CD key installed, and a heartbeat.
  @hello Base.decode16!(
           "21396566633331346236353233376435643634366531623831373337326166633600213962663131646336623865313737316562366466333830646530613963366363000C5554324B3453455256455200290D00000604696E7400FFFFFFFF00"
         )
  @heartbeat Base.decode16!(
               "010000000000004D1E0000000000000E65786D61737465722074657374000A444D2D52616E6B696E000C7844656174684D6174636800000000001000000000000000000000000230000E0B5365727665724D6F6465000A646564696361746564000A41646D696E4E616D6500000B41646D696E456D61696C00000E53657276657256657273696F6E000533333639000A47616D655374617473000646616C7365000E4D6178537065637461746F7273000232000B4D696E506C6179657273000230000D456E6454696D6544656C61790005342E3030000A476F616C53636F726500033235000A54696D654C696D697400033230000D5472616E736C6F6361746F72000646616C7365000B576561706F6E53746179000554727565000D466F7263655265737061776E000646616C736500086D757461746F72000A444D4D757461746F720000"
             )

  defp bin(iodata), do: IO.iodata_to_binary(iodata)

  test "compact indexes" do
    for {n, wire} <- [
          {0, <<0>>},
          {1, <<1>>},
          {63, <<63>>},
          {64, <<0x40, 1>>},
          {-1, <<0x81>>},
          {-64, <<0xC0, 1>>},
          {300, <<0x6C, 4>>},
          {8_191, <<0x7F, 0x7F>>},
          {8_192, <<0x40, 0x80, 1>>}
        ] do
      assert UE2.compact(n) == wire
      assert UE2.decode_compact(wire <> "x") == {:ok, n, "x"}
    end

    for n <- [1_048_576, 134_217_727, 134_217_728, 2_147_483_647, -2_147_483_647],
        do: assert(UE2.decode_compact(UE2.compact(n)) == {:ok, n, ""})

    assert UE2.decode_compact(<<0x40>>) == :error
    assert UE2.decode_compact("") == :error
  end

  test "strings: Latin-1, UTF-16 when it doesn't fit, empty" do
    assert bin(UE2.string("DM-Rankin")) == <<10, "DM-Rankin", 0>>
    assert bin(UE2.string("")) == <<1, 0>>
    assert bin(UE2.string("blåbær")) == <<7, "bl", 0xE5, "b", 0xE6, "r", 0>>
    assert bin(UE2.string("€")) == <<0x82, 0xAC, 0x20, 0, 0>>

    for s <- ["exmaster test", "blåbær", "€ and 𝄞", "", <<0x1B, "colour">>],
        do: assert(UE2.decode_string(bin(UE2.string(s)) <> "x") == {:ok, s, "x"})

    # Empty, as UT2004 sends AdminName: no NUL at all.
    assert UE2.decode_string(<<0, "x">>) == {:ok, "", "x"}
    assert UE2.decode_string(<<5, "abc">>) == :error
    assert UE2.decode_string(<<0x82, 0, 0xD8, 0, 0>>) == :error
  end

  test "a server's challenge response" do
    assert UE2.parse_hello(@hello) == {:ok, "UT2K4SERVER", 3369}
    assert UE2.parse_hello(binary_part(@hello, 0, 70)) == :error
  end

  test "a UT2004 heartbeat" do
    <<1, payload::binary>> = @heartbeat
    assert {:ok, hb} = UE2.parse_heartbeat(payload)

    assert Map.delete(hb, :rules) == %{
             port: 7757,
             query_port: 0,
             hostname: "exmaster test",
             map: "DM-Rankin",
             gametype: "xDeathMatch",
             players: 0,
             max_players: 16,
             skill: "0"
           }

    assert length(hb.rules) == 14
    assert {"AdminName", ""} in hb.rules
    assert {"mutator", "DMMutator"} in hb.rules
    assert UE2.mutators(hb) == ["dmmutator"]

    values = UE2.filter_values(hb)

    assert Map.take(values, ~w(gametype currentplayers freespace password stats nobots
             weaponstay transloc serverversion nomutators)) == %{
             "gametype" => {"xdeathmatch", 0},
             "currentplayers" => {"0", 0},
             "freespace" => {"1", 1},
             "password" => {"false", 0},
             "stats" => {"false", 0},
             "nobots" => {"true", 0},
             "weaponstay" => {"true", 0},
             "transloc" => {"false", 0},
             "serverversion" => {"3369", 3369},
             "nomutators" => {"false", 0}
           }

    # The latest version and standard.
    assert UE2.flags(values, UE2.mutators(hb)) == 0b0100100

    for n <- [10, 100, 200, byte_size(payload) - 20],
        do: assert(UE2.parse_heartbeat(binary_part(payload, 0, n)) == :error)
  end

  test "flags" do
    values = %{
      "gamepassword" => {"true", 0},
      "gamestats" => {"true", 0},
      "servermode" => {"non-dedicated", 0}
    }

    assert UE2.flags(values, ["mutinstagib", "mututclassic"]) == 0b1111011
    assert UE2.flags(Map.put(values, "serverversion", {"3369", 3369}), []) == 0b0101111
    assert UE2.flags(%{}, []) == 0b0100000
  end

  # A server that sends as much as a frame takes: 64 rules of 480 bytes,
  # one of them a 32,000-digit number, and long names.
  test "what a server is filtered by is bounded" do
    long = String.duplicate("x", 480)

    hb = %{
      hostname: String.duplicate("h", 4_000),
      map: long,
      gametype: long,
      skill: long,
      players: 0,
      max_players: 16,
      rules:
        [{"GoalScore", String.duplicate("9", 32_000)}] ++
          for(i <- 1..63, do: {"Rule#{i}" <> long, long}) ++
          for(_ <- 1..40, do: {"mutator", "Mut" <> long})
    }

    values = UE2.filter_values(hb)
    assert map_size(values) <= 32 + 15
    assert Enum.all?(values, fn {k, {t, _}} -> byte_size(k) <= 32 and byte_size(t) <= 64 end)

    assert values["goalscore"] ==
             {String.duplicate("9", 64), String.to_integer(String.duplicate("9", 64))}

    assert :erlang.external_size(values) < 6_000

    mutators = UE2.mutators(hb)
    assert length(mutators) == 16 and Enum.all?(mutators, &(byte_size(&1) == 64))
  end

  test "cutting keeps whole characters" do
    assert UE2.cut("blåbær", 3) == "bl"
    assert UE2.cut("blåbær", 4) == "blå"
    assert UE2.cut("€uro", 2) == ""
    assert UE2.cut("short", 64) == "short"
  end

  # As qstat asks, with a gametype and its "not empty", and with a
  # mutator it mustn't run.
  test "list queries" do
    query =
      <<3, 9, "gametype", 0, 12, "xDeathMatch", 0, 0, 15, "currentplayers", 0, 2, "0", 0, 4, 8,
        "mutator", 0, 12, "MutInstaGib", 0, 4>>

    assert UE2.parse_query(query) ==
             {:ok,
              [
                {"gametype", "xdeathmatch", :eq, 0},
                {"currentplayers", "0", :gt, 0},
                {"mutator", "mutinstagib", :gt, 0}
              ]}

    # A comparison it doesn't know is "disabled", left out.
    assert UE2.parse_query(<<1, 2, "x", 0, 2, "y", 0, 6>>) == {:ok, []}
    assert UE2.parse_query(<<0>>) == {:ok, []}
    assert UE2.parse_query(<<2, 2, "x", 0, 2, "y", 0, 0>>) == :error
    assert UE2.parse_query("") == :error

    # At most 32 filters, and values cut as a server's are.
    one = <<2, "x", 0, 2, "1", 0, 0>>
    assert {:ok, [_ | _]} = UE2.parse_query(<<32, :binary.copy(one, 32)::binary>>)
    assert UE2.parse_query(<<33, :binary.copy(one, 33)::binary>>) == :error

    digits = String.duplicate("7", 1_000)

    assert UE2.parse_query(
             IO.iodata_to_binary([1, UE2.string("goalscore"), UE2.string(digits), 4])
           ) ==
             {:ok,
              [
                {"goalscore", String.duplicate("7", 64), :gt,
                 String.to_integer(String.duplicate("7", 64))}
              ]}
  end

  test "filters" do
    entry = %{
      filters: %{
        "gametype" => {"xdeathmatch", 0},
        "currentplayers" => {"3", 3},
        "password" => {"false", 0}
      },
      mutators: ["mutinstagib"]
    }

    # Through parse_query, as a client's query comes.
    pass = fn filters ->
      query =
        Enum.map(filters, fn {k, v, op} ->
          [UE2.string(k), UE2.string(v), Map.fetch!(%{eq: 0, ne: 1, lt: 2, le: 3, gt: 4}, op)]
        end)

      {:ok, filters} = UE2.parse_query(IO.iodata_to_binary([length(filters), query]))
      UE2.matches?(entry, filters)
    end

    assert pass.([])
    assert pass.([{"gametype", "XDEATHMATCH", :eq}])
    refute pass.([{"gametype", "xCTFGame", :eq}])
    assert pass.([{"gametype", "xCTFGame", :ne}])
    assert pass.([{"currentplayers", "0", :gt}, {"currentplayers", "3", :le}])
    refute pass.([{"currentplayers", "3", :lt}])
    assert pass.([{"password", "false", :eq}])
    # Keys are cut as a server's are.
    long = "ThisRuleNameIsLongerThanThirtyTwoBytes"

    {:ok, [{key, _, _, _}]} =
      UE2.parse_query(IO.iodata_to_binary([1, UE2.string(long), UE2.string("6"), 0]))

    assert key == long |> binary_part(0, 32) |> String.downcase()

    assert Map.has_key?(
             UE2.filter_values(%{
               hostname: "",
               map: "",
               gametype: "",
               skill: "",
               players: 0,
               max_players: 0,
               rules: [{long, "5"}]
             }),
             key
           )

    # Keys the server doesn't have match.
    assert pass.([{"nosuchkey", "x", :eq}])
    assert pass.([{"mutator", "MutInstaGib", :eq}])
    refute pass.([{"mutator", "MutInstaGib", :gt}])
    assert pass.([{"mutator", "MutUTClassic", :gt}])
    refute pass.([{"mutator", "MutUTClassic", :eq}])
  end

  test "a list entry" do
    entry = %{
      query_port: 7758,
      hostname: "exmaster test",
      map: "DM-Rankin",
      gametype: "xDeathMatch",
      clients: 3,
      max_clients: 16,
      flags: 0b0100100,
      skill: "0"
    }

    assert bin(UE2.encode_entry({{198, 51, 100, 7}, 7757}, entry)) ==
             <<198, 51, 100, 7, 7757::little-16, 7758::little-16, 14, "exmaster test", 0, 10,
               "DM-Rankin", 0, 12, "xDeathMatch", 0, 3, 16, 0b0100100::little-32, 2, "0", 0>>

    assert bin(UE2.frame("abc")) == <<3, 0, 0, 0, "abc">>
  end
end
