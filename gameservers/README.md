# Real game servers against exmaster

`docker-compose.yml` runs four game servers from LinuxGSM's images
([docker-gameserver](https://github.com/GameServerManagers/docker-gameserver)),
which install the original server binaries and game data:

| Service | Server | Port | Master |
|---|---|---|---|
| `q3` | id's q3ded 1.32c | 27960 | 127.0.0.1:27950 |
| `q2` | id's quake2 3.20 | 27910 | 127.0.0.1:27900 |
| `qw` | nQuake's MVDSV 0.32 with KTX | 27500 | 127.0.0.1:27000 |
| `bf1942` | DICE's bf1942_lnxded 1.61, patched to 1.612 | 14567, queries 23000 | 127.0.0.2:27900, lists TCP 28900 |

They use host networking and heartbeat exmaster on loopback only. The
GameSpy master is on 127.0.0.2, since Quake 2's has 127.0.0.1:27900 and
Battlefield 1942 can't heartbeat another port.

```
EXMASTER_LISTEN=q3:127.0.0.1:27950,q2:127.0.0.1:27900,qw:127.0.0.1:27000,gs:127.0.0.2:27900,gsl:127.0.0.2:28900 \
  elixir --sname exmaster -S mix run --no-halt

gameservers/run.sh                  # start the servers, show the lists
gameservers/run.sh bf1942           # or some of them
python3 -I gameservers/query.py     # the lists, as clients ask for them
quakestat -q3m 127.0.0.1:27950      # qstat (apt install qstat) asks each server too
quakestat -gsm,bfield1942 127.0.0.2:28900
elixir --sname probe -e 'IO.inspect(:rpc.call(:"exmaster@#{elem(:inet.gethostname(), 1)}", Exmaster, :stats, []))'

docker compose -f gameservers/docker-compose.yml down
```

Server files are kept in `data/` (ignored by git), about 1.3 GB for the
Quake servers and 170 MB for Battlefield 1942. The image installs a game
only into an empty `serverfiles`, and Battlefield 1942 reads its config
from there, so `run.sh` installs it with `docker compose run bf1942
auto-install` and copies `config/bf1942/serversettings.con` in before it
first starts.

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
- Battlefield 1942 heartbeats `master.gamespy.com` and the All-Seeing
  Eye's `master.udpsoft.com` and `master2.udpsoft.com`, none of which
  resolve any more. `extra_hosts` points the first at exmaster on
  127.0.0.2 and the others at 127.0.0.3, where nothing listens. Its
  config sets `game.serverIP 127.0.0.1`, which binds the game and
  All-Seeing Eye ports; its GameSpy query port, 23000, listens on 0.0.0.0
  whatever it says.

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

## What it showed for Battlefield 1942 (2026-10-28)

- The server heartbeats `\heartbeat\23000\gamename\bfield1942` from its
  query port as it starts and every 300 seconds, and the All-Seeing Eye's
  `\hb\14690\bf1942` to the same master port.
- It answered exmaster's 16-character challenge with the right
  `\validate\` and was listed on its first heartbeat; each periodic
  heartbeat had it asked again and kept it listed.
- Stopped with Ctrl+C, as LinuxGSM stops it, it sends no
  `\statechanged\2`, so it stays listed until it expires.
- The list came back over TCP to BF1942-Master's Python client with
  enctype 2, to `query.py` without encryption, and to qstat, which asks
  as GameSpy Arcade for the text form and then queried the server
  (`0/16 berlin conquest exmaster test`).

