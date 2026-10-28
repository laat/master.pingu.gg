defmodule Exmaster.Config do
  @moduledoc """
  Parses the `listen` setting (`EXMASTER_LISTEN`): comma-separated
  `protocol:[host:]port[=label]`, where protocol is `q3`, `q2` or `qw`.

      q3:27950,q3:27900=UrbanTerror,q2:27900,qw:27000
      q3:[::1]:27950,q2:127.0.0.1:27900

  A label is for Quake 3 listeners only; see "Listeners" in
  `docs/quake3.md`. Quake 2 and QuakeWorld lists only hold IPv4, so their
  host can't be IPv6.
  """

  @protocols %{"q3" => Exmaster.Q3.Master, "q2" => Exmaster.Q2.Master, "qw" => Exmaster.QW.Master}

  def listeners!(spec) do
    spec
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&listener!/1)
  end

  defp listener!(item) do
    {addr, label} =
      case String.split(item, "=", parts: 2) do
        [addr, label] -> {addr, label}
        [addr] -> {addr, nil}
      end

    with [name, hostport] <- String.split(addr, ":", parts: 2),
         {:ok, protocol} <- Map.fetch(@protocols, name),
         {:ok, ip, port} <- hostport(hostport),
         :ok <- check(protocol, ip, label) do
      [protocol: protocol, ip: ip, port: port, label: label]
    else
      {:error, reason} ->
        raise ArgumentError, "listen #{inspect(item)}: #{reason}"

      _ ->
        raise ArgumentError, "listen #{inspect(item)}: want q3|q2|qw:[host:]port[=label]"
    end
  end

  defp hostport(s) do
    with [_, v6, v4, port] <- Regex.run(~r/^(?:(?:\[([^\]]+)\]|([^:\[\]]+)):)?(\d+)$/, s),
         port when port in 0..65_535 <- String.to_integer(port),
         {:ok, ip} <- ip(v6 <> v4) do
      {:ok, ip, port}
    else
      {:error, _} = error -> error
      _ -> {:error, "bad host or port"}
    end
  end

  defp ip(""), do: {:ok, nil}

  defp ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, "#{host} is not an IP address"}
    end
  end

  defp check(protocol, ip, label) do
    q3 = protocol == Exmaster.Q3.Master

    cond do
      not q3 and ip != nil and tuple_size(ip) == 8 ->
        {:error, "Quake 2 and QuakeWorld lists are IPv4 only"}

      label == nil ->
        :ok

      not q3 ->
        {:error, "labels are for q3 listeners"}

      not Exmaster.Q3.valid_name?(label, Exmaster.Q3.max_name_length()) ->
        {:error, "invalid label"}

      true ->
        :ok
    end
  end
end
