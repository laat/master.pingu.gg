defmodule Exmaster.Q3.Challenge do
  @moduledoc """
  The challenges in `getinfo`, which a server must echo in its
  `infoResponse`. They are stateless, like TCP SYN cookies:

      challenge = class char <> base89(first 8 bytes of
                  HMAC-SHA256(key, address, listener, time bucket, class))

  A heartbeat from an address the master doesn't list gets a `getinfo` with
  a challenge and stores nothing, so forged heartbeats can't fill memory.
  The class says how to classify the server when it answers; it travels in
  the first character and the MAC covers it. The listener is the local
  address and port the challenge went out from, so it only checks there. The key is random per
  boot, kept in `:persistent_term`.

  A challenge is accepted in its own time bucket and the next one, so it
  lives between one and two TTLs. Its characters are ASCII 33-126 without
  `\\ / ; " %`, as dpmaster's are.
  """

  @alphabet for c <- 33..126, c not in [?\\, ?/, ?;, ?", ?%], into: "", do: <<c>>
  @base byte_size(@alphabet)
  # One class character and ten MAC characters: 89^10 > 2^64.
  @length 11

  def alphabet, do: @alphabet

  def init_key, do: :persistent_term.put({__MODULE__, :key}, :crypto.strong_rand_bytes(32))

  defp key, do: :persistent_term.get({__MODULE__, :key})

  @doc "The challenge for addr, with class (0..88), sent through the listener bound to via."
  def issue(addr, class, via, now, ttl, key \\ key()) when class in 0..(@base - 1)//1 do
    make(key, addr, class, via, Integer.floor_div(now, ttl))
  end

  @doc "Checks a challenge that came back from addr on listener via: `{:ok, class}` or `:error`."
  def check(addr, challenge, via, now, ttl, key \\ key())

  def check(addr, <<c, _::binary>> = challenge, via, now, ttl, key)
      when byte_size(challenge) == @length do
    with {class, 1} <- :binary.match(@alphabet, <<c>>),
         bucket = Integer.floor_div(now, ttl),
         true <-
           Enum.any?(
             [bucket, bucket - 1],
             &:crypto.hash_equals(make(key, addr, class, via, &1), challenge)
           ) do
      {:ok, class}
    else
      _ -> :error
    end
  end

  def check(_addr, _challenge, _via, _now, _ttl, _key), do: :error

  defp make(key, addr, class, via, bucket) do
    addr = Exmaster.Addr.to_binary(addr)
    via = Exmaster.Addr.to_binary(via)
    data = [byte_size(addr), addr, byte_size(via), via, <<bucket::signed-64, class>>]
    <<v::64, _::binary>> = :crypto.mac(:hmac, :sha256, key, data)
    digits(v, @length - 1, [:binary.at(@alphabet, class)])
  end

  defp digits(_v, 0, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  defp digits(v, n, acc),
    do: digits(div(v, @base), n - 1, [:binary.at(@alphabet, rem(v, @base)) | acc])
end
