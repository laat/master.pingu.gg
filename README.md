# exmaster

Master servers in Elixir/OTP for Quake 3 based games, Quake 2 and
QuakeWorld. Game servers heartbeat it and clients ask it for server lists.
It keeps the lists in memory (ETS) and nothing else: no database, no
server browser, no upstream masters.
[gameservers/](gameservers/README.md) runs real Quake 3, Quake 2 and
QuakeWorld servers against it in Docker.

The protocols are described in [docs/quake3.md](docs/quake3.md),
[docs/quake2.md](docs/quake2.md) and [docs/quakeworld.md](docs/quakeworld.md).

## Running

Erlang/OTP 28 and Elixir 1.20, pinned in `mise.toml` (`mise install`).
There are no dependencies.

```
mix test
mix run --no-halt                         # q3:27950, q2:27900, qw:27000

MIX_ENV=prod mix release
EXMASTER_LISTEN=q3:27950,q2:27900,qw:27000 _build/prod/rel/exmaster/bin/exmaster start
_build/prod/rel/exmaster/bin/exmaster rpc 'IO.inspect(Exmaster.stats())'
_build/prod/rel/exmaster/bin/exmaster rpc 'IO.inspect(Exmaster.servers(:q3))'
```

The release includes the Erlang runtime, so it has to be built on the
OS and architecture it runs on.

| Variable | Default | Meaning |
|---|---|---|
| `EXMASTER_LISTEN` | `q3:27950,q2:27900,qw:27000` | comma-separated `protocol:[host:]port[=label]` |
| `EXMASTER_MAX_SERVERS` | `16384` | servers per master |
| `EXMASTER_MAX_PER_IP` | `32` | servers per IP address, per master |
| `EXMASTER_MAX_UNKNOWN_TAG` | `512` | Quake 3 servers with a heartbeat tag that's neither built in nor `DarkPlaces` |
| `EXMASTER_LOG_LEVEL` | `info` | `debug`, `info`, `warning`, `error` |

A protocol can listen on several ports. A Quake 3 listener can have a
label, `q3:27900=UrbanTerror`, to mirror a game's own master: servers that
heartbeat it are listed under the label, and anonymous queries to it ask
for that game (see [Listeners](docs/quake3.md#listeners)). Quake 3 listens
on `::` with IPv4 mapped in, or on IPv4 alone where there is no IPv6.
Quake 2 and QuakeWorld lists hold only IPv4 addresses, so they listen on
IPv4.

## How it works

```
Exmaster.Supervisor
├── Exmaster.RateLimit        token buckets in a public ETS table
├── Exmaster.Store            one per master: :exmaster_q3, :exmaster_q2, :exmaster_qw
└── Exmaster.Listeners
    └── Exmaster.Listener     one per socket, running Q3.Master, Q2.Master or QW.Master
```

- Each socket has a listener process that takes packets one at a time,
  `{:active, 100}`. Replies go out through the socket the packet came in
  on: a server behind NAT may only take packets from the address it sent
  its heartbeat to. For the same reason a listed server is only asked
  again by the listener it is listed through; heartbeats and shutdowns
  for it that come in on another are ignored.
- Each master's servers are in an ETS table owned by its `Store`. Listeners
  read the table directly. Only the store writes it, so the limits are
  checked against one count, and only if the entry is still the one the
  listener built its update from, so two listeners answering for one
  server can't lose each other's changes. A listener that restarts loses
  nothing.
- Token buckets are one integer each (GCRA), updated with
  compare-and-swap. Listeners share them without a process in between.
  Time is counted in units of 1/rate ms, so byte costs don't round.
- A packet that makes a protocol raise is dropped and logged at most once
  a minute, so a packet like that can't restart a listener in a loop.
- Each protocol has its own module for the wire format (`Exmaster.Q3`,
  `Exmaster.Q2`, `Exmaster.QW`) and one for the master (`*.Master`). The
  protocols share no code, and each master has its own copy of the code
  that decides when a listed server is asked again; Quake 2 and
  QuakeWorld each have their own table of whom they asked. What is shared
  has no protocol in it: sockets, stores and rate limits.

### Quake 3

Only an `infoResponse` that echoes a valid challenge is trusted. A
heartbeat from an address that isn't listed gets a `getinfo` with a
stateless challenge, an HMAC of the address, the listener's local
address and port, a 5-second time bucket and the class the tag implies (`Exmaster.Q3.Challenge`). It stores
nothing, so forged heartbeats can't fill memory. A server is listed for
15 minutes after each valid reply, and is dropped then unless a heartbeat
had it asked again. Other rules:

- game names from fingerprints, labels, `gamename` and the tag;
- unknown tags can't claim a built-in game, and are capped;
- every protocol a server reported in the last 15 minutes is kept;
- ET clients always get empty and full servers, and ET: Legacy's;
- `getservers` and `getserversExt` options, packets of at most 1400 bytes,
  EOT on the last.

### Quake 2 and QuakeWorld

Their servers heartbeat with no challenge, and the reply to `status`
echoes nothing. A heartbeat from an address that isn't listed gets
`status`. A reply is only taken from an address asked in the last 10
seconds, once. That keeps out servers that can't be reached, and makes a
forged registration take two forged packets. It doesn't prove a server
is at its address the way a Quake 3 challenge does, since a blind spoofer
can make up the reply. `max_per_ip` keeps what one can list under someone
else's IP to 32 ports.

Each of the two masters remembers whom it asked in a
fixed table of 65,536 slots (`:atomics`), keyed by a salted hash. Forged
heartbeats from many addresses take slots rather than growing it. A real
server whose slot gets taken is asked again at its next heartbeat.

### Limits, for all three

- Server list queries: 5 per IP at once, then one every 3 seconds.
  Replies to everyone together: 256 KB a second, bursts of 1 MB. Each
  reply costs at least 1400 bytes, so queries that match nothing still pay
  for the table scan.
- A heartbeat from an address that isn't listed has the master send to
  it: 64 per IP at once, then one a second.
- A heartbeat from a listed server has it asked again at most once a
  minute. One that comes sooner has it asked when the minute is over.
- A shutdown (a flatline tag, `shutdown`, `C`) can be forged, so the
  server is asked, and dropped if it doesn't answer within 10 seconds of
  that. The check shares the once-a-minute allowance with heartbeats: a
  second query right after one could fall to the server's own flood
  protection, and the server would be dropped. A shutdown inside the
  minute has the check wait for its end. A server that restarts sends a
  shutdown and, a moment later, a heartbeat from its new instance; that
  heartbeat is put off, since the check spent the minute, and is answered
  as one from an unlisted address when the check drops the old entry.

## What it doesn't do

- Pulling lists from upstream masters, and the budget rules for them.
- Polling servers every 5 minutes, and `getstatus` for player lists.
- A51 forwarding ports and duplicate ports. Both come from upstream
  lists or need status replies.
- Surviving a restart: servers come back with their next heartbeat,
  within 5 minutes for ioquake3.
