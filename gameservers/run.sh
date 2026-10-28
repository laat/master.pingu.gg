#!/bin/sh
# Starts the test servers against an exmaster on 127.0.0.1 (127.0.0.2 for
# GameSpy) and shows the lists, from query.py and from qstat. See
# README.md.
#
#   run.sh [service...]     q3 q2 qw bf1942 mohaa by default
set -eu
cd "$(dirname "$0")"
services=${*:-q3 q2 qw bf1942 mohaa}
export HOST_UID="$(id -u)" HOST_GID="$(id -g)"

# BF1942 reads its config from serverfiles, which the image installs into
# only when it is empty, so it is installed first and given its config
# before it starts: LinuxGSM's listens on every address.
case " $services " in *" bf1942 "*)
	if [ ! -e data/bf1942/serverfiles/start.sh ]; then
		docker compose run --rm bf1942 auto-install || true
	fi
	cp config/bf1942/serversettings.con data/bf1942/serverfiles/mods/bf1942/settings/
esac

docker compose up -d $services

# The first start installs each game, which takes a minute or two.
for g in $services; do
	printf 'waiting for %s' "$g"
	until docker exec -u linuxgsm "exmaster-$g" sh -c "cd /app && ./${g}server details" 2>/dev/null | grep -q "STARTED"; do
		printf .
		sleep 5
	done
	echo
done

# Quake 2 3.20's first heartbeat comes minutes after it starts, and the
# ping setmaster sends goes out before its socket is open. The others
# heartbeat at once; this makes it immediate for all of them. BF1942
# heartbeats as it starts too, and has no command for it.
for g in $services; do
	[ "$g" = bf1942 ] && continue
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
