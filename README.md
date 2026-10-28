# master.pingu.gg

Master servers in Elixir/OTP for Quake 3 based games, Quake 2,
QuakeWorld and Battlefield 1942 (GameSpy). Game servers heartbeat it and
clients ask it for server lists. It keeps the lists in memory (ETS) and
nothing else: no database, no server browser, no upstream masters.
[gameservers/](gameservers/README.md) runs real Quake 3, Quake 2,
QuakeWorld and Battlefield 1942 servers against it in Docker.

The protocols are described in [docs/quake3.md](docs/quake3.md),
[docs/quake2.md](docs/quake2.md), [docs/quakeworld.md](docs/quakeworld.md)
and [docs/gamespy.md](docs/gamespy.md).

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
| `EXMASTER_LISTEN` | `q3:27950,q2:27900,qw:27000` | comma-separated `protocol:[host:]port[=label]`; protocols `q3`, `q2`, `qw`, `gs` and `gsl` |
| `EXMASTER_PEERS` | none | comma-separated node names to share server lists with (see [Several nodes](#several-nodes)) |
| `EXMASTER_MAX_SERVERS` | `16384` | servers per master, on each node |
| `EXMASTER_MAX_PER_IP` | `32` | servers per IP address, per master, on each node |
| `EXMASTER_MAX_UNKNOWN_TAG` | `512` | Quake 3 servers with a heartbeat tag that's neither built in nor `DarkPlaces` |
| `EXMASTER_LOG_LEVEL` | `info` | `debug`, `info`, `warning`, `error` |

A protocol can listen on several ports. A Quake 3 listener can have a
label, `q3:27960=UrbanTerror`, to be a game's own master: its servers are
listed in a store of their own, apart from Quake 3's, and every query to
it is answered from that store. Urban Terror and Smokin' Guns need this,
since on the wire they look like Quake 3 (see
[Listeners](docs/quake3.md#listeners)). `Exmaster.stats()` and
`Exmaster.servers/1` take the label as the master's name. Quake 3 listens
on `::` with IPv4 mapped in, or on IPv4 alone where there is no IPv6.
Quake 2 and QuakeWorld lists hold only IPv4 addresses, so they listen on
IPv4.

GameSpy's master is two listeners: `gs` takes heartbeats over UDP and
`gsl` sends lists over TCP, both from one store. They aren't in the
default, since Battlefield 1942 heartbeats port 27900, Quake 2's master
port, and has it compiled in: give them an address of their own, and bind
the Quake 2 listener to another
(`q2:203.0.113.1:27900,gs:203.0.113.2:27900,gsl:203.0.113.2:28900`).
Their lists hold only IPv4 too.

### Several nodes

exmaster can run on several hosts behind one DNS name with an A record
for each. A game server heartbeats one of them and a client asks one of
them, maybe another, so the nodes share their server lists: every node
answers with all of them. Each node still asks and checks only the
servers that heartbeat it, and a server's replies come back to the node
that asked, so challenges, rate limits and the limits above stay per
node.

The nodes are connected with Erlang distribution. Give each a name, the
same cookie, and the list of nodes (its own name in it is skipped):

```
RELEASE_DISTRIBUTION=name RELEASE_NODE=exmaster@10.0.0.1 RELEASE_COOKIE=<secret> \
EXMASTER_PEERS=exmaster@10.0.0.1,exmaster@10.0.0.2 \
  _build/prod/rel/exmaster/bin/exmaster start
```

A node tries to connect to the others every 5 seconds. Entries are sent
with their expiry on the OS clock, so the hosts' clocks have to agree, as
NTP keeps them. Distribution
needs TCP 4369 (epmd) and a port per node, which
`ERL_AFLAGS="-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100"`
pins. It isn't encrypted, and a node with the cookie can run any code on
the others, so keep it to a private network such as WireGuard or
Tailscale, with those ports closed to the internet.

When nodes lose each other, each goes on answering with what it had, and
what it had from the others expires within 15 minutes unless they come
back. When they do, each sends its list to the other.

## How it works

```
Exmaster.Supervisor
├── Exmaster.RateLimit        token buckets in a public ETS table
├── Exmaster.PG               the pg scope the stores share their lists in
├── Exmaster.Store            one per master: :exmaster_q3, :exmaster_q2, :exmaster_qw,
│                             :exmaster_gs, and :exmaster_q3_<label> per label
├── Exmaster.Cluster          connects to EXMASTER_PEERS, if set
└── Exmaster.Listeners
    ├── Exmaster.Listener     one per UDP socket, running Q3.Master, Q2.Master,
    │                         QW.Master or GS.Master
    └── Exmaster.GS.ListServer  one per TCP socket, with a task per connection
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
- With several nodes, each store sends the servers it adds, replaces and
  drops to the same master's store on the others, which keep them in a
  second table, keyed by address and node. Queries answer from both
  tables; a server two nodes list is sent once, as the node that heard
  from it last has it. A store that joins, after
  a restart or a split, gets each other node's whole list, which replaces
  what it had from that node. Entries travel with their times on the OS
  clock, and each node converts to and from its monotonic clock. See
  `Exmaster.Store`.
- Token buckets are one integer each (GCRA), updated with
  compare-and-swap. Listeners share them without a process in between.
  Time is counted in units of 1/rate ms, so byte costs don't round.
- A packet that makes a protocol raise is dropped and logged at most once
  a minute, so a packet like that can't restart a listener in a loop.
- Each protocol has its own module for the wire format (`Exmaster.Q3`,
  `Exmaster.Q2`, `Exmaster.QW`, `Exmaster.GS`) and one for the master
  (`*.Master`). The
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

- game names from labels, `gamename` and the tag;
- unknown tags can't claim a built-in game, and are capped;
- every protocol a server reported in the last 15 minutes is kept;
- ET clients always get empty and full servers;
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

### GameSpy (Battlefield 1942)

A heartbeat, `\heartbeat\<query port>\gamename\bfield1942`, has the
master send `\info\\secure\<challenge>` to the server's query port.
The server is listed once a reply from there carries the challenge's
`\validate\`, gsmsalg under the game's key. The challenges are stateless,
as Quake 3's: an HMAC of the address, the listener and a 5-second bucket.
Clients get the list over TCP, as 6-byte entries encrypted with GameSpy's
enctype 2 when they ask for it, as Battlefield 1942 does. The list
server takes 64 connections at once, 5 an IP at once then one every 3
seconds, gives each 5 seconds to ask and closes it after 10. See
[docs/gamespy.md](docs/gamespy.md).

### Limits, for all of them

- Server list queries: 5 per IP at once, then one every 3 seconds.
  Replies to everyone together: 256 KB a second, bursts of 1 MB. Each
  reply costs at least 1400 bytes, so queries that match nothing still pay
  for the table scan.
- A heartbeat from an address that isn't listed has the master send to
  it: 64 per IP at once, then one a second.
- A heartbeat from a listed server has it asked again at most once a
  minute. One that comes sooner has it asked when the minute is over.
- Quake 3 queries to one address, from the Quake 3 master and the
  labelled ones together, go at least 2 seconds apart, first queries
  included: a server listed by two of them shares their address, and its
  flood protection counts queries by IP. One that would come sooner is
  sent when the 2 seconds are over. A master sends a server it doesn't
  list a first query at most every 10 seconds, so forged heartbeats to
  one master can't keep those 2 seconds from the master that lists it.
- A shutdown (a flatline tag, `shutdown`, `C`, `\statechanged\2`) can be
  forged, so the server is asked, and dropped if it doesn't answer
  within 10 seconds of that. The check shares the once-a-minute
  allowance with heartbeats: a second query right after one could fall
  to the server's own flood protection, and the server would be dropped.
  A shutdown inside the minute has the check wait for its end. A server
  that restarts sends a shutdown and, a moment later, a heartbeat from
  its new instance; that heartbeat is put off, since the check spent the
  minute, and is answered as one from an unlisted address when the check
  drops the old entry.

## What it doesn't do

- Pulling lists from upstream masters, and the budget rules for them.
- Polling servers every 5 minutes, and `getstatus` for player lists.
- A51 forwarding ports and duplicate ports. Both come from upstream
  lists or need status replies.
- Surviving a restart: servers come back with their next heartbeat,
  within 5 minutes for ioquake3. With several nodes, the others' servers
  come back at once.
