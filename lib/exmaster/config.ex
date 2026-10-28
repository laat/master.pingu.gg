defmodule Exmaster.Config do
  @moduledoc """
  Parses the `listen` setting (`EXMASTER_LISTEN`): comma-separated
  `protocol:[host:]port[=label]`, where protocol is `q3`, `q2`, `qw`, `gs`
  (GameSpy heartbeats, UDP), `gsl` (GameSpy lists, TCP) or `ue2` (Unreal
  Tournament 2004, TCP).

      q3:27950,q2:27900,qw:27000,q3:27960=UrbanTerror,q3:27961=SmokinGuns
      q3:[::1]:27950,q2:127.0.0.1:27900,gs:127.0.0.2:27900,gsl:127.0.0.2:28900
      ue2:28902

  A label is for Quake 3 listeners only. A labelled listener is a master of
  its own, for one game: it lists its servers in a store of its own,
  shared with the listeners that have the same label. See "Listeners" in
  `docs/quake3.md`. Quake 2, QuakeWorld, GameSpy and UT2004 lists only
  hold IPv4, so their host can't be IPv6.

  A `q2` and a `gs` listener on the same address and port share one
  socket, `Exmaster.Q2GS`: both games heartbeat UDP 27900.
  """

  @protocols %{
    "q3" => Exmaster.Q3.Master,
    "q2" => Exmaster.Q2.Master,
    "qw" => Exmaster.QW.Master,
    "gs" => Exmaster.GS.Master,
    "gsl" => Exmaster.GS.ListServer,
    "ue2" => Exmaster.UE2.Master
  }

  def listeners!(spec) do
    spec
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&listener!/1)
    |> share()
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
      [protocol: protocol, ip: ip, port: port, label: label, store: store(protocol, label)]
    else
      {:error, reason} ->
        raise ArgumentError, "listen #{inspect(item)}: #{reason}"

      _ ->
        raise ArgumentError, "listen #{inspect(item)}: want q3|q2|qw:[host:]port[=label]"
    end
  end

  # A q2 and a gs listener on one address and port become one listener,
  # where the first of them was.
  @shared [Exmaster.GS.Master, Exmaster.Q2.Master]

  defp share(listeners) do
    pairs =
      listeners
      |> Enum.filter(&(&1[:protocol] in @shared and &1[:port] != 0))
      |> Enum.group_by(&{&1[:ip], &1[:port]}, & &1[:protocol])
      |> Map.filter(fn {_, protocols} -> Enum.sort(protocols) == @shared end)

    listeners
    |> Enum.map(fn l ->
      if l[:protocol] in @shared and Map.has_key?(pairs, {l[:ip], l[:port]}),
        do: [
          protocol: Exmaster.Q2GS,
          ip: l[:ip],
          port: l[:port],
          label: nil,
          store: Exmaster.Q2GS.store()
        ],
        else: l
    end)
    |> Enum.uniq_by(
      &if(&1[:protocol] == Exmaster.Q2GS, do: {&1[:ip], &1[:port]}, else: make_ref())
    )
  end

  @doc """
  The stores the listeners list into, as `{name, store}`: `:q3`, `:q2`,
  `:qw`, `:gs` and `:ue2` always, and a label for each labelled
  listener's.
  """
  def stores(listeners) do
    base = [
      q3: Exmaster.Q3.Master.store(),
      q2: Exmaster.Q2.Master.store(),
      qw: Exmaster.QW.Master.store(),
      gs: Exmaster.GS.Master.store(),
      ue2: Exmaster.UE2.Master.store()
    ]

    labelled =
      for l <- listeners, l[:label] != nil, uniq: true, do: {l[:label], l[:store]}

    base ++ labelled
  end

  defp store(protocol, nil), do: protocol.store()
  defp store(protocol, label), do: :"#{protocol.store()}_#{label}"

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
        {:error, "Quake 2, QuakeWorld, GameSpy and UT2004 lists are IPv4 only"}

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
