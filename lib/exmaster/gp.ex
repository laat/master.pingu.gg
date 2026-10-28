defmodule Exmaster.GP do
  @moduledoc """
  The login of GameSpy Presence's connection manager (gpcm), as Unreal
  Tournament 3 speaks it over TCP 29900 before its server will heartbeat
  QR2. `Exmaster.GP.Server` runs it; see `docs/qr2.md`.

  Messages are `\\key\\value...` ending in `\\final\\`. The server speaks
  first:

  | From | Message |
  |---|---|
  | master | `\\lc\\1\\challenge\\<10 letters>\\id\\1\\final\\` |
  | client | `\\login\\\\challenge\\<32 characters>\\uniquenick\\<name>\\partnerid\\0\\response\\<md5>\\...\\id\\1\\final\\` |
  | master | `\\lc\\2\\sesskey\\<n>\\proof\\<md5>\\userid\\<n>\\profileid\\<n>\\uniquenick\\<name>\\lt\\<ticket>\\id\\1\\final\\`, or `\\error\\` |

  With `h`, the MD5 of the password in hex, and 48 spaces between, the
  client's response is the MD5 of h, the spaces, the user, its challenge,
  the master's and h again; the master's proof the same with the
  challenges swapped. The client checks the proof, so the master has to
  know h: there is one password, public, for every name.
  """

  @spaces String.duplicate(" ", 48)

  @doc "The master's greeting, with its challenge."
  def greeting(challenge), do: "\\lc\\1\\challenge\\#{challenge}\\id\\1\\final\\"

  @doc """
  The user a login hashes, as the client builds it: its uniquenick, or
  nick@email, after its partner id and `@` unless that is 0 (GameSpy's).
  `nil` for a login by token, which this master doesn't take.
  """
  def user(login) do
    partner = if login["partnerid"] in [nil, "", "0"], do: "", else: login["partnerid"] <> "@"

    cond do
      Map.has_key?(login, "authtoken") -> nil
      login["uniquenick"] not in [nil, ""] -> partner <> login["uniquenick"]
      login["user"] not in [nil, ""] -> partner <> login["user"]
      true -> nil
    end
  end

  @doc "The MD5 of a password, in hex, as the hashes take it."
  def password_hash(password), do: md5(password)

  @doc "The response a client sends for user, under the password with hash h."
  def response(h, user, client_challenge, server_challenge),
    do: md5([h, @spaces, user, client_challenge, server_challenge, h])

  @doc "The master's proof that it knows the password, which the client checks."
  def proof(h, user, client_challenge, server_challenge),
    do: md5([h, @spaces, user, server_challenge, client_challenge, h])

  @doc """
  A profile's id, from its name, case aside: the first 31 bits of its
  SHA-256, plus one, so every node gives a name the same one.
  """
  def profile_id(name) do
    <<_::1, n::31, _::binary>> = :crypto.hash(:sha256, String.downcase(name))
    n + 1
  end

  @doc """
  The reply to a login that the password checks out for, then the buddy
  and block lists, empty, which the SDK waits for before it counts itself
  logged in. id is the login message's.
  """
  def logged_in(name, profile_id, proof, ticket, id) do
    "\\lc\\2\\sesskey\\#{profile_id}\\proof\\#{proof}\\userid\\#{profile_id}" <>
      "\\profileid\\#{profile_id}\\uniquenick\\#{name}\\lt\\#{ticket}\\id\\#{id || "1"}\\final\\" <>
      "\\bdy\\0\\list\\\\final\\\\blk\\0\\list\\\\final\\"
  end

  @doc "An error that ends the connection, as GameSpy's codes go."
  def error(code, message, id),
    do: "\\error\\\\err\\#{code}\\fatal\\\\errmsg\\#{message}\\id\\#{id || "1"}\\final\\"

  defp md5(data), do: :crypto.hash(:md5, data) |> Base.encode16(case: :lower)
end
