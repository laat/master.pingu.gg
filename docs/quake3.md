# Quake 3 master server protocol

This is the Quake 3 master protocol, as dpmaster defined it, and how
exmaster speaks it. Game servers heartbeat the master, the master checks
them with `getinfo`, and clients ask it for lists with `getservers` and
`getserversExt`. Quake 2 is in [quake2.md](quake2.md), QuakeWorld in
[quakeworld.md](quakeworld.md). The sources used here are:

- id Software's `server.txt`, originally on ftp.idsoftware.com, mirrored at
  https://thegate.gamers.org/pub/idgames2/idstuff/quake3/docs/server.txt.
  It only covers the game server's out-of-band commands (`getstatus`,
  `getinfo`, `getchallenge`, `connect`, `rcon`), not heartbeats or
  `getservers`, but it is the origin of the challenge rule: "We do this in
  order to stop ghost servers appearing which do nothing more than send ghost
  heartbeats to a master server, you should query and check a server with a
  challenge before accepting it."
- dpmaster 2.2 `doc/techinfo.txt` and `src/messages.c`, `src/games.c`
  (Mathieu Olivier, https://github.com/kphillisjr/dpmaster). dpmaster is the
  de facto reference implementation and is what ioquake3, DarkPlaces, Xonotic
  and most open-source id Tech 3 games talk to.
- ioquake3 `code/client/cl_main.c` and `code/server/sv_main.c` for the client
  and game server side.
- The previous Python implementation, https://github.com/laat/pymaster.

## Transport

Everything is UDP. The conventional master port is 27950; game servers
default to 27960 (`net_port`). Every packet starts with four `0xFF` bytes
("out-of-band" marker), followed by a command name in plain ASCII. The
command name ends at the first space, `\n`, `\` or `/`.

```
FF FF FF FF  <command> <payload>
```

Packets from the master are kept at or below 1400 bytes.

## Roles

| Role        | Sends to master                         | Receives from master   |
|-------------|-----------------------------------------|------------------------|
| Game server | `heartbeat`, `infoResponse`             | `getinfo`              |
| Game client | `getservers`, `getserversExt`           | `getserversResponse`, `getserversExtResponse` |

## Messages

### `heartbeat` (server → master)

```
\xFF\xFF\xFF\xFFheartbeat QuakeArena-1\n
```

The argument is a *heartbeat tag* identifying the protocol family, not the game:

| Tag                | Game name     | Flatline tag     |
|--------------------|---------------|------------------|
| `QuakeArena-1`     | `Quake3Arena` | (same tag)       |
| `Wolfenstein-1`    | `wolfmp`      | `WolfFlatline-1` |
| `EnemyTerritory-1` | `et`          | `ETFlatline-1`   |
| `Tremulous`        | `Tremulous`   | `Tremulousdead`  |
| `smokinguns`       | `SmokinGuns`  | `smokingunsdead` |
| `DarkPlaces`       | from `infoResponse` `gamename` | none |
| anything else      | from `infoResponse` `gamename` | none |

Call of Duty sends `flatline`. Tags are 1–63 printable ASCII characters
without whitespace or `\`; other heartbeats are dropped.

Servers send a heartbeat when they start, when they become empty/full or stop
being empty/full, and periodically (ioquake3: every 5 minutes). A *flatline*
heartbeat is sent at shutdown.

A heartbeat proves nothing on its own because the source address can be
spoofed. The master answers with `getinfo` and only trusts the reply.

### `getinfo` (master → server)

```
\xFF\xFF\xFF\xFFgetinfo <challenge>
```

The challenge is 9–12 characters from ASCII 33–126, excluding
`\ / ; " %`. The server must echo it back in its `infoResponse`. Since the
master picks it and sends it to the claimed address, a valid echo proves the
server owns that address. exmaster's are 11 characters; see
[Challenges](#challenges).

### `infoResponse` (server → master)

```
\xFF\xFF\xFF\xFFinfoResponse\n\challenge\<challenge>\protocol\68\sv_maxclients\16\clients\3\gametype\0\hostname\...
```

The payload is an *infostring*: `\key\value\key\value...`. A key given
twice keeps its last value. Required keys:

| Key             | Rule                                              |
|-----------------|---------------------------------------------------|
| `challenge`     | must be a challenge the master sent to this address, not expired |
| `protocol`      | integer; read as C's `atoi` does, so QuakeSpasm-Spiked's `3n` is 3 |
| `sv_maxclients` | integer > 0 (Q3 sends maxclients minus private slots) |
| `clients`       | integer; missing counts as 0 (Call of Duty leaves it out when empty) |
| `gametype`      | optional, defaults to `"0"`, 1–31 printable characters, no whitespace |
| `gamename`      | required unless the game comes from elsewhere (see [Game names](#game-names)), no whitespace |

Common extra keys: `hostname`, `mapname`, `pure`, `game` (mod directory),
`g_humanplayers`, `g_needpass`. exmaster keeps the first 63 bytes of
`hostname`.

### `getservers` (client → master)

```
\xFF\xFF\xFF\xFFgetservers 68 empty full          (Q3A, anonymous)
\xFF\xFF\xFF\xFFgetservers 84                     (ET)
\xFF\xFF\xFF\xFFgetservers Nexuiz 3 full          (DarkPlaces style, named)
```

Two forms, told apart by whether the first token is an integer:

- Anonymous: `getservers <protocol> [options]`. The game is looked up from the
  protocol number (66–68 → Quake3Arena, 50/57/59/60 → wolfmp, 72/80/83/84 → et).
  For any other protocol, every server that reported it matches, whatever
  its game.
- Named: `getservers <gamename> <protocol> [options]`.

A labelled listener (see [Listeners](#listeners)) ignores the game name:
every server it lists is its game's, and Smokin' Guns' clients ask for
`smokinguns` over IPv6 and anonymously over IPv4.

Options, whitespace-separated, unknown ones ignored:

| Option        | Meaning                                   |
|---------------|-------------------------------------------|
| `empty`       | include servers with 0 clients            |
| `full`        | include servers with clients ≥ sv_maxclients |
| `gametype=X`  | only servers whose `gametype` equals X    |
| `ffa`         | `gametype=0`                              |
| `tourney`     | `gametype=1`                              |
| `team`        | `gametype=3`                              |
| `ctf`         | `gametype=4`                              |

Empty and full servers are left out unless asked for. ET clients never ask,
so for `et` the master always includes them (dpmaster's
`send-empty-servers,send-full-servers` game option).

pymaster mapped `team` to 2 and `ctf` to 3. That was wrong: in Q3, gametype 2
is single player, 3 is team deathmatch and 4 is CTF.

`getservers` only returns IPv4 servers.

### `getserversResponse` (master → client)

```
\xFF\xFF\xFF\xFFgetserversResponse\<6 bytes>\<6 bytes>...\EOT\0\0\0
```

Each server is `\` followed by 4 bytes of IPv4 address and 2 bytes of port,
big-endian. `1.2.3.4:2048` is `\x5C\x01\x02\x03\x04\x08\x00`.

If the list does not fit in one packet the master sends several, each with
the full header. Only the last packet ends with the fake entry `\EOT\0\0\0`.
(dpmaster < 2.0 and pymaster put EOT on every packet. Clients should treat
`EOT`/`EOF` entries as markers, never as addresses. They have port 0;
`69.79.84.10:27960` is an address.) Servers are sent in address order.

### `getserversExt` (client → master)

```
\xFF\xFF\xFF\xFFgetserversExt Quake3Arena 68 empty ipv4 ipv6
```

Like the named `getservers`, plus two options:

| Option | Meaning               |
|--------|-----------------------|
| `ipv4` | include IPv4 servers  |
| `ipv6` | include IPv6 servers  |

If neither appears, both are included. Some old ioquake3 builds send
`getserversExt 68 empty ipv6` with no game name, so the anonymous form is
accepted here too.

### `getserversExtResponse` (master → client)

```
\xFF\xFF\xFF\xFFgetserversExtResponse\<6 bytes>/<18 bytes>...\EOT\0\0\0
```

`\` precedes a 6-byte IPv4 entry, `/` precedes an 18-byte IPv6 entry (16
address bytes + 2 port bytes). Splitting and EOT work as for
`getserversResponse`.

### Other messages

RTCW and ET send `gameCompleteStatus` at the end of a match. It carries
nothing a master needs, and exmaster ignores it, as it does any other
command.

## How exmaster lists servers

This follows dpmaster's rule: an `infoResponse` carrying a valid challenge is
the only message that is trusted.

1. **Heartbeat from an address that isn't listed.** The master sends
   `getinfo` with a challenge and stores nothing.
2. **Valid `infoResponse`.** The server is listed under a game name, with
   its protocol, gametype, clients and maxclients, until 15 minutes after
   the reply. Only another valid `infoResponse` moves that on.
3. **Heartbeat from a listed server.** The master sends `getinfo` again,
   at most once a minute; a heartbeat inside the minute has it sent when
   the minute is over. A heartbeat with another tag doesn't change how a
   listed server is classified, since heartbeats can be forged; the new
   tag applies once the server has expired.
4. **Flatline from a listed server.** A flatline can be forged, so the
   server isn't dropped for it: it is sent `getinfo`, and dropped if it
   doesn't answer within 10 seconds. That query counts toward the
   once-a-minute allowance.

A listed server is only asked through the listener it is listed through:
behind NAT it may only take packets from the address it heartbeats.
Heartbeats and flatlines for it that come in on another listener are
ignored. The rate limits are in the [README](../README.md#limits-for-all-three).

### Challenges

exmaster's challenges are stateless, like TCP SYN cookies:

```
challenge = class char + base89(first 8 bytes of
            HMAC-SHA256(key, address, listener, time bucket, class))
```

The key is random per boot. The listener is the local address and port
the `getinfo` went out from, so a challenge only checks on that socket.
The time bucket is `now / 5 s`, and a challenge is accepted in its own
bucket and the next one, so it lives 5–10 seconds (dpmaster: 2 s). The
result is 11 characters from the allowed set.

The class records what the heartbeat tag said, so the reply can be
classified without the master having stored anything:

- **known**: a tag from the table above, which implies a game;
- **DarkPlaces**: the server must send `gamename`;
- **unknown**: any other tag. The server must send `gamename`, can't be
  listed as a built-in game (`Quake3Arena`, `wolfmp`, `et`, `Tremulous`,
  `SmokinGuns`) unless a listener's label says so, and there are at most
  `EXMASTER_MAX_UNKNOWN_TAG` (512) such servers. A made-up tag can't
  crowd out or impersonate the games that have tags of their own.

### Game names

Every `infoResponse` decides the game again, first match wins:

1. The listener's label.
2. The `gamename` key.
3. The game the heartbeat tag implies.

If nothing applies, the server is rejected. Game names must be 1–63
printable ASCII characters without whitespace or `\`.

### Servers with several protocols

Some servers answer with a different `protocol` from one reply to the
next so they get listed for several client versions. On 2026-10-25, 20 of
21 RTCW 1.0 servers did: 14 rotated through 57 and 60, 6 through 50, 57,
59 and 60, and 3 1.4 servers through 57 and 60. exmaster remembers every
protocol a server reported in the last 15 minutes, up to 8, dropping the
oldest, and lists it for each.

What a server advertises isn't what it accepts. The rotating RTCW 1.0
servers run WolfSE, a 1.0 server build that rotates through every RTCW
protocol to get onto every list: the six advertising the demo protocol
(50) were on maps the demo doesn't have, which has only `mp_beach`.

### Listeners

A master can listen on several ports, and a Quake 3 listener can have a
label: `EXMASTER_LISTEN=q3:27950,q3:27960=UrbanTerror,q3:27961=SmokinGuns`.
A labelled listener is a game's own master. Its servers are listed in a
store of their own, under the label, shared by the listeners with the
same label and kept apart from the Quake 3 list, and every query to it is
answered from that store, whatever game it names.

That is how games that look like Quake 3 on the wire are kept apart.
Urban Terror and Smokin' Guns are standalone games with masters of their
own, `master.urbanterror.info:27900` and `master.smokin-guns.org:27950`.
Urban Terror's servers heartbeat `QuakeArena-1` with no `gamename`, and
its clients ask `getservers 68`, as Quake 3's do; only the master they
talk to tells them apart. Smokin' Guns' servers heartbeat `smokinguns`,
but its clients ask `getservers 68` over IPv4 too. A server that
heartbeats the Quake 3 port is listed as what its tag and `gamename` say,
so an Urban Terror server there is listed as Quake 3, as dpmaster would.

To take a game's servers on its own default port, give its listener an
address of its own (`q3:203.0.113.2:27900=UrbanTerror`), and bind the
other listeners on that port to their addresses: a listener on all
addresses takes the port on all of them.

## Telling games apart

Many id Tech 3 games heartbeat `QuakeArena-1`, send no `gamename` (or
`Quake3Arena`) and share protocol numbers. This is what tells them apart,
from the replies of about 2,200 servers listed by their own masters on
2026-10-25 and from engine source. exmaster goes by none of it: a game
that can't be told by its tag or `gamename` gets a labelled listener (see
[Listeners](#listeners)). Much of it only shows up in `statusResponse`,
which a master doesn't ask for.

| Game | Protocol | `gamename` sent | Distinguishing fields |
|---|---|---|---|
| Quake 3 (id 1.32, CNQ3) | 68 (1.31: 67) | no | status `version` `Q3 1.32…`, `CNQ3 …` |
| Quake 3 (ioquake3) | 68 | `Quake3Arena` | info `g_humanplayers`; status `version` `ioq3 …`, `com_gamename` |
| Urban Terror 4.2/4.3 | 68 | no, or `Quake3Arena` | info `game` = `q3ut4`, `modversion`, `auth`; status `gamename` `q3urt43` |
| Smokin' Guns | 68 | rarely, `smokinguns` | tag `smokinguns`; info `game` = `smokinguns` |
| OpenArena | 71 | no, or `Quake3Arena` | status `gamename` `baseoa`, `version` `ioq3+oa …`; nothing in info |
| Q3Rally | 71 | `Q3Rally` | |
| World of Padman | 71 | `WorldofPadman` | |
| Tremulous | 69–71 | trunk: no; GPP/1.3: `Tremulous` | tag `Tremulous` |
| Jedi Outcast (+JK2MV) | 15, 16 | no | info `truejedi`, `wdisable`, `fdisable`; status `JK2MV` |
| Jedi Academy (+OpenJK) | 25, 26 | no | as JK2; info `autodemo` on OpenJK |
| Soldier of Fortune II | 2002, 2004 | no | status `com_gamename` `SoF2MP` |
| RTCW (+iortcw) | 60 (1.0: 57) | `wolfmp` | tag `Wolfenstein-1` |
| ET 2.60b, ET: Legacy, ETe | 84 (`ET 3.00 - TB` servers: 82) | `et` | tag `EnemyTerritory-1`; ET: Legacy adds info `version` `ET Legacy v…` |
| Warsow, Warfork | 22 (Warfork also 24, 26) | yes | |
| Nexuiz, Xonotic | 3 | yes | tag `DarkPlaces` |

Jedi Outcast, Jedi Academy and Soldier of Fortune II need nothing: their
protocols are their own, and an anonymous query for a protocol exmaster
has no game for matches every server that reported it. They are listed
as `Quake3Arena`, which their tag implies.

OpenArena is the one that can't be told from Quake 3 by `infoResponse`:
at protocol 71 both send `Quake3Arena` or nothing, and 14 of the 76
servers OpenArena's master listed were in fact Quake 3 (`baseq3`,
`defrag`) on an ioquake3 build with protocol 71. A labelled listener is
the way to list them apart.

ET: Legacy servers (285 of 399 ET servers on 2026-10-25, with 453 of the
568 players) are listed as `et`, with vanilla Wolfenstein: ET's, whose
clients join them.

## Quake on Quake 3 masters

id's Quake has no master server: its servers answer `CCREQ_SERVER_INFO`
broadcasts on the local network. Modern engines list their Quake servers
on Quake 3-style masters with the `DarkPlaces` tag, protocol 3, under game
names of their own: `DarkPlaces-Quake` (DarkPlaces) and `FTE-Quake` (FTE,
QuakeSpasm-Spiked). Their `infoResponse` is a normal one plus Quake keys:
`mapname`, `deathmatch`, `teamplay`, `coop`, `modname` or `mod`, and `ver`.

## Call of Duty

Call of Duty, United Offensive, 2 and 4 run on id Tech 3 and speak this
protocol with two differences a master has to allow for: servers send
`flatline` at shutdown, and leave out `clients` when nobody is on, which
exmaster counts as 0 (dpmaster would reject them). The gametype is a word
(`tdm`, `sd`, `war`). Without `gamename`, a labelled listener names the
game.
