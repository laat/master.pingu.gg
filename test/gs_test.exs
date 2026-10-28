defmodule Exmaster.GSTest do
  use ExUnit.Case, async: true

  alias Exmaster.GS
  alias Exmaster.GS.Enctype2

  # The reply of a Battlefield 1942 server (Linux, 1.612) to
  # \\info\\\\secure\\AtjJBQLjIYaWFitR, captured on 2026-10-28.
  @info "\\averageFPS\\0\\content_check\\1\\dedicated\\2\\gameId\\bf1942\\gamemode\\pre\\gametype\\conquest\\hostname\\exmaster test\\hostport\\14567\\mapId\\BF1942\\mapname\\berlin\\maxplayers\\16\\numplayers\\0\\password\\0\\reservedslots\\0\\roundTime\\-1\\roundTimeRemain\\-1\\status\\3\\sv_punkbuster\\0\\tickets1\\80\\tickets2\\100\\unpure_mods\\\\version\\v1.612\\validate\\vWcYUi1PGU/Wgnf54XqrRwAA\\weight\\10\\final\\\\queryid\\2.1"

  test "parse" do
    info = GS.parse(@info)
    assert info["hostname"] == "exmaster test"
    assert info["unpure_mods"] == ""
    assert info["final"] == ""
    assert info["queryid"] == "2.1"

    assert GS.parse("\\heartbeat\\23000\\gamename\\bfield1942") == %{
             "heartbeat" => "23000",
             "gamename" => "bfield1942"
           }

    assert GS.parse("\\basic\\\\secure\\MASTER") == %{"basic" => "", "secure" => "MASTER"}
    assert GS.parse("junk") == %{}
  end

  test "validate, as GameSpy's servers answer \\secure\\" do
    # Doom 3's key, from gsmsalg's own example.
    assert GS.validate("ABCDEF", "kbeafe") == "iJbjNilG"
    # Three BF1942 servers on the Internet, and the one above.
    assert GS.validate("ABCDEF", "HpWx9z") == "vXrDWjx4"
    assert GS.validate("AtjJBQLjIYaWFitR", "HpWx9z") == GS.parse(@info)["validate"]
  end

  test "lists" do
    addrs = [{{1, 2, 3, 4}, 23_000}, {{10, 0, 0, 1}, 65_535}]
    assert GS.encode_list(addrs) == <<1, 2, 3, 4, 0x59, 0xD8, 10, 0, 0, 1, 0xFF, 0xFF>>
    assert GS.encode_text_list(addrs) == "\\ip\\1.2.3.4:23000\\ip\\10.0.0.1:65535"
  end

  # {key, header, plain, encrypted}, from BF1942-Master's encoder
  # (github.com/Ahrkylien/BF1942-Master, encryption.py) with a fixed header.
  @enctype2 [
    {
      "HpWx9z",
      Base.decode16!(
        "0763c80102030405",
        case: :lower
      ),
      Base.decode16!(
        "0102030459d80a00000159d9",
        case: :lower
      ),
      Base.decode16!(
        "e44f139f793b790405b93ad1a0402b3707fd9fe69e9eb67b16e4364d",
        case: :lower
      )
    },
    {
      "HpWx9z",
      Base.decode16!(
        "c8c9cacbcccdcecfd0d1d2d3d4d5",
        case: :lower
      ),
      Base.decode16!(
        "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186" <>
          "abd0f51a3f6489aed3f81d42678cb1d6fb20456a8fb4d9fe23486d92b7dc0126" <>
          "4b7095badf04294e7398bde2072c51769bc0e50a2f54799ec3e80d32577ca1c6" <>
          "eb10355a7fa4c9ee13385d82a7ccf1163b6085aacff4193e6388add2f71c4166" <>
          "8bb0d5fa1f44698eb3d8fd22476c91b6db00254a6f94b9de03284d7297bce106" <>
          "2b50759abfe4092e53789dc2e70c31567ba0c5ea0f34597ea3c8ed12375c81a6" <>
          "cbf0153a5f84a9cef3183d6287acd1f61b40658aafd4f91e43688db2d7fc2146" <>
          "6b90b5daff24496e93b8dd02274c7196bbe0052a4f7499bee3082d52779cc1e6" <>
          "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186" <>
          "abd0f51a3f6489aed3f81d42678cb1d6fb20456a8fb4d9fe23486d92b7dc0126" <>
          "4b7095badf04294e7398bde2072c51769bc0e50a2f54799ec3e80d32577ca1c6" <>
          "eb10355a7fa4c9ee13385d82a7ccf1163b6085aacff4193e6388add2f71c4166" <>
          "8bb0d5fa1f44698eb3d8fd22476c91b6db00254a6f94b9de03284d7297bce106" <>
          "2b50759abfe4092e53789dc2e70c31567ba0c5ea0f34597ea3c8ed12375c81a6" <>
          "cbf0153a5f84a9cef3183d6287acd1f61b40658aafd4f91e43688db2d7fc2146" <>
          "6b90b5daff24496e93b8dd02274c7196bbe0052a4f7499bee3082d52779cc1e6" <>
          "0b30557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186" <>
          "abd0f51a3f6489aed3f81d42678cb1d6fb20456a8fb4d9fe23486d92b7dc0126" <>
          "4b7095badf04294e7398bde2072c51769bc0e50a2f54799e",
        case: :lower
      ),
      Base.decode16!(
        "e280b99db3f5b7cecfd0d1d2d3d4d58a67aa43ab0fb52a517ecfe8d4259841e4" <>
          "6d459542c06d8f1b15fe6bb91643b6ffd82ba42ce653cffc0fd41c71a6c6204a" <>
          "5cb5f7aff6a574ac254104d5606f33694fd490103be5f770e4ca87b36a4c6084" <>
          "e7bbdb4449dfcefabdebb5cf7ac0a3428dd37077f56467786ed6c5a4acf2f789" <>
          "4d599af8100a626897ec4b090102d4a01905ec462f1c767ea233675db1269543" <>
          "c992b34d268aa48eea32626c004bd8b7acae5add4c32ffffed849d752e125a68" <>
          "c1c119ba94f8ec4390d9558197e34219bdff13844c77f364428b8bb46c9b4ee6" <>
          "2c27a5f586e133fa53a8b204e61d54ed1caa0cb2ffe19e887d3515e42f3ec571" <>
          "d28bb10a8da74a89a0f4b82d3b62ea49b9dafb90c6935306174b3067814d2ee0" <>
          "7060c6aa955aab17dd098d4a39709a31ecf25b4be92a3202f2e2ea0939b05fea" <>
          "88afcc359b78c1643755da805c6e72ee383e4ee4bdd4da66f0e3ee518f943dda" <>
          "59d2f2c545d744989e6099d7176073f1755e5a2bf80a5c0ca97f0a203f39034a" <>
          "d41ee767048300ee95b60088aa840340b0168483751b8d8f782c628d1cd766b2" <>
          "fd93a4fab58e80e783fe02be165b3b8e5937f8b33ad3bf4b53d4defcbb4045f5" <>
          "506e0717764ceda2cce10e4504d92e2537714920a95335cd1e042322076d39d4" <>
          "6c59b34308df705b9b55509c91be3977eebf18bff8ed63ddf815f127f00a3d11" <>
          "027e6b4c51a5fa8d86d222b32e4036c38638f745218fa097550833cb30b375fb" <>
          "71de0c7eb4b86e9112e0be7ca3e8c8e0e335b3fbdff4debea391e36d576c5557" <>
          "75e68a4257e107b363af11fe11cf23b5ab4acf24db636e8dc4d9f1811ad2e8cb" <>
          "36924172fce29e9110d12bb37f3d",
        case: :lower
      )
    },
    {
      "HpWx9z",
      Base.decode16!(
        "000000000000",
        case: :lower
      ),
      "",
      Base.decode16!(
        "ea48705778397af11aa74900469a",
        case: :lower
      )
    }
  ]

  test "enctype 2 matches BF1942-Master's" do
    for {key, header, plain, encrypted} <- @enctype2 do
      assert Enctype2.encode(plain, key, header) == encrypted
      assert Enctype2.decode(encrypted, key) == {:ok, plain}
    end
  end

  test "enctype 2 round trip, random headers" do
    for n <- [0, 1, 62, 63, 64, 126, 127, 6 * 1000] do
      data = :crypto.strong_rand_bytes(n)
      assert Enctype2.decode(Enctype2.encode(data, "HpWx9z"), "HpWx9z") == {:ok, data}
    end

    assert Enctype2.decode("", "HpWx9z") == :error
    assert Enctype2.decode(<<0xEC>>, "HpWx9z") == :error
    assert Enctype2.decode(Enctype2.encode("x", "HpWx9z"), "other!") == :error
  end
end
