# Real game servers against exmaster

`docker-compose.yml` runs fifteen game servers from LinuxGSM's images
([docker-gameserver](https://github.com/GameServerManagers/docker-gameserver)),
which install the original server binaries and game data:

| Service | Server | Port | Master |
|---|---|---|---|
| `q3` | id's q3ded 1.32c | 27960 | 127.0.0.1:27950 |
| `q2` | id's quake2 3.20 | 27910 | 127.0.0.1:27900 |
| `qw` | nQuake's MVDSV 0.32 with KTX | 27500 | 127.0.0.1:27000 |
| `bf1942` | DICE's bf1942_lnxded 1.61, patched to 1.612 | 14567, queries 23000 | 127.0.0.2:27900, lists TCP 28900 |
| `mohaa` | mohaa_lnxded 1.12 with the Reborn patch RC3.5.1 | 12203, queries 12300 | 127.0.0.2:27900, lists TCP 28900 |
| `rtcw` | iortcw's iowolfded | 27961 | 127.0.0.1:27950 |
| `wet` | id's etded 2.60b | 27962 | 127.0.0.1:27950 |
| `etl` | ET: Legacy's etlded | 27963 | 127.0.0.1:27950 |
| `xnt` | Xonotic's dedicated server (DarkPlaces) | 26000 | 127.0.0.1:27950 |
| `wf` | Warfork's wf_server, from Steam | 44400, HTTP 44444 | 127.0.0.1:27950 |
| `cod` | Activision's cod_lnxded 1.5 | 28960 | 127.0.0.1:20510, labelled `CoD` |
| `coduo` | Activision's coduo_lnxded 1.51 | 28961 | 127.0.0.1:20610, labelled `CoDUO` |
| `cod2` | Activision's cod2_lnxded 1.3 | 28962 | 127.0.0.1:20710, labelled `CoD2` |
| `cod4` | CoD4X 1.8's cod4x18_dedrun | 28964 | 127.0.0.1:20810, labelled `CoD4` |
| `sof2` | Raven's sof2ded 1.03 | 20100 | 127.0.0.1:20110, labelled `SoF2` |

They use host networking and heartbeat exmaster on loopback only. The
GameSpy master is on 127.0.0.2, since Quake 2's has 127.0.0.1:27900 and
Battlefield 1942 and MOH:AA can't heartbeat another port.

```
EXMASTER_LISTEN=q3:127.0.0.1:27950,q2:127.0.0.1:27900,qw:127.0.0.1:27000,gs:127.0.0.2:27900,gsl:127.0.0.2:28900,\
q3:127.0.0.1:20510=CoD,q3:127.0.0.1:20610=CoDUO,q3:127.0.0.1:20710=CoD2,q3:127.0.0.1:20810=CoD4,q3:127.0.0.1:20110=SoF2 \
  elixir --sname exmaster -S mix run --no-halt

gameservers/run.sh                  # start the servers, show the lists
gameservers/run.sh bf1942           # or some of them
python3 -I gameservers/query.py     # the lists, as clients ask for them
quakestat -q3m 127.0.0.1:27950      # qstat (apt install qstat) asks each server too
quakestat -rwm 127.0.0.1:27950
quakestat -cod2m 127.0.0.1:20710        # and -cod4m 127.0.0.1:20810
quakestat -gsm,bfield1942 127.0.0.2:28900
quakestat -gsm,mohaa 127.0.0.2:28900
elixir --sname probe -e 'IO.inspect(:rpc.call(:"exmaster@#{elem(:inet.gethostname(), 1)}", Exmaster, :stats, []))'

docker compose -f gameservers/docker-compose.yml down
```

Server files are kept in `data/` (ignored by git): about 1.3 GB for the
Quake servers, 170 MB for Battlefield 1942, 3 GB for MOH:AA, and 3.6 GB
for RTCW, ET, ET: Legacy, Xonotic and Warfork together. The image
installs a game only into an empty `serverfiles`. q3, q2 and qw mount a
config there, and Battlefield 1942 reads its config from there, so
`run.sh` installs those four first, with only `/data` mounted, whenever
their executable is missing, and copies
`config/bf1942/serversettings.con` in before Battlefield 1942 first
starts. The others mount only their LinuxGSM instance config, which is
outside `serverfiles`, and the image installs them as they first start.

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
- MOH:AA heartbeats `master.gamespy.com` only; the Reborn patch's
  `mohmaster.2015.com` and GameSpy's `master0` and `master1`, named in its
  config, aren't contacted, and none of them resolve. `extra_hosts` points
  the first at exmaster on 127.0.0.2 and the others at 127.0.0.3. Its
  instance config, `config/mohaaserver.cfg`, is mounted outside
  `serverfiles`, so the image installs it; it binds 127.0.0.1, but the
  query port, 12300, listens on 0.0.0.0. It also sets `sv_gamespy 1`
  before `+map` (see [docs/gamespy.md](../docs/gamespy.md#medal-of-honor-allied-assault))
  and `querymode="1"`, without which LinuxGSM's monitor, which can't
  query it, starts a second instance.
- RTCW, ET, ET: Legacy, Xonotic and Warfork don't run LinuxGSM's server
  configs at all: the start line in their instance config sets what they
  need, the master (`sv_master1`, Warfork's `masterservers`) included,
  and binds 127.0.0.1. LinuxGSM's RTCW config sets its public masters
  with `seta`, which iortcw would keep in its own config, so it must never
  have run in `data/rtcw`. ET 2.60b heartbeats port 27950 whatever port
  `sv_master1` names. iortcw and ET: Legacy open IPv6 sockets on `[::]`
  unless told otherwise (`net_enabled 1`, `net_ip6 ::1`), as do Xonotic
  (`net_address_ipv6 ::1`) and Warfork (`sv_ip6 ::1`). Xonotic also
  heartbeats masters of its own, `sv_masterextra1`-`3`
  (`master1.xonotic.org:42863`, `master2.xonotic.org:27950`); its start
  line points them at 127.0.0.3, since `+set` with an empty value sets
  nothing here either.
- The four Call of Duty servers ignore `sv_master1` and heartbeat
  Activision's masters by name (`codmaster`, `coduomaster`, `cod2master`
  and `cod4master.activision.com`), each on a port of its own, so
  `extra_hosts` points those at 127.0.0.1, where exmaster has a labelled
  listener for each. The binaries also name Activision's CD-key servers
  and CoD4X's update server, which go to 127.0.0.3. CoD4X opens an IPv6
  socket too, on `[::]` unless `net_ip6 ::1` keeps it on loopback. SoF2
  takes `sv_master1` but sends to its port 20110, whatever port it
  names; like the five above, none of them runs LinuxGSM's server
  config.

q3ded, quake2 and the others above are bound to loopback, so they can't
send anywhere else. A capture of game-port UDP off loopback while the
servers start is empty:

```
sudo tcpdump -i any -n 'udp and (port 27960 or port 27910 or port 27500 or port 27961 or port 27962 or port 27963 or port 26000 or port 44400 or port 28960 or port 28961 or port 28962 or port 28964 or port 20100) and not host 127.0.0.1 and not host ::1'
```

LinuxGSM's monitor can't query Quake 2 3.20, MVDSV, Battlefield 1942 or
MOH:AA with gamedig (qstat can), and queries ET and ET: Legacy on 27960,
the port it takes from their server configs. It restarts a server after
five failures, every three minutes or so, or starts a second instance,
so `querymode="1"` has it check the process only for those six.

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

## What it showed for MOH:AA (2026-10-28)

- Installed from an empty `data/` by the image itself, since nothing is
  mounted under `serverfiles`. It registered on its first heartbeat,
  answering exmaster's challenge under `M5Fdwc`.
- Every heartbeat was `\heartbeat\12300\gamename\mohaa\statechanged\`:
  at start, on `send heartbeat`, 300 seconds after that one, and when
  LinuxGSM stopped it. After the stop it stayed listed, as expected.
- `query.py`, a client asking as `mohaa_lnxded` does (no `\enctype\`),
  and qstat (`-gsm,mohaa`) got the list; qstat then queried the server
  (`0/14 dm/mohdm1 Round-Based-Match exmaster-test`).

## What it showed for RTCW, ET, ET: Legacy, Xonotic and Warfork (2026-10-28)

The five, with q3, q2, qw and bf1942, from an empty `data/`:

- Each registered on its first heartbeat: RTCW as `wolfmp`, protocol 60;
  ET and ET: Legacy as `et`, 84; Xonotic as `Xonotic`, 3; Warfork as
  `Warfork`, 26. `query.py` got each from its own query, and qstat
  `-rwm` got RTCW and queried it.
- A capture of their game ports off loopback stayed empty.
- LinuxGSM started ET and ET: Legacy on port 27960, taken from its own
  server configs, until the ports were written out on their start lines;
  each Quake 3 engine then moved one port up from a taken one, which put
  RTCW on 27962.
- LinuxGSM's monitor, which can't query Battlefield 1942, started a
  second instance of it on 23001, found two and restarted it, until
  `querymode="1"`.

## What it showed for Call of Duty and SoF2 (2026-10-28)

- From an empty `data/`, each registered on its first heartbeat, on its
  labelled listener: Call of Duty as `CoD`, protocol 6; United Offensive
  as `CoDUO`, 22; Call of Duty 2 as `CoD2`, 118; Call of Duty 4 as
  `CoD4`, 6; SoF2 as `SoF2`, 2004. Their tags were `COD-1`, `COD-1`,
  `COD-2`, `COD-4` and `SoF2MP-1`.
- `query.py` got each from its own listener; qstat `-cod2m` and `-cod4m`
  got Call of Duty 2 and 4 and queried them. qstat `-sof2m` asks
  `getservers 2004 SOF2FULL`, an option exmaster doesn't know, so it
  asks for neither empty nor full servers and doesn't get an empty one.
- Stopped by LinuxGSM, Call of Duty sent `heartbeat flatline` and SoF2
  `heartbeat flatline SoF2MP-1`, twice; exmaster asked each, got no
  answer, and dropped it 10 seconds later.
- A capture of their game ports off loopback, IPv6 included, stayed
  empty.

