# Real game servers against exmaster

`docker-compose.yml` runs three game servers from LinuxGSM's images
([docker-gameserver](https://github.com/GameServerManagers/docker-gameserver)),
which install the original server binaries and game data:

| Service | Server | Port | Master |
|---|---|---|---|
| `q3` | id's q3ded 1.32c | 27960 | 127.0.0.1:27950 |
| `q2` | id's quake2 3.20 | 27910 | 127.0.0.1:27900 |
| `qw` | nQuake's MVDSV 0.32 with KTX | 27500 | 127.0.0.1:27000 |

They use host networking and heartbeat exmaster on 127.0.0.1 only.

```
EXMASTER_LISTEN=q3:127.0.0.1:27950,q2:127.0.0.1:27900,qw:127.0.0.1:27000 \
  elixir --sname exmaster -S mix run --no-halt

gameservers/run.sh                  # start the servers, show the lists
python3 -I gameservers/query.py     # the lists, as clients ask for them
quakestat -q3m 127.0.0.1:27950      # qstat (apt install qstat) asks each server too
elixir --sname probe -e 'IO.inspect(:rpc.call(:"exmaster@#{elem(:inet.gethostname(), 1)}", Exmaster, :stats, []))'

docker compose -f gameservers/docker-compose.yml down
```

Server files are kept in `data/` (ignored by git), about 1.3 GB for the
three.

## Keeping the test servers off public masters

LinuxGSM's server configs point at public masters, and the engines get to
them in ways that are easy to miss, so each server uses a config of its
own from `config/` instead:

- LinuxGSM's Quake 3 `server.cfg` sets `sv_master1`-`5` to public masters,
  including a line that starts with `;`, which Quake 3 runs as a command.
  q3ded archives `sv_master2`-`5` in `q3config.cfg`, so `exmaster.cfg`
  clears them on every start. `+set sv_master2 ""` on the command line
  doesn't: Quake 3 takes it as `set` with no value.
- LinuxGSM's Quake 2 `server.cfg` runs `map` and then `setmaster` for
  three public masters. 3.20's `map` defers the rest of the command line
  and of the config until a client has loaded the map, which on a
  dedicated server never happens, so those `setmaster` lines (and anything
  after `+map`) never run. That is luck, not a setting, so `exmaster.cfg`
  replaces it and `+map` comes last. 3.20 also always heartbeats id's old
  master, 192.246.40.37; bound to 127.0.0.1 it can't send there
  (`NET_SendPacket ERROR: Invalid argument`).
- MVDSV always runs `ktx/server.cfg`, whose `setmaster` lists four public
  masters, before anything on the command line, so `exmaster.cfg` is
  mounted over it. MVDSV has no option to bind an address
  (`sv_local_addr` isn't one): it listens on 0.0.0.0:27500.

q3ded and quake2 are bound to 127.0.0.1, so they can't send anywhere else.
A capture of game-port UDP off loopback while the servers start is empty:

```
sudo tcpdump -i any -n 'udp and (port 27960 or port 27910 or port 27500) and not host 127.0.0.1'
```

LinuxGSM's monitor can't query Quake 2 3.20 or MVDSV with gamedig (qstat
can) and restarts them after five failures, every three minutes or so, so
`querymode="1"` has it check the process only.

## What it showed (2026-10-28)

- All three registered on their first heartbeat and were listed to
  `query.py` and to qstat, which then queried each server.
- The Quake 3 server, empty, was listed for `getservers 68 empty` and
  not for `getservers 68`; with a bot on, for both.
- A heartbeat within a minute of the last poll had the server asked at
  the end of the minute.
- Stopping MVDSV (`C`) had it dropped 10 seconds later. Quake 3's
  shutdown heartbeat is an ordinary `QuakeArena-1` heartbeat, so it stays
  listed until it expires.
- Restarting MVDSV: the new instance's heartbeat came during the check of
  the old one's `C`, and it was listed again when the check dropped the
  old entry, within 2 ms. LinuxGSM's monitor restarted it 7 times before
  `querymode="1"`, and it was never unlisted.
- Periodic heartbeats kept all three listed past the 15-minute expiry.
- qstat's QuakeWorld master query is `c\n\0`, which exmaster ignored
  until it took one-byte commands with trailing newlines and NULs.
