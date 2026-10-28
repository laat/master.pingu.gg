#!/bin/sh
# Starts the test servers against an exmaster on 127.0.0.1 and shows the
# lists, from query.py and from qstat. See README.md.
set -eu
cd "$(dirname "$0")"

HOST_UID=$(id -u) HOST_GID=$(id -g) docker compose up -d

# The first start installs each game, which takes a minute or two.
for g in q3 q2 qw; do
	printf 'waiting for %s' "$g"
	until docker exec -u linuxgsm "exmaster-$g" sh -c "cd /app && ./${g}server details" 2>/dev/null | grep -q "STARTED"; do
		printf .
		sleep 5
	done
	echo
done

# Quake 2 3.20's first heartbeat comes minutes after it starts, and the
# ping setmaster sends goes out before its socket is open. The others
# heartbeat at once; this makes it immediate for all three.
for g in q3 q2 qw; do
	docker exec -u linuxgsm "exmaster-$g" sh -c "cd /app && ./${g}server send heartbeat" >/dev/null
done
sleep 3

python3 -I query.py
if command -v quakestat >/dev/null; then
	for m in q3m:27950 q2m:27900 qwm:27000; do
		quakestat "-${m%%:*}" "127.0.0.1:${m#*:}"
		sleep 3.5
	done
fi
