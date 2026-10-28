defmodule Exmaster.SB.Crypt do
  @moduledoc """
  The stream cipher GameSpy's server browsing encrypts lists with, which
  aluigi calls enctypeX and GameSpy's SDK GOACrypt (`sb_crypt.c`): Michael
  Paul Johnson's 1993 cipher, a 256-card deck reshuffled with every byte.

  The deck lives in `:atomics`, as `Exmaster.GS.Enctype2`'s table does: a
  list is encrypted byte by byte, and every byte moves four cards. A state
  belongs to the process that made it.
  """
  import Bitwise

  defstruct [:cards, :rotor, :ratchet, :avalanche, :last_plain, :last_cipher]

  @doc "A state keyed with key (1 to 255 bytes)."
  def init(key) when byte_size(key) in 1..255 do
    cards = :atomics.new(256, signed: false)
    for i <- 0..255, do: put(cards, i, i)

    {rsum, _} =
      Enum.reduce(255..0//-1, {0, 0}, fn i, {rsum, keypos} ->
        {swap_with, rsum, keypos} = keyrand(cards, i, key, rsum, keypos)
        t = card(cards, i)
        put(cards, i, card(cards, swap_with))
        put(cards, swap_with, t)
        {rsum, keypos}
      end)

    %__MODULE__{
      cards: cards,
      rotor: card(cards, 1),
      ratchet: card(cards, 3),
      avalanche: card(cards, 5),
      last_plain: card(cards, 7),
      last_cipher: card(cards, rsum)
    }
  end

  # A card position from 0 to limit, drawn with the key.
  defp keyrand(_cards, 0, _key, rsum, keypos), do: {0, rsum, keypos}

  defp keyrand(cards, limit, key, rsum, keypos) do
    mask = mask(limit, 1)
    draw(cards, limit, mask, key, rsum, keypos, 0)
  end

  defp mask(limit, m) when m < limit, do: mask(limit, (m <<< 1) + 1)
  defp mask(_limit, m), do: m

  defp draw(cards, limit, mask, key, rsum, keypos, tries) do
    rsum = card(cards, rsum) + :binary.at(key, keypos) &&& 0xFF
    keypos = keypos + 1

    {rsum, keypos} =
      if keypos >= byte_size(key),
        do: {rsum + byte_size(key) &&& 0xFF, 0},
        else: {rsum, keypos}

    u = mask &&& rsum
    # Rare long loops are cut short.
    u = if tries + 1 > 11, do: rem(u, limit), else: u

    if u > limit,
      do: draw(cards, limit, mask, key, rsum, keypos, tries + 1),
      else: {u, rsum, keypos}
  end

  @doc "Encrypts data: `{ciphertext, state}`."
  def encrypt(state, data), do: run(state, data, :encrypt)

  @doc "Decrypts data: `{plaintext, state}`."
  def decrypt(state, data), do: run(state, data, :decrypt)

  defp run(state, data, way) do
    {out, state} =
      for <<b <- data>>, reduce: {[], state} do
        {out, s} ->
          {c, s} = byte(s, b, way)
          {[c | out], s}
      end

    {out |> Enum.reverse() |> :erlang.list_to_binary(), state}
  end

  defp byte(s, b, way) do
    cards = s.cards
    ratchet = s.ratchet + card(cards, s.rotor) &&& 0xFF
    rotor = s.rotor + 1 &&& 0xFF
    swaptemp = card(cards, s.last_cipher)
    put(cards, s.last_cipher, card(cards, ratchet))
    put(cards, ratchet, card(cards, s.last_plain))
    put(cards, s.last_plain, card(cards, rotor))
    put(cards, rotor, swaptemp)
    avalanche = s.avalanche + card(cards, swaptemp) &&& 0xFF

    out =
      b
      |> bxor(card(cards, card(cards, avalanche) + card(cards, rotor) &&& 0xFF))
      |> bxor(
        card(
          cards,
          card(
            cards,
            card(cards, s.last_plain) + card(cards, s.last_cipher) + card(cards, ratchet) &&& 0xFF
          )
        )
      )

    {plain, cipher} = if way == :encrypt, do: {b, out}, else: {out, b}

    {out,
     %{
       s
       | rotor: rotor,
         ratchet: ratchet,
         avalanche: avalanche,
         last_plain: plain,
         last_cipher: cipher
     }}
  end

  defp card(cards, i), do: :atomics.get(cards, i + 1)
  defp put(cards, i, v), do: :atomics.put(cards, i + 1, v)
end
