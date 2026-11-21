#!/usr/bin/env bash
# The listen test (ST222, CORE-FR-10 MVP 2): the core stack's addresses with CORE_LISTEN set and unset.
# Checks: docker compose config publishes BIND and chrony on CORE_LISTEN, and on 127.0.0.1 when unset;
# the Unbound command, rendered by compose and run on a temporary file, puts CORE_LISTEN in interface
# and stub-addr and CORE_LAN in access-control; zone.sh writes CORE_BIND_PORT into the peer lines.
# Starts no containers. Skipped with a message when docker or jq is absent.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
core="$here/../../core"

if ! command -v docker >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
	echo "listen test: skipped (needs docker and jq)"
	exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# render FILE [NAME=VALUE...]: the compose config as JSON, with the listen variables cleared first.
render() {
	local file="$1"
	shift
	env -u CORE_LISTEN -u CORE_LAN -u CORE_BIND_PORT -u CORE_NTP_PORT -u CORE_DNS_PORT "$@" \
		docker compose -f "$file" config --format json
}

# host_ips JSON SERVICE: the distinct addresses the service publishes on.
host_ips() {
	printf '%s' "$1" | jq -r --arg s "$2" '.services[$s].ports[].host_ip' | sort -u | paste -sd, -
}

check_published() {
	local json="$1" service="$2" want="$3"
	local got
	got="$(host_ips "$json" "$service")"
	[ "$got" = "$want" ] || fail "$service publishes on '$got', want '$want'"
}

# The Unbound step: the command compose renders, its paths moved into $1, the server start removed.
unbound_step() {
	local json="$1" out="$2" cmd
	local envs=()
	cmd="$(printf '%s' "$json" | jq -r '.services.unbound.command[2]')"
	cmd="${cmd//\$\$/\$}"
	cmd="${cmd//\/etc\/unbound\/unbound.template/$out.template}"
	cmd="${cmd//\/opt\/unbound\/etc\/unbound\/unbound.conf/$out.conf}"
	cmd="${cmd// exec \/unbound.sh/ true}"
	mapfile -t envs < <(printf '%s' "$json" | jq -r '.services.unbound.environment | to_entries[] | "\(.key)=\(.value)"')
	cp "$here/../../core/unbound/unbound.conf" "$out.template"
	env -i PATH="$PATH" "${envs[@]}" sh -c "$cmd"
}

unbound_file="$core/unbound/docker-compose.yml"
bind_file="$core/bind/docker-compose.yml"
chrony_file="$core/chrony/docker-compose.yml"

# 1. CORE_LISTEN set: BIND and chrony publish on it.
set_json="$(render "$unbound_file" CORE_LISTEN=10.0.0.5 CORE_LAN=10.0.0.0/24)"
bind_json="$(render "$bind_file" CORE_LISTEN=10.0.0.5)"
chrony_json="$(render "$chrony_file" CORE_LISTEN=10.0.0.5)"
check_published "$bind_json" bind 10.0.0.5
check_published "$chrony_json" chrony 10.0.0.5
printf '%s' "$bind_json" | jq -e '[.services.bind.ports[].published] | unique == ["5300"]' >/dev/null ||
	fail "bind publishes on a port other than 5300 with defaults"

# 2. CORE_LISTEN unset: loopback, as before.
unset_bind_json="$(render "$bind_file")"
unset_chrony_json="$(render "$chrony_file")"
unset_set_json="$(render "$unbound_file")"
check_published "$unset_bind_json" bind 127.0.0.1
check_published "$unset_chrony_json" chrony 127.0.0.1
printf '%s' "$unset_chrony_json" | jq -e '[.services.chrony.ports[].published] | unique == ["12300"]' >/dev/null ||
	fail "chrony publishes on a port other than 12300 with defaults"

# 3. The Unbound step with CORE_LISTEN set and CORE_LAN set: the interface, the stub and the LAN line.
mkdir "$tmp/lan"
unbound_step "$set_json" "$tmp/lan/unbound"
conf="$tmp/lan/unbound.conf"
grep -qx '	interface: 10.0.0.5@5353' "$conf" || fail "unbound interface is not 10.0.0.5@5353"
grep -qx '	stub-addr: 10.0.0.5@5300' "$conf" || fail "unbound stub-addr is not 10.0.0.5@5300"
grep -qx '	access-control: 10.0.0.0/24 allow' "$conf" || fail "unbound does not allow CORE_LAN"
grep -qx '	access-control: 127.0.0.0/8 allow' "$conf" || fail "unbound lost the loopback allow"
grep -qE '@[A-Z]+@' "$conf" && fail "unbound config still has a placeholder"

# 4. The Unbound step unset: loopback, no LAN line, the stub on 127.0.0.1@5300 as before.
mkdir "$tmp/unset"
unbound_step "$unset_set_json" "$tmp/unset/unbound"
conf="$tmp/unset/unbound.conf"
grep -qx '	interface: 127.0.0.1@5353' "$conf" || fail "unset: unbound interface is not 127.0.0.1@5353"
grep -qx '	stub-addr: 127.0.0.1@5300' "$conf" || fail "unset: unbound stub-addr is not 127.0.0.1@5300"
[ "$(grep -c 'access-control:.*allow' "$conf")" -eq 1 ] || fail "unset: unexpected access-control allow lines"
grep -qE '@[A-Z]+@' "$conf" && fail "unset: unbound config still has a placeholder"

# 5. zone.sh writes CORE_BIND_PORT into the transfer lines.
CORE_ROLE=primary CORE_PEER=10.0.0.2 CORE_BIND_PORT=5301 CORE_NAMED_OUT="$tmp/primary.conf" \
	bash "$core/bind/zone.sh" >/dev/null
grep -q 'also-notify { 10.0.0.2 port 5301; };' "$tmp/primary.conf" || fail "primary does not notify the peer on CORE_BIND_PORT"
CORE_ROLE=secondary CORE_PEER=10.0.0.1 CORE_BIND_PORT=5301 CORE_NAMED_OUT="$tmp/secondary.conf" \
	bash "$core/bind/zone.sh" >/dev/null
grep -q 'primaries { 10.0.0.1 port 5301; };' "$tmp/secondary.conf" || fail "secondary does not pull from the primary on CORE_BIND_PORT"

echo "listen test: ok (published on CORE_LISTEN and on loopback when unset; unbound interface, stub and CORE_LAN; zone.sh peer ports)"
