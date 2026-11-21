#!/usr/bin/env bash
# The one-command setup for one core node (CORE-FR-10, MVP 2, ST218). Run as your normal user from a
# checkout of stacks: ./compose/core-vm/setup.sh [--yes | --dry-run]. It calls sudo itself where needed.
#
# - Asks once for the node's values: CORE_BIND, CORE_LAN, CORE_ADMIN, CORE_ZONE_URL (an http(s) URL with
#   an address, never a name), CORE_ROLE (primary or secondary) and CORE_PEER (empty until the other node
#   exists). Enter takes the default. A value in the environment skips its question; a value already in
#   compose/core-vm/.env is reused without asking. --yes takes every default. With no terminal and no
#   default it stops, naming the value.
# - Preflight (apt, systemd, Docker, mise): a missing one stops with a plain message and exit 2, before
#   anything is written.
# - Writes compose/core-vm/.env (mode 600) only when a value differs. The file is git-ignored.
# - Then the stages in setup-stages.sh, each checking first: host.sh with the LAN and admin values;
#   zone-sync.service and zone-sync.timer into /etc/systemd/system and /etc/core/zone-sync.env, the timer
#   enabled and started; a first zone sync through the service when BIND has no copy; mise run core-up
#   with the node's address and LAN and its ports (BIND 5300, DNS 53, NTP 123), so the peer reaches 5300 only.
# - Last, resolve_check: two lines saying whether this VM's resolver answers github.com and the internal probe
#   (CORE_PROBE_NAME in .env). Read-only; it never changes the exit code.
# - Ends "changes: n", the sum of every stage's changes. A second run ends "changes: 0".
# - --dry-run prints every step, asks nothing (values from the environment or the defaults) and writes
#   nothing. The change() wrapper is the only place a machine change happens.
# shellcheck disable=SC2034,SC2329 # the stages (setup-stages.sh) use these; change() calls them by name
set -euo pipefail

usage() { echo "usage: ./compose/core-vm/setup.sh [--yes | --dry-run]"; }

MODE=run
ASSUME_YES=0
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) MODE=dry ;;
		--yes) ASSUME_YES=1 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; echo "setup.sh: unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

if [ "$(id -u)" -eq 0 ]; then
	echo "setup.sh: run as your normal user, not root: ./compose/core-vm/setup.sh (it calls sudo itself)" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
KEYS=(CORE_BIND CORE_LAN CORE_ADMIN CORE_ZONE_URL CORE_ROLE CORE_PEER)
declare -A VAL=() STORED=()
CHANGES=0

step() { echo "[step] $*"; }

# The only place a machine change happens. --dry-run prints it and skips it.
change() {
	local description=$1
	shift
	CHANGES=$((CHANGES + 1))
	if [ "$MODE" = dry ]; then
		echo "[dry-run] would: $description"
		return 0
	fi
	echo "[change] $description"
	"$@"
}

# shellcheck disable=SC1091
. "$SCRIPT_DIR/setup-stages.sh"

# The values already in .env. STORED holds every key the file has, an empty one (CORE_PEER) included.
read_env() {
	local line key
	[ -f "$ENV_FILE" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			*=*)
				key="${line%%=*}"
				if [[ " ${KEYS[*]} " == *" $key "* ]]; then STORED[$key]="${line#*=}"; fi
				;;
		esac
	done < "$ENV_FILE"
}

# True when the file exists and holds exactly the settled values.
env_same() {
	local k
	[ -f "$ENV_FILE" ] || return 1
	for k in "${KEYS[@]}"; do
		[ "${STORED[$k]:-}" = "${VAL[$k]}" ] || return 1
	done
}

read_env
for key in "${KEYS[@]}"; do settle "$key"; done
preflight
if env_same; then
	step "$ENV_FILE already has these values"
else
	change "write $ENV_FILE (mode 600)" write_env_file
fi
run_host
zone_units
backup_units
first_zone_sync
core_up
resolve_check
echo "changes: $CHANGES"
