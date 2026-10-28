# GameSpy master protocol: Battlefield 1942, Medal of Honor and Unreal Tournament

This is GameSpy's first master protocol, from before Query and Reporting 2,
as Battlefield 1942, Medal of Honor: Allied Assault and Unreal Tournament
speak it, and how exmaster speaks it: `Exmaster.GS`
(wire format), `Exmaster.GS.Master` (heartbeats, UDP) and
`Exmaster.GS.ListServer` (lists, TCP). Quake 3 is in [quake3.md](quake3.md).
The sources used here are:

- The Battlefield 1942 Linux dedicated server, 1.61 patched to 1.612, as
  LinuxGSM installs it: its strings (GameSpy's QR SDK, `qr_send_exiting`,
  `\heartbeat\%d\gamename\%s`, the list request of its server browser) and
  its traffic, captured against exmaster on 2026-10-28.
- BF1942-Master (https://github.com/Ahrkylien/BF1942-Master), the master
  `master.bf1942.org` runs, with captures in its comments and the enctype 2
  cipher in Python.
- Luigi Auriemma's gsmsalg (gsseckey), as OpenSpy carries it
  (`openspy-core`, `code/core/OS/gamespy/gsmsalg.cpp`).
- Three Battlefield 1942 servers on the Internet, asked once each on
  2026-10-28.
- The Medal of Honor: Allied Assault Linux dedicated server, 1.12 with
  the Reborn patch RC3.5.1, as LinuxGSM installs it: its strings and its
  traffic against exmaster, on 2026-10-28. See
  [Medal of Honor](#medal-of-honor-allied-assault).
- The Unreal Tournament Linux server, OldUnreal's 469f, as LinuxGSM
  installs it: its traffic against exmaster, on 2026-10-28. See
  [Unreal Tournament](#unreal-tournament).

## Where Battlefield 1942 servers go

GameSpy's masters closed in 2014. The game's binaries heartbeat
`master.gamespy.com`, which no longer resolves, and send the All-Seeing
Eye's heartbeat to `master.udpsoft.com`, which doesn't either. Since 2022
the community runs `master.bf1942.org` (162.19.137.251), and players and
server admins patch their executables, or their hosts file, to use it. On
2026-10-28 it listed 79 servers. It takes heartbeats without a challenge
and lists without checking the client.

| Port | Use |
|---|---|
| UDP 27900 | master: heartbeats (GameSpy's and the All-Seeing Eye's) |
| TCP 28900 | master: lists |
| UDP 14567 | server: the game |
| UDP 23000 | server: GameSpy queries (`game.gameSpyPort`) |
| UDP 14690 | server: All-Seeing Eye queries |

The master's port 27900 is Quake 2's too, and the game hard-codes it.
The two masters can share the port (see
[Sharing port 27900](#sharing-port-27900)).

## Heartbeats

```
\heartbeat\23000\gamename\bfield1942
```

from the query port, to UDP 27900: as the server starts, and every 300
seconds. The number is the query port, which clients ask; under NAT the
heartbeat may come from another port, so exmaster takes the IP from the
packet and the port from the heartbeat. GameSpy's SDK adds
`\statechanged\1` when the game changes and `\statechanged\2` when it
exits; a Linux server stopped with Ctrl+C, as LinuxGSM stops it, sends
nothing.

BF1942 also sends the All-Seeing Eye's heartbeat, `\hb\14690\bf1942`, to
port 27900 of `master.udpsoft.com`. exmaster drops it. The All-Seeing
Eye's client and masters closed in 2008, and nothing still reads such a
list, so there is no master for it.

## Sharing port 27900

A `q2` and a `gs` listener on the same address and port run on one
socket, `Exmaster.Q2GS`, which tells the packets apart by how they start:

| Starts with | From | Goes to |
|---|---|---|
| `\hb\` | BF1942: the All-Seeing Eye's heartbeat | dropped |
| `\` | GameSpy servers: heartbeats, replies to `\secure\` | `Exmaster.GS.Master` |
| anything else | Quake 2: out-of-band packets (`FF FF FF FF`), `query` | `Exmaster.Q2.Master` |

Quake 2 takes the first word of a packet as its command, so nothing it
sends starts with `\`; everything GameSpy's first protocol sends does.
The two keep their own stores, rate limits and state. Replies go out
through the shared socket, so a server behind NAT gets them from the
address it sent its heartbeat to.

## The challenge

A server answers `\secure\<challenge>` on its query port with
`\validate\<response>`, the challenge under the game's secret key with
gsmsalg: an RC4-like pass keyed with the key, then base64 (the alphabet
gsmsalg spells out is base64's). `\info\` and `\secure\` together get one
reply of about 400 bytes:

```
\info\\secure\AtjJBQLjIYaWFitR

\averageFPS\0\content_check\1\dedicated\2\gameId\bf1942\gamemode\pre
\gametype\conquest\hostname\exmaster test\hostport\14567\mapId\BF1942
\mapname\berlin\maxplayers\16\numplayers\0\password\0\reservedslots\0
\roundTime\-1\roundTimeRemain\-1\status\3\sv_punkbuster\0\tickets1\80
\tickets2\100\unpure_mods\\version\v1.612\validate\vWcYUi1PGU/Wgnf54XqrRwAA
\weight\10\final\\queryid\2.1
```

(one packet, broken into lines here). The Linux server answered
challenges of 6 to 65 characters, gsmsalg's limit; three servers on the
Internet answered `ABCDEF` with `vXrDWjx4`. `\status\` is `\info\` with
`gamename`, `gamever` and the rules, about 1 KB.

Battlefield 1942's key is `HpWx9z`. Anyone can compute a response, so the
response proves nothing by itself; the challenge does: only the master
and the server it went to know it. gsmsalg's first pass depends on the
key alone, so exmaster does it once a game; a forged `\validate\` then
costs it about as much as a forged Quake 3 `infoResponse`, and one of the
wrong length nothing.

## How exmaster lists servers

1. **Heartbeat from an address that isn't listed.** The master sends
   `\info\\secure\<challenge>` to the heartbeat's IP and query port, and
   stores nothing. A challenge is 16 characters of `[A-Za-z0-9]` (6 for
   Unreal Tournament): the game's, then an HMAC of the address, the
   listener and a 5-second time bucket. It is good in its bucket and the
   next, 5 to 10 seconds.
2. **Reply with a valid `\validate\`, from that address.** The server is
   listed for 15 minutes, with `hostname`, `numplayers`, `maxplayers` and
   `version` (Unreal Tournament's `gamever`) from the reply. Only another valid reply moves that on.
3. **Heartbeat from a listed server.** It is asked again, at most once a
   minute; a heartbeat inside the minute has it asked when the minute is
   over. Only the listener it is listed through asks it.
4. **`\statechanged\2` from a listed server.** It can be forged, so the
   server is asked, and dropped if it doesn't answer within 10 seconds.

A heartbeat for a game the master has no key for is ignored. The rate
limits are the other masters' (see the
[README](../README.md#limits-for-all-of-them)).

## The list

Over TCP:

| From | Message |
|---|---|
| master | `\basic\\secure\<challenge>`, on connecting |
| client | `\gamename\bfield1942\gamever\2\location\0\validate\<response>\enctype\2\final\\queryid\1.1\` |
| client | `\list\cmp\gamename\bfield1942\final\`, or with `\where\<filter>` before `\final\` |
| master | the list, then closes |

With `cmp` the list is 6 bytes a server, IPv4 address and query port,
big-endian, then `\final\`; without, text, `\ip\a.b.c.d:port` a server.
With `\enctype\2`, as Battlefield 1942 asks, the master encrypts both
under the key of the game asking; with none or 0 it sends them as they
are. qstat asks as GameSpy Arcade, with no encryption and the text form:

```
\gamename\gamespy2\gamever\020109017\location\5\validate\12345678\final\\list\\gamename\bfield1942\final\
```

exmaster, like `master.bf1942.org`, ignores `\where\` (clients filter
the list themselves) and doesn't check the client's `\validate\` (the
keys are public). Any client may list any game, as on GameSpy's masters;
encrypting needs the asking game's key.

Limits: 64 connections at once, for everyone; per IP, 5 at once, then
one every 3 seconds; 5 seconds and 2 KB from connecting to the end of the
request; 10 seconds in all, sending included, so a client that reads
slowly can't keep a slot; and the reply-byte budget all masters share,
reserved before the list is made and encrypted.

## Enctype 2

```
header length xor 0xEC (1 byte)
header, 6 to 14 random bytes; the first 6 xor the key
the list and \final\, xor a keystream
```

The keystream comes from a table of 326 32-bit words seeded from the
header (before it is xored with the key) and rewritten as it goes, 63
bytes at a time: the code it comes from regenerates its 64-byte buffer
one byte early. `Exmaster.GS.Enctype2` is ported from BF1942-Master's
Python and checked against it byte for byte; Battlefield 1942's own
decoder is `ServerListReadList` in its binaries.

## Medal of Honor: Allied Assault

MOH:AA speaks the same protocol, as `mohaa`, with the key `M5Fdwc`
(aluigi's gslist.cfg; the server's `\validate\` matches it). 333networks
listed 135 servers on 2026-10-28.

| Port | Use |
|---|---|
| UDP 12203 | server: the game |
| UDP 12300 | server: GameSpy queries, on 0.0.0.0 whatever `net_ip` says |

- **Heartbeats** go to `master.gamespy.com:27900`, compiled in, from the
  query port: `\heartbeat\12300\gamename\mohaa\statechanged\`, with
  `statechanged` empty, as the server starts, on the console's
  `heartbeat` command, 300 seconds after the last, and as it shuts down.
  The last is the same packet as the others, so a server that stops
  stays listed until it expires. The Reborn patch's config names
  `mohmaster.2015.com` in `sv_master1`-`3`, which doesn't resolve and
  which the server didn't contact.
- **`sv_gamespy 1`** has to be set before `+map`, or the server opens no
  query socket and sends nothing. LinuxGSM's start line runs `+map` before
  `+exec`, so setting it in the server's config is too late.
- **The reply** to `\info\\secure\<challenge>` is one packet:
  `\gamemode\openplaying\maxplayers\14\numplayers\0\gametype\Round-Based-Match\mapname\dm/mohdm1\hostport\12203\hostname\…\validate\…\final\\queryid\3.1`.
- **Clients** ask for a list without `\enctype\`
  (`\gamename\%s\gamever\%s\location\0\validate\%s\final\\queryid\1.1\`,
  then `\list\cmp\gamename\mohaa\final\`), so they get it
  unencrypted.

## Unreal Tournament

Unreal Tournament speaks it as `ut`, with the key `Z5Nfb0` (aluigi's
gslist.cfg; the server's `\validate\` matches it). 333networks listed
852 servers on 2026-10-28.

| Port | Use |
|---|---|
| UDP 7777 | server: the game |
| UDP 7778 | server: GameSpy queries |
| UDP 7779, 7780, … | server: one a master, for its heartbeats |

- **The masters** are `ServerActors` lines in the server's ini, under
  `[Engine.GameEngine]`, one a master:
  `ServerActors=IpServer.UdpServerUplink MasterServerAddress=… MasterServerPort=27900`.
  They have to come after `ServerActors=IpServer.UdpServerQuery`.
- **Heartbeats**, `\heartbeat\7778\gamename\ut`, come from the
  uplink's own port and name the query port, every 55 seconds
  (`UpdateMinutes=1`). Nothing is sent when the server stops, so it
  stays listed until it expires.
- **The challenge.** The server answers only the first 6 characters of a
  `\secure\` challenge: its `\validate\` is 8 characters, the first 8 of
  the response to the whole. So exmaster sends it 6: the game's and 5 of
  HMAC, about 30 bits, for a challenge that lives 10 seconds.
- **The reply** to `\info\\secure\<challenge>` is one packet:
  `\hostname\…\hostport\7777\maptitle\…\mapname\DM-Deck16][\gametype\DeathMatchPlus\numplayers\0\maxplayers\10\gamemode\openplaying\gamever\469\minnetver\432\worldlog\true\wantworldlog\true\validate\…\queryid\1.1\final\`.
- **Clients** (UBrowser's `UBrowserGSpyFact`) ask for the text list:
  `\gamename\ut\location\0\validate\…\final\`, then
  `\list\\gamename\ut\final\`, and get `\ip\a.b.c.d:7778` a
  server, then `\final\`.
- **OldUnreal 469** upgrades an ini whose `[FirstRun] FirstRun` is older
  than 469, setting it to 469 and adding its default masters
  (`master.oldunreal.com`, `master.333networks.com`,
  `master.hypercoop.tk`, `master.qtracker.com`) to the uplinks, from the
  next start. An ini with `FirstRun=469` is left alone.

