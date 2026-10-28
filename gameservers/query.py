"""Asks exmaster for its lists the way game clients do, and prints them.

    python3 -I query.py [host]

Queries go 3.5 seconds apart, under exmaster's per-IP limit of 5 at once
then one every 3 seconds. The GameSpy list is asked for without
encryption (enctype 0); Battlefield 1942 asks for enctype 2, which the
tests cover. The QR2 list (server browsing) is always encrypted; the
client here decrypts OpenSpy's lists too.
"""
import os
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
OOB = b"\xff\xff\xff\xff"


def ask(port, packet):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(1.5)
    s.sendto(packet, (HOST, port))
    replies = []
    try:
        while True:
            replies.append(s.recv(65536))
            s.settimeout(0.3)
    except socket.timeout:
        pass
    time.sleep(3.5)
    return replies


def q3(packet, port=27950):
    out = []
    for r in ask(port, OOB + packet):
        body = r[4:].split(b"Response", 1)[1]
        i = 0
        while i < len(body):
            if body[i:i + 7] == b"\\EOT\x00\x00\x00":
                break
            if body[i:i + 1] == b"\\":
                a = body[i + 1:i + 5]
                out.append("%d.%d.%d.%d:%d" % (*a, int.from_bytes(body[i + 5:i + 7], "big")))
                i += 7
            elif body[i:i + 1] == b"/":
                out.append("[%s]:%d" % (socket.inet_ntop(socket.AF_INET6, body[i + 1:i + 17]),
                                        int.from_bytes(body[i + 17:i + 19], "big")))
                i += 19
            else:
                break
    return out


def six_byte(port, packet, header):
    out = []
    for r in ask(port, packet):
        entries = r[len(OOB + header):]
        for i in range(0, len(entries) - 5, 6):
            e = entries[i:i + 6]
            out.append("%d.%d.%d.%d:%d" % (*e[:4], int.from_bytes(e[4:6], "big")))
    return out


for query in [b"getservers 68", b"getservers 68 empty", b"getservers 68 empty full",
              b"getservers Quake3Arena 68 empty", b"getserversExt Quake3Arena 68 empty",
              b"getservers 60 empty", b"getservers 84 empty",
              b"getserversExt Xonotic 3 empty", b"getservers Warfork 26 empty"]:
    print("q3 %-36s %s" % (query.decode(), q3(query)))
# The labelled listeners, one per game, as their clients ask.
for port, game, query in [(20510, "CoD", b"getservers 6 empty full"),
                          (20610, "CoDUO", b"getservers 22 empty full"),
                          (20710, "CoD2", b"getservers 118 empty full"),
                          (20810, "CoD4", b"getservers 6 empty full"),
                          (20110, "SoF2", b"getservers 2004 empty full")]:
    print("q3 %-36s %s" % ("%s %s" % (game, query.decode()), q3(query, port)))
print("q2 %-36s %s" % ("query", six_byte(27900, b"query\n", b"servers ")))
print("qw %-36s %s" % ("c", six_byte(27000, b"c\n", b"d\n")))


def gamespy(game):
    """The list over TCP: the master's challenge, the client's hello (its
    \\validate\\ isn't checked), then \\list\\cmp, read to the close."""
    s = socket.create_connection((HOST, 28900), timeout=5)
    s.recv(1024)
    s.sendall(b"\\gamename\\%s\\gamever\\2\\location\\0\\validate\\x\\enctype\\0\\final\\\\queryid\\1.1\\" % game)
    s.sendall(b"\\list\\cmp\\gamename\\%s\\final\\" % game)
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    entries = data[:-len(b"\\final\\")]
    return ["%d.%d.%d.%d:%d" % (*entries[i:i + 4], int.from_bytes(entries[i + 4:i + 6], "big"))
            for i in range(0, len(entries) - 5, 6)]


for game in [b"bfield1942", b"mohaa", b"ut"]:
    print("gs %-36s %s" % ("list cmp " + game.decode(), gamespy(game)))


def fstring(text):
    b = text.encode("latin1") + b"\0"
    return bytes([len(b)]) + b


def ut2004(filters=()):
    """UT2004's list over TCP, in frames: the master's challenge, the
    client's CD key hashes (not checked), name and version, its
    verification, then the query with filters (key, value, comparison);
    a frame with the count, then one a server."""
    s = socket.create_connection((HOST, 28902), timeout=5)

    def read():
        def exactly(n):
            b = b""
            while len(b) < n:
                chunk = s.recv(n - len(b))
                if not chunk:
                    raise EOFError
                b += chunk
            return b
        (n,) = struct.unpack("<I", exactly(4))
        return exactly(n)

    def write(payload):
        s.sendall(struct.pack("<I", len(payload)) + payload)

    read()
    write(fstring("0" * 32) + fstring("0" * 32) + fstring("UT2K4CLIENT") +
          struct.pack("<IB", 3369, 5) + fstring("int") + struct.pack("<IIIB", 0, 0, 0, 0))
    read()
    write(fstring("0" * 32))
    read()
    write(b"\0" + bytes([len(filters)]) +
          b"".join(fstring(k) + fstring(v) + bytes([op]) for k, v, op in filters))
    (count,) = struct.unpack("<I", read()[:4])
    out = []
    for _ in range(count):
        e = read()
        out.append("%d.%d.%d.%d:%d" % (*e[:4], struct.unpack("<H", e[4:6])[0]))
    time.sleep(3.5)
    return out


for name, filters in [("all", ()), ("gametype = xDeathMatch", [("gametype", "xDeathMatch", 0)]),
                      ("gametype = xCTFGame", [("gametype", "xCTFGame", 0)])]:
    print("ue2 %-35s %s" % ("list " + name, ut2004(filters)))


class GOACrypt:
    """GameSpy's list cipher, from its SDK's sb_crypt.c; decrypting only."""

    def __init__(self, key):
        c = list(range(256))
        rsum, keypos = 0, 0
        for i in range(255, -1, -1):
            if i == 0:
                u = 0
            else:
                mask, tries = 1, 0
                while mask < i:
                    mask = (mask << 1) + 1
                while True:
                    rsum = (c[rsum] + key[keypos]) & 0xFF
                    keypos += 1
                    if keypos >= len(key):
                        keypos, rsum = 0, (rsum + len(key)) & 0xFF
                    u = mask & rsum
                    tries += 1
                    if tries > 11:
                        u %= i
                    if u <= i:
                        break
            c[i], c[u] = c[u], c[i]
        self.c = c
        self.rotor, self.ratchet, self.avalanche, self.last_plain = c[1], c[3], c[5], c[7]
        self.last_cipher = c[rsum]

    def decrypt(self, data):
        c, out = self.c, bytearray()
        for b in data:
            self.ratchet = (self.ratchet + c[self.rotor]) & 0xFF
            self.rotor = (self.rotor + 1) & 0xFF
            t = c[self.last_cipher]
            c[self.last_cipher] = c[self.ratchet]
            c[self.ratchet] = c[self.last_plain]
            c[self.last_plain] = c[self.rotor]
            c[self.rotor] = t
            self.avalanche = (self.avalanche + c[t]) & 0xFF
            p = b ^ c[(c[self.avalanche] + c[self.rotor]) & 0xFF] ^ \
                c[c[(c[self.last_plain] + c[self.last_cipher] + c[self.ratchet]) & 0xFF]]
            self.last_plain, self.last_cipher = p, b
            out.append(p)
        return bytes(out)


def server_browsing(game, fields, from_game, from_key, host=HOST, port=28910):
    """A QR2 game's list over TCP, as GameSpy's SDK asks for it
    (sb_serverlist.c): a request with an 8-byte challenge, then the
    master's crypt header and the list, encrypted under a key made of the
    challenge, the master's and the asking game's secret key. Returns the
    servers as (address, {field: value}), and closes once the list ends."""
    challenge = bytearray(os.urandom(8))
    req = (bytes([0, 1, 3]) + struct.pack("<I", 0) + game + b"\0" + from_game + b"\0" +
           bytes(challenge) + b"\0" + fields + b"\0" + struct.pack(">I", 0))
    s = socket.create_connection((host, port), timeout=5)
    s.sendall(struct.pack(">H", len(req) + 2) + req)
    data, plain, crypt = b"", b"", None
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
        if crypt is None:
            if len(data) < 1 or len(data) < (data[0] ^ 0xEC) + 2:
                continue
            n = data[0] ^ 0xEC
            m = data[n + 1] ^ 0xEA
            if len(data) < n + 2 + m:
                continue
            server_challenge = data[n + 2:n + 2 + m]
            for i in range(m):
                j = (i * from_key[i % len(from_key)]) % 8
                challenge[j] ^= (challenge[i % 8] ^ server_challenge[i]) & 0xFF
            crypt = GOACrypt(bytes(challenge))
            data = data[n + 2 + m:]
        plain += crypt.decrypt(data)
        data = b""
        servers = parse_list(plain)
        if servers is not None:
            s.close()
            return servers
    raise EOFError("the list didn't end")


def parse_list(b):
    """The servers in a decrypted list, or None if it hasn't all come.
    Any read can end inside a record, so a short field means wait. The
    fields are the ones the list names, as the SDK reads them."""
    try:
        i = 6
        if b[4:6] == b"\xff\xff":
            raise ValueError("master's error: %r" % b[6:].split(b"\0")[0])
        default_port = struct.unpack(">H", b[4:6])[0]
        nfields = b[i]
        i += 1
        types, names = [], []
        for _ in range(nfields):
            types.append(b[i])
            j = b.index(b"\0", i + 1)
            names.append(b[i + 1:j])
            i = j + 1
        npopular = b[i]
        i += 1
        popular = []
        for _ in range(npopular):
            j = b.index(b"\0", i)
            popular.append(b[i:j])
            i = j + 1
        servers = []
        while True:
            flags = b[i]
            if flags == 0 and b[i + 1:i + 5] == b"\xff\xff\xff\xff":
                return servers
            ip = socket.inet_ntoa(b[i + 1:i + 5])
            i += 5
            port = default_port
            if flags & 16:
                port = struct.unpack(">H", b[i:i + 2])[0]
                i += 2
            if flags & 2:
                i += 4
            if flags & 32:
                i += 2
            if flags & 8:
                i += 4
            values = {}
            if flags & 64:
                for name, t in zip(names, types):
                    if t == 0:
                        if b[i] == 0xFF:
                            j = b.index(b"\0", i + 1)
                            values[name.decode()] = b[i + 1:j].decode("latin1")
                            i = j + 1
                        else:
                            values[name.decode()] = popular[b[i]].decode("latin1")
                            i += 1
                    elif t == 1:
                        values[name.decode()] = str(b[i])
                        i += 1
                    else:
                        values[name.decode()] = str(struct.unpack(">H", b[i:i + 2])[0])
                        i += 2
            servers.append(("%s:%s" % (ip, port), values))
    except (IndexError, OSError, struct.error):
        return None
    except ValueError as e:
        if "master's error" in str(e):
            raise
        return None


for game, from_game, key in [(b"bfvietnam", b"bfvietnam", b"h2P9dJ"),
                             (b"bfvietnam", b"gslive", b"Xn221z")]:
    servers = server_browsing(game, b"\\hostname\\gamever\\numplayers\\maxplayers\\mapname",
                              from_game, key)
    print("sb %-36s %s" % ("%s, asked as %s" % (game.decode(), from_game.decode()), servers))
    time.sleep(3.5)
