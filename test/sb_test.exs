defmodule Exmaster.SBTest do
  use ExUnit.Case, async: true

  alias Exmaster.SB
  alias Exmaster.SB.Crypt

  @plain "The quick brown fox jumps over the lazy dog, twice: The quick brown fox."

  # Encrypted here, and decrypted back by .gameservers/query.py's
  # GOACrypt, which decrypts OpenSpy's lists.
  @cipher Base.decode16!(
            "20519E91B0CCD5428F71D5DFB963C0028BD2047D007E451C31C651C2D8A16CF167E665A38DF28F76987730B6DB4A85FE62E0F749DACE9190089BA87341F9C07F652F06A198DDCCA2"
          )

  test "the cipher, against a known answer" do
    {cipher, _} = Crypt.encrypt(Crypt.init("exmaster"), @plain)
    assert cipher == @cipher
    {plain, _} = Crypt.decrypt(Crypt.init("exmaster"), @cipher)
    assert plain == @plain

    # A stream: in parts, the same.
    {a, state} = Crypt.encrypt(Crypt.init("exmaster"), binary_part(@plain, 0, 10))
    {b, _} = Crypt.encrypt(state, binary_part(@plain, 10, byte_size(@plain) - 10))
    assert a <> b == @cipher
  end

  test "the crypt header, and the key the client makes of it" do
    fixed = fn n -> :binary.copy(<<0xAB>>, n) end
    {header, state} = SB.crypt(<<1, 2, 3, 4, 5, 6, 7, 8>>, "h2P9dJ", fixed)

    # 10 xor 0xEC, two bytes of options (none), 8 random, 25 xor 0xEA, 25 more.
    assert header == <<0xE6, 0, 0>> <> fixed.(8) <> <<0xF3>> <> fixed.(25)
    # As query.py decrypts it, from the header.
    assert {<<0x0B, 0xAE, 0xA8>>, _} = Crypt.encrypt(state, "abc")
  end

  defp request(game, from, fields, options, extra \\ "") do
    <<0, 1, 3, 0::32, game::binary, 0, from::binary, 0, 1, 2, 3, 4, 5, 6, 7, 8, "gamever='v1.21'",
      0, fields::binary, 0, options::32, extra::binary>>
  end

  test "list requests" do
    assert {:ok,
            %{
              game: "bfvietnam",
              from: "gslive",
              challenge: <<1, 2, 3, 4, 5, 6, 7, 8>>,
              fields: ["hostname", "numplayers"],
              list?: true,
              source_ip: nil,
              max: nil
            }} = SB.parse_request(request("bfvietnam", "gslive", "\\hostname\\numplayers", 0))

    # No list (2), another source IP (8), at most 10 (128, little-endian).
    assert {:ok, %{list?: false, source_ip: {198, 51, 100, 7}, max: 10, fields: []}} =
             SB.parse_request(
               request(
                 "bfvietnam",
                 "bfvietnam",
                 "",
                 2 + 8 + 128,
                 <<198, 51, 100, 7, 10::little-32>>
               )
             )

    assert SB.parse_request(request("bfvietnam", "bfvietnam", "", 8)) == :error
    assert SB.parse_request(<<1, 1, 3, 0::32, "x", 0>>) == :error
    assert SB.parse_request(<<0, 1, 3, 0::32, "bfvietnam", 0, "x", 0, 1, 2>>) == :error
  end

  test "a list" do
    servers = [
      # On the game's port, with no local address.
      {{{198, 51, 100, 1}, 23_000},
       %{local_ip: nil, local_port: nil, fields: %{"hostname" => "one", "numplayers" => "3"}}},
      # On another, with a local address on another port too.
      {{{198, 51, 100, 2}, 23_100},
       %{local_ip: {192, 168, 1, 26}, local_port: 23_101, fields: %{"hostname" => "two"}}}
    ]

    assert IO.iodata_to_binary(SB.encode_list(["hostname", "numplayers"], servers, 23_000)) ==
             <<2, 0, "hostname", 0, 0, "numplayers", 0, 0>> <>
               <<64, 198, 51, 100, 1, 0xFF, "one", 0, 0xFF, "3", 0>> <>
               <<64 + 16 + 2 + 32, 198, 51, 100, 2, 23_100::16, 192, 168, 1, 26, 23_101::16, 0xFF,
                 "two", 0, 0xFF, 0>> <>
               <<0, 0xFF, 0xFF, 0xFF, 0xFF>>

    assert SB.head({203, 0, 113, 9}, 23_000) == <<203, 0, 113, 9, 23_000::16>>
    assert SB.error({203, 0, 113, 9}, "no") == <<203, 0, 113, 9, 0xFF, 0xFF, "no", 0>>
  end
end
