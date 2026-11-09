defmodule Exmaster.Addr do
  @moduledoc """
  Addresses are `{ip, port}` with the IP as `:inet` has it: a 4-tuple for
  IPv4, an 8-tuple for IPv6. IPv4 addresses that come in on a dual-stack
  socket as IPv4-mapped IPv6 are turned back into IPv4 first, so a server
  has one address whichever socket it talks to.
  """
  import Bitwise

  @type t :: {:inet.ip_address(), :inet.port_number()}

  def unmap({{0, 0, 0, 0, 0, 0xFFFF, a, b}, port}),
    do: {{a >>> 8, a &&& 255, b >>> 8, b &&& 255}, port}

  def unmap(addr), do: addr

  @doc "The IPv4-mapped IPv6 address, for sending to IPv4 from a dual-stack socket."
  def map_v4({a, b, c, d}), do: {0, 0, 0, 0, 0, 0xFFFF, a <<< 8 ||| b, c <<< 8 ||| d}

  def ipv4?({{_, _, _, _}, _}), do: true
  def ipv4?(_), do: false

  @doc """
  Whether addr can be a server on the internet: not unspecified, loopback,
  private, shared (CGNAT), link-local, multicast or reserved, and not port
  0. Upstream masters' lists have such addresses, from servers that
  heartbeat from a LAN, and the master shouldn't be had to send to its own
  network.
  """
  def public?({_, 0}), do: false
  def public?({{0, _, _, _}, _}), do: false
  def public?({{10, _, _, _}, _}), do: false
  def public?({{100, b, _, _}, _}) when b in 64..127, do: false
  def public?({{127, _, _, _}, _}), do: false
  def public?({{169, 254, _, _}, _}), do: false
  def public?({{172, b, _, _}, _}) when b in 16..31, do: false
  def public?({{192, 168, _, _}, _}), do: false
  def public?({{a, _, _, _}, _}) when a >= 224, do: false
  def public?({{_, _, _, _}, _}), do: true
  def public?({{0, 0, 0, 0, 0, 0, 0, _}, _}), do: false
  def public?({{0, 0, 0, 0, 0, 0xFFFF, _, _}, _}), do: false
  def public?({{a, _, _, _, _, _, _, _}, _}) when (a &&& 0xFE00) == 0xFC00, do: false
  def public?({{a, _, _, _, _, _, _, _}, _}) when (a &&& 0xFFC0) == 0xFE80, do: false
  def public?({{a, _, _, _, _, _, _, _}, _}) when (a &&& 0xFF00) == 0xFF00, do: false
  def public?(_), do: true

  @doc "The address's bytes, big-endian, then the port's."
  def to_binary({ip, port}), do: <<ip_bytes(ip)::binary, port::16>>

  def ip_bytes({a, b, c, d}), do: <<a, b, c, d>>

  def ip_bytes({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  def to_string({{_, _, _, _} = ip, port}), do: "#{:inet.ntoa(ip)}:#{port}"
  def to_string({ip, port}), do: "[#{:inet.ntoa(ip)}]:#{port}"
end
