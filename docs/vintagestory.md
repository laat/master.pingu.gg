# Vintage Story master protocol

This is the master protocol Vintage Story speaks, JSON over HTTP, and how
exmaster speaks it: `Exmaster.VS` (the JSON) and `Exmaster.VS.Master`
(the master, HTTP over TCP). The sources used here are:

- Vintage Story 1.22.7's server and client code, decompiled from
  `VintagestoryLib.dll` in the official Linux server package:
  `ServerSystemHeartbeat` and its packets, `ServerConfig`, and the
  client's `GuiScreenPublicServers`, `GuiScreenPublicServerView` and
  `ServerListEntry`.
- The official master's list (`https://masterserver.vintagestory.at/api/v1/servers/list`),
  2,169 servers on 2026-11-07.
- The 1.22.7 server, as LinuxGSM installs it: its traffic against a
  master that logged every connection, on 2026-10-28, and against
  exmaster, on 2026-11-07.

## Where Vintage Story servers go

The master is a URL in the server's `serverconfig.json`, host, port and
path all honoured, and the server appends the endpoint to it, so it has
to end in `/`:

```json
"MasterserverUrl": "http://masterserver.vintagestory.at/api/v1/servers/",
"AdvertiseServer": true,
```

Since 1.20 servers don't advertise by default; `AdvertiseServer` turns it
on. A server with `VerifyPlayerAuth` off doesn't register, nor one with
UPnP on until UPnP has worked. `--withconfig` on the command line merges
settings into the file, which is how the test rig sets them. The client's
URL is `masterserverUrl` in its `clientsettings.json`, by default the
official master over HTTPS.

| Port | Use |
|---|---|
| TCP 80 or 443 | master, the official one: servers and clients |
| TCP and UDP 42420 | server: the game |

## Requests

Every request is HTTP/1.1 from .NET's `HttpClient`, and every reply is
JSON: `{"status": ..., "data": ...}`. A server posts `application/json`
with a `Content-Length`:

- `register`, as it starts (once the game is running, or at once in
  standby mode), and when advertising is switched on:

  ```json
  {"port":42420,"name":"exmaster test","icon":"","playstyle":{"id":"surviveandbuild","langCode":"surviveandbuild-bands"},
   "maxPlayers":16,"gameVersion":"1.22.7","hasPassword":false,
   "Mods":[{"id":"game","version":"1.22.7"},{"id":"creative","version":"1.22.7"},{"id":"survival","version":"1.22.7"}],
   "serverUrl":null,"gameDescription":null,"whitelisted":true,"vhIdentifier":null}
  ```

  `Mods` are those clients need too. With `status` `ok`, `data` is a
  token, and the server heartbeats with it at once and every 2 minutes.
  Any other status has the server log `data`: "Could not register to
  master server, master server says: ...". `blacklisted` logs a warning
  too. The server doesn't try again until it starts again or advertising
  is switched back on, nor when the request fails.
- `heartbeat`: `{"token":"<token>","players":0}`. The status `invalid` or
  `timeout`, an empty reply, or none within the request's timeout, has
  the server register again at once; anything else is ignored.
- `unregister`, as it begins to shut down, and when advertising is
  switched off: `{"token":null}`. The game clears its token before it
  sends it, so the master can only go by the IP. The reply is ignored.

A client gets `list`, and the master answers `{"status":"ok","data":[...]}`
with a server an object:

```json
{"serverName":"exmaster test","serverIP":"127.0.0.1:42420",
 "playstyle":{"id":"surviveandbuild","langCode":"surviveandbuild-bands"},
 "mods":[{"id":"game","version":"1.22.7"}],"maxPlayers":16,"players":0,
 "gameVersion":"1.22.7","hasPassword":false,"whitelisted":true,"gameDescription":""}
```

These are the keys the official master's list has. Its `maxPlayers` is a
string, which the client reads as the integer its field is. `serverIP`
is where the client connects, `[address]:port` for IPv6. The client reads
`mods`, `playstyle`, `gameDescription` and `serverName` without checking
for null, so they are always there. It needs HTTP status 200, sorts the
servers by players itself, and filters them by password, whitelist, mods
and name.

## How exmaster lists servers

exmaster serves the endpoints under any path: the endpoint is a request
path's last segment, so `http://host:port/` and
`http://host:port/api/v1/servers/` both work. Each connection is one
request, and is closed after the reply.

- A registration lists the server at the IP its connection comes from
  and the port it names. TCP has proved the IP; the port is the server's
  word, but it only matters to clients, who connect to that IP. A server
  that isn't listed has to take a TCP connection from the master on that
  port first, within 3 seconds, so servers clients can't reach aren't
  listed; the reply says so, and the server logs it. The game opens its
  port before it registers.
- The token is the server's port: the master knows the IP from the
  connection, and anyone at that IP could register the port anyway.
- A heartbeat keeps the server listed for 5 minutes more and sets its
  players. One for a server that isn't listed, because it expired or
  exmaster restarted, gets `invalid`, and the game registers again. With
  several nodes, a heartbeat for a server another node lists has this
  node list it, so a server whose heartbeats go to another node than its
  registration did stays listed. A heartbeat keeps the name, mods and
  the rest from the server's latest registration, on whichever node.
- An unregistration names no server, so 10 seconds after it, when the
  server should have closed its port, exmaster connects to each server
  it lists at that IP, and drops those that don't take the connection
  and haven't heartbeat since. One with a token, which the game doesn't
  send, checks that server only. An IP gets 4 of these checks at once,
  then one every 10 seconds; an unregistration over that is answered and
  its server expires.
- Strings are cut: the name to 128 bytes, the description to 1,024, the
  version, the playstyle's and each mod's id and version to 64, and a
  server keeps its first 512 mods. Each entry is copied to every list and
  to the other nodes.
- The master takes 256 connections at once, 8 from an IP, and an IP can
  open 64 at once, then one a second: the game registers once, as it
  starts, so a host that starts many servers at once has to get through.
  The request has to be in within 10 seconds, the body at most 64 KB
  with a `Content-Length` (a chunked one gets 411), and a connection is
  closed 15 seconds after it opened. Connections to servers that aren't
  listed count against the same allowance as the other masters' first
  queries: 64 per IP at once, then one a second.
- `max_per_ip` and `max_servers` apply as to the other masters, and the
  reply to a refused registration says why.

Lists count against the same reply budget as the other masters', and an
IP gets 5 at once, then one every 3 seconds; over that, the client gets
429 and shows "Could not connect to master server". The least a list
costs is reserved before it is made; the rest is paid 64 KB at a time,
waiting when the budget is spent, and the time it waits doesn't count
against the 15 seconds, up to a minute of it. The official list is 4 MB
for 2,169 servers, most of it mods, and the client doesn't take it
compressed.

## Not done

- IPv6. The lists could carry it, as the official one does, but the
  listener is IPv4 only, as the other TCP masters are.
- HTTPS, which the client's default URL uses: the client's URL has to be
  changed to exmaster's anyway. A proxy in front of exmaster would hide
  the servers' IPs from it, so registrations have to reach it directly.
- `blacklisted`, and any check of names.
- Keep-alive: the game's `HttpClient` connects again for each request.
