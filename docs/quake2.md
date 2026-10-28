# Quake 2 master server protocol

The Quake 2 master is `Exmaster.Q2.Master`, with the wire format in
`Exmaster.Q2`. It shares nothing of the Quake 3 rules
([quake3.md](quake3.md)): no challenges, tags, fingerprints or labels.
QuakeWorld's is much the same, see [quakeworld.md](quakeworld.md).
Sources: id's Quake 2 `server/sv_main.c`, `qcommon/qcommon.h`, and two
master implementations, packetflinger/q2master (Go) and
quakeservices/master (Python).

Quake 2 masters listen on 27900 (`PORT_MASTER`), game servers on 27910.
Out-of-band (OOB) packets start with four `0xFF` bytes. Quake 2
tokenizes the whole packet, so the command ends at the first byte ≤ space.

| Message | Direction | Format |
|---|---|---|
| `query\n` | client → master | **no** `\xFF\xFF\xFF\xFF` prefix (exmaster takes it with one too) |
| `servers ` | master → client | OOB, then 6-byte entries (4 bytes IPv4, 2 bytes port, big-endian), no separators |
| `heartbeat\n` | server → master | OOB, followed by the same text as the `print` reply, every 300 s (`HEARTBEAT_SECONDS`) |
| `ping` | server → master | OOB, taken as a heartbeat |
| `shutdown` | server → master | OOB, when the server stops |
| `status\n` | master → server | OOB |
| `print\n` | server → master | OOB, the serverinfo infostring, then `<frags> <ping> "<name>"` per player |

The `servers` reply is split into packets of at most 1400 bytes, each with
the header. There is no end marker and no room for IPv6, so the master
listens on IPv4 only. An empty list is the header alone.

The serverinfo has `hostname`, `mapname`, `maxclients`, `deathmatch`,
`coop`, `dmflags`, `game` (the mod directory), `gamename` (the mod's name,
not the game's), `version`, and on most servers `protocol` (34; R1Q2 is
35 and q2pro 36, and both also accept 34). Players are the lines after
the serverinfo that have a quoted name.

## No challenge

No Quake 2 reply echoes anything the master sends, so a reply can't prove
that a server is at the address it came from. exmaster:

- answers a heartbeat from an address that isn't listed with `status`,
  and notes that it asked;
- takes a `print` only from an address it asked in the last 10 seconds,
  once, and lists the server for 15 minutes after each one;
- doesn't use the status a heartbeat carries, since heartbeats can be
  forged with a listed server's address;
- asks a listed server again on its heartbeat, at most once a minute;
- answers a `shutdown` with `status`, and drops the server if it doesn't
  reply within 10 seconds.

That keeps out servers that can't be reached, and makes a forged
registration take a forged heartbeat and a forged reply. It is no proof
that a server is at its address, as a Quake 3 challenge is: a blind
spoofer can make up the reply. `EXMASTER_MAX_PER_IP` keeps what one can
list under someone else's IP to 32 ports.

Whom the master asked is kept in a fixed table of 65,536 slots, keyed by
a salted hash of the address. Forged heartbeats from many addresses take
slots rather than growing it. A real server whose slot gets taken is
asked again at its next heartbeat.

## Games

Quake 2 masters list every Quake 2 server, and so does exmaster: a
`query` gets every listed server. It records each one as a game for its
own use: Action Quake 2 (`ActionQuake2`), recognised by `game`, `gamedir`
or `gamename` being `action` or by an `actionversion` key (37 of the 98
servers master.quakeservers.net listed on 2026-10-25), and `Quake2` for
everything else.
