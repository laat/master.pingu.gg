# GameSpy QR2 and server browsing: Battlefield Vietnam

This is GameSpy's second master protocol, Query and Reporting 2 (QR2),
which game servers heartbeat over UDP, and its list side, server
browsing, which clients ask over TCP; as Battlefield Vietnam speaks them,
and how exmaster speaks them: `Exmaster.QR2` and `Exmaster.QR2.Master`
(heartbeats), `Exmaster.SB`, `Exmaster.SB.Crypt` and
`Exmaster.SB.ListServer` (lists). GameSpy's first protocol is in
[gamespy.md](gamespy.md). The sources used here are:

- The Battlefield Vietnam Linux dedicated server, 1.21, as LinuxGSM
  installs it: its strings and its traffic, against a master that logged
  every packet and then against exmaster, on 2026-10-28.
- GameSpy's SDK (`qr2/qr2.c`, `serverbrowsing/sb_serverlist.c`,
  `sb_crypt.c`), in https://github.com/nitrocaster/GameSpy.
- OpenSpy's masters (https://github.com/openspy/openspy-core, `code/qr`
  and `code/serverbrowsing`), which players use now.
- aluigi's gslist.cfg, for the keys.
- OpenSpy's list server, `master.openspy.net:28910`, asked once for
  `bfvietnam` on 2026-10-28: 11 servers. The client in
  `gameservers/query.py` decrypted that list, and then exmaster's.

## Where Battlefield Vietnam servers go

| Port | Use |
|---|---|
| UDP 27900 | master: heartbeats, `bfvietnam.master.gamespy.com`, and the available check, `bfvietnam.available.gamespy.com` |
| TCP 28910 | master: lists, `bfvietnam.ms0.gamespy.com` (the SDK names a game's `<game>.ms<n>`, n a hash of the name, 0 to 19) |
| UDP 15567 | server: the game |
| UDP 23000 | server: GameSpy queries and its heartbeats (`game.gameSpyPort`), on 0.0.0.0 whatever `game.serverIP` says |
| UDP 14690 | server: All-Seeing Eye queries |

The server binary names the masters by the patterns
`%s.available.gamespy.com` and `%s.master.gamespy.com`, and also
`gamestats.gamespy.com` and the All-Seeing Eye's `master.udpsoft.com` and
`master2.udpsoft.com`. GameSpy's hosts no longer resolve; the community
runs OpenSpy, whose hosts are the same with `openspy.net`. The master's
UDP port is 27900, as for GameSpy's first protocol and Quake 2, so the
three can share it (see
[Sharing port 27900](gamespy.md#sharing-port-27900)).
`game.serverInternet 1` has the server heartbeat at all; LinuxGSM's
config has 0.

## Packets

A server's packets start with a type and its instance key, 4 random bytes
it picks as it starts; the master's with `FE FD`, the type and the key.
The server ignores a master packet whose key isn't its own.

| Type | Direction | Payload |
|---|---|---|
| `09` available | server → master, from a port of its own | key 0, `bfvietnam` NUL; answered `FE FD 09 00 00 00 00` |
| `03` heartbeat | server → master, from its query port | key NUL value NUL ..., an empty key, then its players and teams |
| `FE FD 01` challenge | master → server | key, the challenge, NUL |
| `01` response | server → master | key, gsseckey(challenge, game key), NUL |
| `FE FD 0A` registered | master → server | key |
| `08` keepalive | server → master | key |

The first heartbeat, about 1 KB, had 49 keys: `localip0`, `localport`,
`natneg 0`, `statechanged 3`, `gamename bfvietnam`, `hostname`,
`hostport 15567`, `mapname`, `gametype`, `numplayers`, `maxplayers`,
`gamemode`, `password`, `gamever v1.21`, `dedicated` and the server's
rules (some empty, as `bot_skill`), then the players' and teams' key
names and values. As the SDK has it, the server heartbeats with
`statechanged 3` every 10 seconds until the master answers, then every 60
seconds (0), on a change at most every 10 seconds (1), and as it exits
(2); keepalives every 20 seconds. Captured: an available check, then the
heartbeat, a keepalive and, once challenged, the response; heartbeats
every 60 seconds, each answered when challenged; `statechanged 2` from
an instance being stopped.

## The challenge

The response is gsmsalg (gsseckey) of the challenge under the game's
secret key, as in GameSpy's first protocol: Battlefield Vietnam's key
is `h2P9dJ`, and the server's responses to two challenges matched
`Exmaster.GS.validate/2` with it. The SDK reads the challenge's last 14
characters as 2 hex digits of options and the server's public IP and
port in hex, and takes up to 64. exmaster's are OpenSpy's 20: 6 of an
HMAC of the address, the listener, a 5-second bucket, the game and the
instance key, `00`, then the address, as `CUZDhR007F0000015A3C` was for
127.0.0.1:23100.

## How exmaster lists servers

1. **Heartbeat from an address that isn't listed.** The master answers
   with a challenge to the address the heartbeat came from, the query
   port, with the heartbeat's instance key, and keeps what the heartbeat
   said aside (below).
2. **Response, from that address, with that key.** The server is listed
   for 15 minutes, with what its heartbeat with that key said:
   `hostname`, `gamever`, `numplayers`, `maxplayers`, `localip0`,
   `localport`, and the first 64 keys, cut to 32 bytes and their values
   to 64, for lists. The master sends `FE FD 0A`.
3. **Heartbeat from a listed server, with its instance key.** It is asked
   again, at most once a minute, with that key; a heartbeat inside the
   minute has it asked when the minute is over. Only the listener it is
   listed through asks it.
4. **Heartbeat from a listed server with another key.** A restarted
   server's, or a forger's: it is asked about as one from an address that
   isn't listed, and a response has the entry take the new key.
5. **`statechanged 2` from a listed server.** It can be forged, so the
   server is asked, with the key it is listed with, and dropped if it
   doesn't answer within 10 seconds.

Heartbeats can be forged, and carry everything a server says about
itself, so what one says is kept aside by address and instance key, 75
seconds at most, two an address (the latest with the key the server is
listed with, and the latest with another), 16,384 addresses in all. It is
listed only when a response with that key comes: the server only answers
a challenge with its own key, which a forger who isn't on the path
doesn't know. Questions to a listed server go with its own key, so forged
heartbeats can't have it ignore them. Keepalives are ignored; anyone can
send one.

## The list

A client connects to TCP 28910 and sends a request: a 2-byte length,
then `00`, the protocol and encoding versions (1, 3), its game version
(4 bytes), the game to list, the game it is (NUL-terminated), an 8-byte
challenge, a filter (SQL-like, `numplayers > 0`) and the fields it wants
(`\hostname\numplayers...`), NUL-terminated, and 4 bytes of options.

The answer:

```
10 xor 0xEC, then 10 bytes: 2 of options (0), 8 random
25 xor 0xEA, then 25 random bytes
encrypted:
  the client's IP, the game's default query port (0xFFFF: an error, and its message)
  the number of fields; each: type (0, text), name, NUL
  the number of popular values (0)
  a server: flags, IPv4; its port, if not the game's default (flag 16);
    its local IP (flag 2) and port (flag 32); each field as FF, value, NUL (flag 64)
  00 FF FF FF FF
```

The client folds the master's 25 bytes into its 8-byte challenge with
the secret key of the game it is, and keys `Exmaster.SB.Crypt` with the
result: GameSpy's GOACrypt (aluigi's enctypeX), a 256-card deck
reshuffled with every byte. So any game the master knows may list any
other, as on GameSpy's masters: Battlefield Vietnam asks as `bfvietnam`,
gslist as GameSpy Arcade, `gslive`, key `Xn221z`. A request from a game
the master doesn't know gets nothing; one for a game it doesn't list gets
the error.

- The filter is ignored: every server is listed, as on exmaster's
  GameSpy master.
- Only list requests are answered, once, and the connection closed. Not
  done: a server's full rules from the master (request 1), messages to
  servers for NAT negotiation (2), updates as servers come and go
  (option 4), groups (option 32), popular values. exmaster lists no
  `natneg` flag, so clients query servers directly.
- Limits: 64 connections at once; per IP, 5 at once then one every 3
  seconds; 5 seconds and 1 KB for the request; 10 seconds in all, but
  for the time the list waits for the reply budget, which it pays 64 KB
  at a time (`Exmaster.Paid`), so a list larger than the budget's burst
  still goes out.
