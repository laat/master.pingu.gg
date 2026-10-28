#!/bin/sh
# Starts the test servers against an exmaster on 127.0.0.1 (127.0.0.2 for
# GameSpy) and shows the lists, from query.py and from qstat. See
# README.md.
#
#   run.sh [service...]     all of them by default
set -eu
cd "$(dirname "$0")"
services=${*:-q3 q2 qw bf1942 mohaa rtcw wet etl xnt wf cod coduo cod2 cod4 sof2 ut99}
export HOST_UID="$(id -u)" HOST_GID="$(id -g)"

# The image installs a game only into an empty serverfiles. q3, q2 and qw
# mount a config there, and BF1942 and UT99 read their configs from there,
# so they are installed first, with nothing but /data mounted, unless
# their executable is there already.
install_first() {
	case " $services " in *" $1 "*)
		[ -e "data/$1/serverfiles/$2" ] && return
		mkdir -p "data/$1"
		docker run --rm -e UID="$HOST_UID" -e GID="$HOST_GID" -v "$PWD/data/$1:/data" \
			"ghcr.io/gameservermanagers/gameserver:$1" auto-install || true
		[ -e "data/$1/serverfiles/$2" ] || { echo "$1 didn't install; see the output above" >&2; exit 1; }
	esac
}
install_first q3 q3ded
install_first q2 quake2
install_first qw mvdsv
install_first bf1942 start.sh
install_first ut99 System/ucc-bin

# BF1942's config goes in before it starts: LinuxGSM's listens on every
# address.
case " $services " in *" bf1942 "*)
	cp config/bf1942/serversettings.con data/bf1942/serverfiles/mods/bf1942/settings/
esac

# UT99's masters are in its ini, and LinuxGSM's names fourteen public ones.
# Before it starts, its uplinks become one to exmaster, its LAN beacon and
# web admin go, and FirstRun says 469 has run, which keeps 469 from adding
# its default masters back.
case " $services " in *" ut99 "*)
	sed -i -e '/^ServerActors=IpServer.UdpServerUplink /d' \
		-e '/^ServerActors=IpDrv.UdpBeacon$/d' -e '/^ServerActors=UWeb.WebServer$/d' \
		-e 's/^ServerActors=IpServer.UdpServerQuery$/&\nServerActors=IpServer.UdpServerUplink MasterServerAddress=127.0.0.2 MasterServerPort=27900/' \
		-e 's/^FirstRun=.*/FirstRun=469/' -e 's/^ServerName=.*/ServerName=exmaster test/' \
		data/ut99/serverfiles/System/ut99server.ini
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
	docker exec -u linuxgsm "exmaster-$g" sh -c "cd /app && ./${g}server send heartbeat" >/dev/null || true
done
sleep 3

python3 -I query.py
if command -v quakestat >/dev/null; then
	for m in q3m:27950 rwm:27950 q2m:27900 qwm:27000 cod2m:20710 cod4m:20810; do
		quakestat "-${m%%:*}" "127.0.0.1:${m#*:}"
		sleep 3.5
	done
fi
