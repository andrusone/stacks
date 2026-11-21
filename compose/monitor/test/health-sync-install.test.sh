#!/usr/bin/env bash
# The monitor timers' installer test (ST247 health sync, ST257 heartbeat; HL-FR-13, HL-FR-09). Sources the real
# compose/monitor/health-sync-install.sh with the helpers setup.sh provides (change, step, report) copied here, and
# stubs for sudo, systemctl and id, so nothing is installed on this machine. The units go to a temp etc folder, the
# groups to a temp file, and the monitor folders are temp folders; the temp folder is removed on exit.
# Checks: a first run installs the four units (ExecStart and User= for this checkout), enables both timers and
# grants the groups, counting changes; a second run counts 0; a dry run changes nothing; with no systemd it prints
# the command and counts nothing; --check reports ok after the first run and missing before it.
# shellcheck disable=SC2034 # the variables set below are read by the sourced installer
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
src="$(cd "$here/../../.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# The helpers setup.sh provides, as the installer uses them.
CHANGES=0
MISSING=()
step() { echo "[step] $*"; }
change() {
	local description=$1
	shift
	CHANGES=$((CHANGES + 1))
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[dry-run] would: $description"
		return 0
	fi
	echo "[change] $description"
	"$@"
}
report() {
	local state=$1 label=$2 detail=$3
	if [ "$state" = ok ]; then
		echo "$label: ok ($detail)"
	else
		echo "$label: missing ($detail)"
		MISSING+=("$label")
	fi
}
systemd_present() { [ "${NO_SYSTEMD:-0}" -ne 1 ]; }

# The stubs. sudo runs the command as this user, except usermod, which the test records in a groups file that
# the id stub reads back; systemctl is a stub on PATH that keeps each timer's state in a file of its own.
export STUB_LOG="$tmp/stub.log" GROUPS_FILE="$tmp/groups" TIMER_STATE="$tmp/timer-enabled"
: > "$STUB_LOG"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
# Test stub for systemctl (ST247, ST257): logs changes; a unit is enabled when $TIMER_STATE.<unit> exists.
case "$1" in
daemon-reload) echo "daemon-reload" >> "$STUB_LOG" ;;
is-enabled | is-active) [ -f "$TIMER_STATE.${*: -1}" ] ;;
enable)
	shift
	echo "enable $*" >> "$STUB_LOG"
	for unit in "$@"; do
		[ "$unit" = --now ] || touch "$TIMER_STATE.$unit"
	done
	;;
*) exit 2 ;;
esac
STUB
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH"

sudo() {
	case "$1" in
	usermod)
		echo "usermod $3 $4" >> "$STUB_LOG"
		echo "$3" >> "$GROUPS_FILE"
		;;
	*) "$@" ;;
	esac
}
id() {
	if [ "${1:-}" = -nG ]; then
		# Only this user's primary group and the groups the test granted: never the real account's groups.
		printf '%s %s\n' "$(command id -gn "$2")" "$(tr '\n' ' ' < "$GROUPS_FILE" 2>/dev/null || true)"
	else
		command id "$@"
	fi
}

# The checkout: the real unit files and scripts, and the monitor folders in temp.
mkdir -p "$tmp/checkout/compose/monitor" "$tmp/monitor/gatus" "$tmp/etc/systemd/system"
cp "$src/compose/monitor/health-sync.sh" "$src/compose/monitor/health-sync.service" \
	"$src/compose/monitor/health-sync.timer" "$src/compose/monitor/heartbeat.sh" \
	"$src/compose/monitor/heartbeat.service" "$src/compose/monitor/heartbeat.timer" "$tmp/checkout/compose/monitor/"
cp "$src/compose/monitor/health-sync-install.sh" "$tmp/checkout/compose/monitor/"
chmod 755 "$tmp/monitor" "$tmp/monitor/gatus"

REPO_DIR="$tmp/checkout"
RUN_USER="$(command id -un)"
MONITOR_USER="$RUN_USER"
MONITOR_DIR="$tmp/monitor"
GATUS_DIR="$tmp/monitor/gatus"
DRY_RUN=0
CHECK=0
HEALTH_SYNC_UNITS="$tmp/etc/systemd/system"
# shellcheck source=/dev/null
source "$src/compose/monitor/health-sync-install.sh"

# 1. A dry run lists the steps and creates nothing.
DRY_RUN=1
hs_run > "$tmp/dry.out"
DRY_RUN=0
grep -q "would: install $tmp/etc/systemd/system/health-sync.service" "$tmp/dry.out" || fail "dry run did not list the service unit"
grep -q "would: install $tmp/etc/systemd/system/heartbeat.service" "$tmp/dry.out" || fail "dry run did not list the heartbeat unit"
[ ! -e "$tmp/etc/systemd/system/health-sync.service" ] || fail "dry run wrote a unit"
[ "$CHANGES" -gt 0 ] || fail "dry run counted no changes"
CHANGES=0
: > "$STUB_LOG"

# 2. The first run installs and enables, and counts its changes.
hs_run
[ "$CHANGES" -eq 8 ] || fail "first run: expected 8 changes (4 units, reload, 2 enables, groups), got $CHANGES"
for name in health-sync heartbeat; do
	svc="$tmp/etc/systemd/system/$name.service"
	grep -qx "ExecStart=$src/compose/monitor/$name.sh" "$svc" && fail "$name ExecStart points at the source checkout, not the test checkout"
	grep -qx "ExecStart=$tmp/checkout/compose/monitor/$name.sh" "$svc" || fail "$name ExecStart is not this checkout's script"
	grep -qx "User=$RUN_USER" "$svc" || fail "no User=$RUN_USER in $name.service"
	cmp -s "$tmp/etc/systemd/system/$name.timer" "$src/compose/monitor/$name.timer" || fail "$name timer unit differs from the checkout's file"
	[ -f "$TIMER_STATE.$name.timer" ] || fail "$name.timer was not enabled"
	grep -q "^enable --now $name.timer$" "$STUB_LOG" || fail "enable --now $name.timer not called: $(cat "$STUB_LOG")"
done
grep -qx docker "$GROUPS_FILE" || fail "$RUN_USER not added to docker"
[ "$(stat -c %A "$MONITOR_DIR" | cut -c6)" = w ] || fail "$MONITOR_DIR not group-writable"
[ "$(stat -c %A "$GATUS_DIR" | cut -c6)" = w ] || fail "$GATUS_DIR not group-writable"

# 3. A second run counts nothing.
CHANGES=0
hs_run > "$tmp/second.out"
[ "$CHANGES" -eq 0 ] || fail "second run: changes $CHANGES, expected 0: $(cat "$tmp/second.out")"

# 4. --check, after the install, reports ok.
MISSING=()
hs_check > "$tmp/check.out"
[ "${#MISSING[@]}" -eq 0 ] || fail "--check after install: missing ${MISSING[*]}: $(cat "$tmp/check.out")"
grep -q "monitor timers (health-sync, heartbeat): ok" "$tmp/check.out" || fail "--check: no timer ok line"

# 5. With no systemd, the command is printed and nothing is counted.
NO_SYSTEMD=1
CHANGES=0
hs_run > "$tmp/nosystemd.out"
NO_SYSTEMD=0
[ "$CHANGES" -eq 0 ] || fail "no systemd: counted $CHANGES changes"
grep -q "sudo systemctl enable --now health-sync.timer heartbeat.timer" "$tmp/nosystemd.out" || fail "no systemd: the command is not printed"

# 6. --check before an install reports the timers and the user missing.
HEALTH_SYNC_UNITS="$tmp/etc2/systemd/system"
MISSING=()
rm -f "$TIMER_STATE".* "$GROUPS_FILE"
hs_check > "$tmp/check2.out"
[ "${#MISSING[@]}" -eq 2 ] || fail "--check on a fresh machine: expected 2 missing, got ${MISSING[*]:-none}"

echo "monitor timers install test: ok (6 checks)"
