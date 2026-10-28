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

  @doc "The address's bytes, big-endian, then the port's."
  def to_binary({ip, port}), do: <<ip_bytes(ip)::binary, port::16>>

  def ip_bytes({a, b, c, d}), do: <<a, b, c, d>>

  def ip_bytes({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  def to_string({{_, _, _, _} = ip, port}), do: "#{:inet.ntoa(ip)}:#{port}"
  def to_string({ip, port}), do: "[#{:inet.ntoa(ip)}]:#{port}"
end
