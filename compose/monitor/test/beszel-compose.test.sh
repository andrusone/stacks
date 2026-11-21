#!/usr/bin/env bash
# The Beszel hub's compose test (ST258, HL-FR-02 MVP 2). No Docker needed: when docker compose is present the
# test reads the rendered file (docker compose config, with placeholder values in a temp folder); otherwise it
# greps the file itself. Checks: the beszel service exists; its image has a version tag, not latest; its data
# volume is under MONITOR_DIR; it has a healthcheck; the file holds no KEY, TOKEN or PASSWORD value.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
file="$here/../docker-compose.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$file" ] || fail "compose file missing: $file"

# The beszel service block, from its line to the next top-level service line.
block() {
	awk '/^  beszel:$/ {on = 1; print; next} on && /^  [A-Za-z0-9_-]+:$/ {exit} on {print}'
}

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
	mon="$tmp/monitor"
	rendered="$tmp/rendered.yml"
	MONITOR_DIR="$mon" MONITOR_BIND=127.0.0.1 NTFY_PORT=8090 GATUS_PORT=8081 NTFY_TOPIC=placeholder \
		docker compose -f "$file" config > "$rendered" 2>"$tmp/err" || fail "docker compose config failed: $(cat "$tmp/err")"
	text="$(block < "$rendered")"
	[ -n "$text" ] || fail "the rendered file has no beszel service"
	printf '%s\n' "$text" | grep -q 'source: '"$mon"'/beszel$' || fail "the beszel volume is not under MONITOR_DIR"
else
	text="$(block < "$file")"
	[ -n "$text" ] || fail "the file has no beszel service"
	printf '%s\n' "$text" | grep -q '\${MONITOR_DIR' || fail "the beszel volume is not under MONITOR_DIR"
fi

image="$(printf '%s\n' "$text" | sed -n 's/^ *image: *//p')"
case "$image" in
	henrygd/beszel:*) ;;
	*) fail "the beszel image is not henrygd/beszel: '$image'" ;;
esac
tag="${image#henrygd/beszel:}"
case "$tag" in
	""|latest) fail "the beszel image has no version tag: '$image'" ;;
esac
printf '%s\n' "$tag" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "the beszel tag is not a version: '$tag'"

printf '%s\n' "$text" | grep -q '^ *healthcheck:' || fail "the beszel service has no healthcheck"

grep -En 'KEY|TOKEN|PASSWORD' "$file" && fail "the compose file holds a KEY, TOKEN or PASSWORD word"

echo "ok: beszel-compose.test.sh"
