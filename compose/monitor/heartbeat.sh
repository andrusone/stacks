#!/usr/bin/env bash
# The outside heartbeat for the monitor (HL-FR-09, MVP 2, ST256). Every five minutes, while the local Gatus
# answers, it pings HEARTBEAT_URL, a dead-man's-switch service outside the monitored machines. A Gatus that
# does not answer sends nothing, so the outside service's silence is the alert. HEARTBEAT_URL comes from the
# environment, else from compose/monitor/.env; it is a secret and is never printed, logged or put in git
# (HL-NFR-02). Always exits 0, so the timer never shows failed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# A value from the environment, else from compose/monitor/.env, else the default given here.
value() {
	local v="${!1-}"
	[ -n "$v" ] || v="$(sed -n "s/^$1=//p" "$here/.env" 2>/dev/null | tail -n1)"
	printf '%s' "${v:-$2}"
}
url="$(value HEARTBEAT_URL '')"
if [ -z "$url" ]; then
	echo "heartbeat: off, set HEARTBEAT_URL in compose/monitor/.env to the outside service's URL"
	exit 0
fi

# Gatus answering is the proof the monitor runs; a check that hangs counts as no answer (HL-FR-10).
# Gatus is published on MONITOR_BIND (docker-compose.yml), so the check goes to that address, as health-sync.sh does.
host="$(value MONITOR_BIND 127.0.0.1)"
port="$(value GATUS_PORT 8080)"
if curl -fsS --max-time 10 "http://$host:$port/health" >/dev/null 2>&1; then
	curl -fsS --max-time 10 "$url" >/dev/null 2>&1 ||
		echo "heartbeat: the outside service did not take the ping, it alerts when pings stop"
else
	echo "heartbeat: gatus did not answer on $host:$port, sent no ping"
fi
exit 0
