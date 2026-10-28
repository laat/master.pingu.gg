# QuakeWorld master server protocol

The QuakeWorld master is `Exmaster.QW.Master`, with the wire format in
`Exmaster.QW`. It works the same way as the Quake 2 one
([quake2.md](quake2.md)). Sources: id's GPL Quake source,
`QW/client/protocol.h` and `QW/server/sv_main.c`, and the live masters.

QuakeWorld masters listen on 27000 (`PORT_MASTER`), servers on 27500
(`PORT_SERVER`). The protocol version is 28 (`PROTOCOL_VERSION`), which
every client in use speaks. Commands are one byte; out-of-band (OOB)
packets start with four `0xFF` bytes.

| Message | Direction | Format |
|---|---|---|
| `c\n` | client → master | **no** `\xFF\xFF\xFF\xFF` prefix (exmaster takes it with one too); qstat sends `c\n\0` |
| `d\n` | master → client | OOB (`M2C_MASTER_REPLY`), then 6-byte entries: 4 bytes IPv4, 2 bytes port, big-endian |
| `a\n<seq>\n<players>\n` | server → master | `S2M_HEARTBEAT`, every few minutes, no prefix (taken with one too) |
| `C\n` | server → master | `S2M_SHUTDOWN` |
| `status\n` | master → server | OOB |
| `n` | server → master | OOB (`A2C_PRINT`): the serverinfo, then one line per client (below) |

id's master only looked at the first byte. exmaster takes `c` and `C`
followed by nothing but newlines and NULs.

The `d` reply is split into packets of at most 1400 bytes, each with the
header. There is no end marker and no room for IPv6, so the master
listens on IPv4 only.

A client line in the status reply is

```
<userid> <frags> <minutes connected> <ping> "<name>" "<skin>" <topcolor> <bottomcolor> ["<team>"]
```

(`SVC_Status`; newer servers add the team). MVDSV includes spectators, with
frags -9999, a negative ping, and the name prefixed `\s\`; exmaster
doesn't count them as players.

Serverinfo keys start with `*` when only the server sets them: `*version`
(`MVDSV 1.20`, `FTE ...`), `*gamedir` (`qw`, `fortress`, `ktx`), `*progs`.
The map is in `map`, not `mapname`. KTX, the usual game mod, puts its mode
in `mode`.

**No challenge**, as in Quake 2: a heartbeat from an address that isn't
listed gets `status`, a reply is only taken from an address asked in the
last 10 seconds, once, a listed server is asked again on its heartbeat at
most once a minute, and a `C` has it asked and dropped if it doesn't
reply within 10 seconds. See [quake2.md](quake2.md#no-challenge).

**Team Fortress.** exmaster records QuakeWorld Team Fortress as a game of
its own, `QWTF`: `*gamedir` is `fortress`, or `teamplay` ends in a tag
for the TF variant (`1?TF2.7`, `651?TF2.5` for CustomTF,
`21?TeamFortress` for MegaTF). 22 servers on 2026-10-25. Everything else
is `QuakeWorld`. A `c` query gets every listed server.

**Not game servers.** QTV relays (`*version` QTV..., for watching games)
and qwfwd forwarding proxies heartbeat QuakeWorld masters too, and
clients look for them there, so they are listed like servers. On
2026-10-25 they were 171 of the 651 addresses public masters listed that
answered (79 QTV, 92 qwfwd).

**FTE servers** can accept both Quake and QuakeWorld clients, and may
heartbeat both a QuakeWorld master and a Quake 3-style one as `FTE-Quake`
(see [quake3.md](quake3.md#quake-on-quake-3-masters)).
