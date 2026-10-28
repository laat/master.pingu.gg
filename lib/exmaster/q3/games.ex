defmodule Exmaster.Q3.Games do
  @moduledoc """
  The games with a heartbeat tag of their own. Games that share another's,
  as Urban Terror shares Quake 3's, are told apart by the port their
  servers heartbeat: a labelled listener. See "Listeners" in
  `docs/quake3.md`.
  """

  # Most of these are anonymous: their servers and clients send no game
  # name, so it comes from the heartbeat tag or the protocol. The first
  # three are dpmaster's (games.c); protocol 57 (RTCW 1.0) is from
  # pymaster. Tremulous and Smokin' Guns have tags of their own; their
  # protocols are shared with other ioquake3 games. ET clients never ask
  # for empty or full servers, so they always get them.
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
    },
    # Smokin' Guns 1.1 (code/qcommon/q_shared.h); protocol 68. Named as
    # its servers and clients name it (GAMENAME_FOR_MASTER).
    %{
      name: "smokinguns",
      protocols: [],
      heartbeat: "smokinguns",
      flatline: "smokingunsdead",
      always_empty_full: false
    }
  ]

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
end
