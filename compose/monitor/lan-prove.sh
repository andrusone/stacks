#!/usr/bin/env bash
# Prove the monitor's ports from a LAN client (ST264, HL-FR-19 MVP 3). Run it from another machine:
#   lan-prove.sh <monitor-ip>
# GATUS_PORT (default 8081) and BESZEL_PORT (default 8091) must accept a TCP connection. Port 8099, which
# nothing declares, must be refused or time out. Prints one ok or FAIL line per check and exits 1 on any
# FAIL, or 2 on bad arguments. Changes nothing on the monitor.
set -u

usage() {
	echo "usage: lan-prove.sh <monitor-ip>" >&2
	exit 2
}

[ $# -eq 1 ] || usage
case "$1" in -*) usage ;; esac
addr="$1"
gatus="${GATUS_PORT:-8081}"
beszel="${BESZEL_PORT:-8091}"
undeclared=8099
fails=0
ok() { echo "ok $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

if ! command -v nc >/dev/null 2>&1; then
	bad "tools: missing nc"
	exit 1
fi

# A TCP connect within 3 seconds. A refusal and a timeout both count as not open.
accepts() { nc -z -w 3 "$addr" "$1" >/dev/null 2>&1; }

for check in "gatus:$gatus" "beszel:$beszel"; do
	name=${check%%:*}
	port=${check#*:}
	if accepts "$port"; then
		ok "$name: $addr:$port accepts a connection"
	else
		bad "$name: $addr:$port does not answer"
	fi
done

if accepts "$undeclared"; then
	bad "closed: $addr:$undeclared accepts a connection"
else
	ok "closed: $addr:$undeclared refuses or times out"
fi

[ "$fails" -eq 0 ] || exit 1
