"""Asks exmaster for its lists the way game clients do, and prints them.

    python3 -I query.py [host [gamespy host]]

Queries go 3.5 seconds apart, under exmaster's per-IP limit of 5 at once
then one every 3 seconds. The GameSpy list is asked for without
encryption (enctype 0); Battlefield 1942 asks for enctype 2, which the
tests cover.
"""
import socket
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
GS_HOST = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.2"
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
    s = socket.create_connection((GS_HOST, 28900), timeout=5)
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
