#!/usr/bin/env bash
# The health sync for the monitor (HL-FR-13, MVP 3, ST242). Runs from the stacks checkout on the monitor
# VM: pulls it, regenerates the Gatus config from health/ and, when the text changed, replaces
# $MONITOR_DIR/gatus/config.yaml and restarts Gatus. A file the generator rejects keeps the last good
# config and posts one line to ntfy, once per bad commit. Values come from the environment, else from
# compose/monitor/.env (this unit has no EnvironmentFile). Always exits 0, so the timer never shows failed.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
# A timer must never wait on a credential prompt.
export GIT_TERMINAL_PROMPT=0

# A value from the environment, else from compose/monitor/.env, else the default given here.
value() {
	local v="${!1-}"
	[ -n "$v" ] || v="$(sed -n "s/^$1=//p" "$here/.env" 2>/dev/null | tail -n1)"
	printf '%s' "${v:-$2}"
}
mon="$(value MONITOR_DIR /srv/monitor)"
cfg="$mon/gatus/config.yaml"
rej="$mon/health-sync.rejected"

if ! git -C "$repo" pull -q --ff-only 2>/dev/null; then
	echo "health-sync: origin pull failed, kept the current config"
	exit 0
fi

# The temp file sits beside the config so the final rename stays on one filesystem.
mkdir -p "$mon/gatus" 2>/dev/null || { echo "health-sync: cannot write $mon/gatus, kept the current config"; exit 0; }
tmp="$(mktemp "$mon/gatus/.config.XXXXXX")" || exit 0
err="$(mktemp)"
trap 'rm -f "$tmp" "$err"' EXIT

gen() {
	if command -v mise >/dev/null 2>&1; then mise x -- go run ./cmd/health generate health
	else go run ./cmd/health generate health; fi
}
if ! (cd "$repo" && gen >"$tmp" 2>"$err"); then
	cat "$err" >&2
	file="$(sed -n 's/^\([^:]*\.toml\):.*/\1/p' "$err" | head -n1)"
	line="health-sync: rejected ${file:-the health files}, kept the last good checks"
	echo "$line"
	commit="$(git -C "$repo" rev-parse HEAD)"
	topic="$(value NTFY_TOPIC '')"
	# Recorded only after ntfy accepts it, so a message lost to a down ntfy is tried again.
	if [ -n "$topic" ] && [ "$(cat "$rej" 2>/dev/null)" != "$commit" ] &&
		curl -fsS -m 10 -d "$line" "http://$(value MONITOR_BIND 127.0.0.1):$(value NTFY_PORT 8090)/$topic" >/dev/null 2>&1; then
		printf '%s\n' "$commit" >"$rej"
	fi
	exit 0
fi

if cmp -s "$tmp" "$cfg"; then exit 0; fi
chmod 0644 "$tmp"
mv -f "$tmp" "$cfg"
c="${HEALTH_GATUS_CONTAINER:-$(docker compose -f "$repo/compose/monitor/docker-compose.yml" ps -q gatus 2>/dev/null)}"
docker restart "$c" >/dev/null 2>&1 || echo "health-sync: could not restart gatus (${c:-no container}), it reads the new config at its next start"
echo "health-sync: loaded $(find "$repo/health" -maxdepth 1 -name '*.toml' | wc -l) files"
exit 0
