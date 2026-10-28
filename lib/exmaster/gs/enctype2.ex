defmodule Exmaster.GS.Enctype2 do
  @moduledoc """
  GameSpy's enctype 2, which encrypts the server lists a master sends to
  Battlefield 1942 clients. Ported from BF1942-Master's Python
  (github.com/Ahrkylien/BF1942-Master, `encryption.py`), itself from Luigi
  Auriemma's enctype2_decoder; the client side is ServerListReadList in
  BF1942's binaries.

  A list goes out as

      header length xor 0xEC (1 byte)
      header, 6 to 14 random bytes; the first ones xor the game's key
      the list and "\\final\\", xor a keystream seeded by the header

  The keystream comes from a table of 326 32-bit words, rewritten as it
  goes, kept in `:atomics`. It is made 63 bytes at a time: the code it is
  ported from regenerates its 64-byte buffer one byte early.
  """
  import Bitwise

  @mask 0xFFFFFFFF
  @final "\\final\\"

  @doc "Encrypts data for a client of the game with key; header is random unless given."
  def encode(data, key, header \\ nil) do
    header = header || :crypto.strong_rand_bytes(6 + :rand.uniform(9) - 1)
    body = xor(data <> @final, keystream(header, byte_size(data) + byte_size(@final)))
    <<bxor(byte_size(header), 0xEC)>> <> xor_key(header, key) <> body
  end

  @doc "Decrypts what encode/3 made: `{:ok, data}` without the `\\final\\`, or `:error`."
  def decode(<<size, rest::binary>>, key) do
    size = bxor(size, 0xEC)

    n = byte_size(rest) - size - byte_size(@final)

    with true <- size >= byte_size(key) and n >= 0,
         <<header::binary-size(^size), body::binary>> <- rest,
         plain = xor(body, keystream(xor_key(header, key), byte_size(body))),
         <<data::binary-size(^n), @final>> <- plain do
      {:ok, data}
    else
      _ -> :error
    end
  end

  def decode(_, _), do: :error

  # The first byte_size(key) bytes of the header, xor the key.
  defp xor_key(header, key) do
    k = byte_size(key)
    <<head::binary-size(^k), tail::binary>> = header
    xor(head, key) <> tail
  end

  defp xor(a, b), do: :crypto.exor(a, binary_part(b, 0, byte_size(a)))

  @doc false
  def keystream(header, len) do
    t = :atomics.new(326, signed: false)
    init_key(t, header)
    blocks = div(len + 62, 63)

    for _ <- 1..blocks//1, into: "" do
      encrypt_block(t)
      words = for i <- 309..324, into: "", do: <<get(t, i)::little-32>>
      binary_part(words, 0, 63)
    end
    |> binary_part(0, len)
  end

  defp get(t, i), do: :atomics.get(t, i + 1)
  defp put(t, i, v), do: :atomics.put(t, i + 1, v)

  # (x << 24 | x >> 8) and (x >> 24 | x << 8), on 32 bits.
  defp ror8(x), do: (x <<< 24 ||| x >>> 8) &&& @mask
  defp rol8(x), do: (x >>> 24 ||| x <<< 8) &&& @mask
  defp mix(t, x), do: bxor(x, get(t, x &&& 0xFF))

  defp init_key(t, src) do
    size = byte_size(src)

    for y <- 0..3 do
      for i <- 0..255, do: put(t, i, (get(t, i) <<< 8) + i)

      Enum.reduce(0..1, y, fn _, pos ->
        Enum.reduce(0..255, pos, fn i, pos ->
          tmp = get(t, i)
          pos = pos + tmp + :binary.at(src, rem(i, size)) &&& 0xFF
          put(t, i, get(t, pos))
          put(t, pos, tmp)
          pos
        end)
      end)
    end

    for i <- 0..255, do: put(t, i, bxor(get(t, i), i))
    seek(t)
  end

  # crypt_seek with n1 and n2 both 0, as the cipher always calls it.
  defp seek(t) do
    {t2, t1, t4} =
      Enum.reduce(0..15, {0, 0, 1}, fn n, {t2, t1, t4} ->
        t2 = t2 + t4 &&& @mask
        t1 = t1 + t2 &&& @mask
        t2 = t2 + t1 &&& @mask
        put(t, n + 256, t2)
        put(t, n + 272, t1)
        put(t, n + 288, t4)
        t3 = mix(t, ror8(t1))
        t2 = mix(t, t2)
        t1 = mix(t, ror8(t3))
        t3 = mix(t, rol8(t2))
        {rol8(t3), t1, t4 <<< 1 &&& @mask}
      end)

    put(t, 304, 16)
    put(t, 305, t2)
    put(t, 306, t1)
    put(t, 307, t4)
    put(t, 308, 0)
  end

  # crypt_encrypt: 16 words of keystream into words 309-324.
  defp encrypt_block(t) do
    state = {get(t, 304), get(t, 305), get(t, 306), get(t, 307)}

    {t2, t1, t3, t5} =
      Enum.reduce(0..15, state, fn i, {t2, t1, t3, t5} ->
        {t2, t1, t3} = refill(t, t2, t1, t3, t5)
        put(t, 309 + i, bxor(t3, t1))
        t2 = t2 - 1
        t1 = bnot(get(t, t2 + 256)) &&& @mask
        t5 = mix(t, get(t, t2 + 272))
        t3 = mix(t, ror8(t1))
        t1 = mix(t, ror8(t3))
        t4 = mix(t, rol8(t5))
        {t2, t1, rol8(t4), (get(t, t2 + 288) <<< 1) + 1 &&& @mask}
      end)

    put(t, 304, t2)
    put(t, 305, t1)
    put(t, 306, t3)
    put(t, 307, t5)
  end

  # The inner loop: while t5 < 65536, step and record the state.
  defp refill(_t, t2, t1, t3, t5) when t5 >= 65_536, do: {t2, t1, t3}

  defp refill(t, t2, t1, t3, t5) do
    t1 = t1 + t5 &&& @mask
    t3 = t3 + t1 &&& @mask
    t1 = t1 + t3 &&& @mask
    put(t, t2 + 256, t1)
    put(t, t2 + 272, t3)
    put(t, t2 + 288, t5)
    t4 = mix(t, ror8(t3))
    t1 = mix(t, t1)
    t3 = mix(t, ror8(t4))
    t4 = mix(t, rol8(t1))
    refill(t, t2 + 1, rol8(t4), t3, t5 <<< 1 &&& @mask)
  end
end
