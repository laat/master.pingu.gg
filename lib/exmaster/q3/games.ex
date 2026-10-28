defmodule Exmaster.Q3.Games do
  @moduledoc """
  The games with a heartbeat tag of their own, and the fingerprints that
  tell games apart when their servers don't say.
  """

  # Most of these are anonymous: their servers and clients send no game
  # name, so it comes from the heartbeat tag or the protocol. The first
  # three are dpmaster's (games.c); protocol 57 (RTCW 1.0) is from
  # pymaster. Tremulous has its own tag; its protocols, 69-71, are shared
  # with other ioquake3 games. ET clients never ask for empty or full
  # servers, so they always get them.
  @games [
    %{
      name: "Quake3Arena",
      protocols: [66, 67, 68],
      heartbeat: "QuakeArena-1",
      flatline: nil,
      always_empty_full: false
    },
    %{
      name: "wolfmp",
      protocols: [50, 57, 59, 60],
      heartbeat: "Wolfenstein-1",
      flatline: "WolfFlatline-1",
      always_empty_full: false
    },
    %{
      name: "et",
      protocols: [72, 80, 83, 84],
      heartbeat: "EnemyTerritory-1",
      flatline: "ETFlatline-1",
      always_empty_full: true
    },
    %{
      name: "Tremulous",
      protocols: [],
      heartbeat: "Tremulous",
      flatline: "Tremulousdead",
      always_empty_full: false
    }
  ]

  # Checked in order. A rule matches if every field it has matches.
  @fingerprints [
    # 234 of 235 Urban Terror servers on 2026-10-25; no Quake 3 server.
    %{game: "UrbanTerror", key: "game", value: "q3ut4"},
    %{game: "SmokinGuns", key: "game", value: "smokinguns"},
    # Raven's engines heartbeat QuakeArena-1 with no gamename, but on
    # protocols of their own.
    %{game: "JK2", protocols: [15, 16]},
    %{game: "JKA", protocols: [25, 26]},
    %{game: "SoF2", protocols: [2002, 2004]},
    # ET: Legacy puts its version in infoResponse; vanilla 2.60b doesn't.
    %{game: "ETLegacy", protocols: [82, 83, 84], key: "version", prefix: "ET Legacy"}
  ]

  # Games listed apart whose servers another game's clients join: ET 2.60b
  # clients join ET: Legacy servers, so a query for et lists them too.
  @variants %{"ETLegacy" => "et"}

  @darkplaces "DarkPlaces"

  def all, do: @games

  def by_heartbeat(tag), do: Enum.find(@games, &(&1.heartbeat == tag))
  def by_protocol(protocol), do: Enum.find(@games, &(protocol in &1.protocols))
  def by_name(name), do: Enum.find(@games, &(&1.name == name))
  def builtin?(name), do: by_name(name) != nil

  @doc "The generic tag of games that send their name in infoResponse."
  def darkplaces, do: @darkplaces

  @doc "Whether a heartbeat tag announces a shutdown. Call of Duty sends `flatline`."
  def flatline?("flatline"), do: true
  def flatline?(tag), do: Enum.any?(@games, &(&1.flatline == tag))

  @doc "The games whose servers a query for game lists: itself and its variants."
  def listed_as(game), do: [game | for({v, ^game} <- @variants, do: v)]

  @doc "The game a fingerprint gives an infoResponse, or nil."
  def identify(info, protocol) do
    Enum.find_value(@fingerprints, fn f ->
      if protocol_matches?(f, protocol) and key_matches?(f, info), do: f.game
    end)
  end

  defp protocol_matches?(%{protocols: ps}, protocol), do: protocol in ps
  defp protocol_matches?(_, _), do: true

  defp key_matches?(%{key: k, value: v}, info), do: Map.get(info, k) == v
  defp key_matches?(%{key: k, prefix: p}, info), do: String.starts_with?(Map.get(info, k, ""), p)
  defp key_matches?(_, _), do: true
end
