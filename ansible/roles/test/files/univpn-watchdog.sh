#!/bin/bash

set -u

: "${CHECK_HOSTS:?CHECK_HOSTS is not set}"
: "${RUNTIME_DIRECTORY:?RUNTIME_DIRECTORY is not set}"
: "${STATE_DIRECTORY:?STATE_DIRECTORY is not set}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
FAILS_ALLOWED="${FAILS_ALLOWED:-3}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-300}"
MAX_LOGIN_FAILURES="${MAX_LOGIN_FAILURES:-3}"

logged_in="${RUNTIME_DIRECTORY}/logged-in"
login_failures="${STATE_DIRECTORY}/login-failures"
pid=

# bash runs a trap only after the current foreground command has ended.
# Sleeping in the background and waiting for it lets the trap run at once.
pause() {
	sleep "$1" &
	wait "$!"
}

stop_client() {
	if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
		# univpn-connect.exp sends "q" to the client on SIGTERM.
		kill -TERM "${pid}"
		for _ in $(seq 20); do
			kill -0 "${pid}" 2>/dev/null || break
			sleep 1
		done
	fi
	pkill -x UniVPNCS
}

tunnel_is_up() {
	local host
	for host in ${CHECK_HOSTS}; do
		if ping -c 3 -W 3 "${host}" >/dev/null 2>&1; then
			return 0
		fi
	done
	return 1
}

# The client adds a host route to its tunnel address via 127.0.0.1 on each
# connect and never removes the route.
remove_stale_routes() {
	local destination
	ip -4 route show via 127.0.0.1 dev lo scope link |
		while read -r destination _; do
			echo "[watchdog] removing stale route to ${destination}"
			ip route del "${destination}" via 127.0.0.1 dev lo scope link
		done
}

trap 'stop_client; exit 0' TERM INT

# The client refuses to start a second time. A client that is already
# running was started by hand, for example in a tmux session. Stopping it
# would cut the VPN connection of whoever started it.
if pgrep -x UniVPNCS >/dev/null; then
	echo "[watchdog] UniVPNCS is already running outside of this service"
	exit 4
fi

remove_stale_routes
rm -f "${logged_in}"
"$(dirname "$0")/univpn-connect.exp" &
pid=$!

waited=0
while [ ! -e "${logged_in}" ] && kill -0 "${pid}" 2>/dev/null &&
	[ "${waited}" -lt "${CONNECT_TIMEOUT}" ]; do
	pause 1
	waited=$((waited + 1))
done

if [ ! -e "${logged_in}" ]; then
	if kill -0 "${pid}" 2>/dev/null; then
		echo "[watchdog] no login after ${CONNECT_TIMEOUT} seconds"
		stop_client
		exit 1
	fi
	wait "${pid}"
	rc=$?
	if [ "${rc}" -eq 3 ]; then
		# The VPN gateway may lock the account after too many wrong
		# passwords, so the service stops retrying a rejected login.
		count=$(($(cat "${login_failures}" 2>/dev/null || echo 0) + 1))
		echo "${count}" >"${login_failures}"
		echo "[watchdog] login rejected (${count}/${MAX_LOGIN_FAILURES})"
		if [ "${count}" -ge "${MAX_LOGIN_FAILURES}" ]; then
			echo "[watchdog] not retrying, check /etc/univpn.env"
			exit 3
		fi
	fi
	if [ "${rc}" -eq 4 ]; then
		exit 4
	fi
	exit 1
fi

echo 0 >"${login_failures}"

# The tunnel needs some seconds after the login. The first checks may
# fail, which FAILS_ALLOWED covers.
fails=0
up=0
while kill -0 "${pid}" 2>/dev/null; do
	pause "${CHECK_INTERVAL}"
	if tunnel_is_up; then
		if [ "${up}" -eq 0 ]; then
			echo "[watchdog] tunnel is up"
			up=1
		fi
		fails=0
		continue
	fi
	fails=$((fails + 1))
	echo "[watchdog] no check host answers (${fails}/${FAILS_ALLOWED})"
	if [ "${fails}" -ge "${FAILS_ALLOWED}" ]; then
		echo "[watchdog] tunnel is down, reconnecting"
		break
	fi
done

stop_client
exit 1
