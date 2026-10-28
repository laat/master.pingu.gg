defmodule Exmaster.TestHelpers do
  def infostring(info), do: Enum.map_join(info, fn {k, v} -> "\\#{k}\\#{v}" end)

  @doc "The addresses in getserversResponse/getserversExtResponse packets; asserts EOT ends the last one only."
  def decode_q3_lists(packets) do
    {addrs, eots} =
      packets
      |> Enum.map(fn
        "\xFF\xFF\xFF\xFFgetserversExtResponse" <> rest -> decode_q3(rest, [])
        "\xFF\xFF\xFF\xFFgetserversResponse" <> rest -> decode_q3(rest, [])
      end)
      |> Enum.unzip()

    true = Enum.drop(eots, -1) |> Enum.all?(&(&1 == false))
    true = List.last(eots)
    Enum.concat(addrs)
  end

  defp decode_q3("", acc), do: {Enum.reverse(acc), false}
  defp decode_q3("\\EOT\0\0\0", acc), do: {Enum.reverse(acc), true}

  defp decode_q3(<<?\\, a, b, c, d, port::16, rest::binary>>, acc),
    do: decode_q3(rest, [{{a, b, c, d}, port} | acc])

  defp decode_q3(<<?/, ip::binary-16, port::16, rest::binary>>, acc) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = ip
    decode_q3(rest, [{{a, b, c, d, e, f, g, h}, port} | acc])
  end

  @doc "The addresses in Quake 2 (`servers `) or QuakeWorld (`d\\n`) list packets."
  def decode_ipv4_lists(packets, header) do
    Enum.flat_map(packets, fn p ->
      <<0xFF, 0xFF, 0xFF, 0xFF, rest::binary>> = p
      ^header <> entries = rest
      for <<a, b, c, d, port::16 <- entries>>, do: {{a, b, c, d}, port}
    end)
  end
end
