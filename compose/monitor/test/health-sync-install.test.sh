#!/usr/bin/env bash
# The monitor timers' installer test (ST247 health sync, HL-FR-13; ST260 backup, HL-FR-14). Sources the real compose/monitor/health-sync-install.sh
# with the helpers setup.sh provides (change, step, report) copied here, and stubs for sudo, systemctl and id,
# so nothing is installed on this machine. The units go to a temp etc folder, the groups to a temp file, and the
# monitor folders are temp folders; the temp folder is removed on exit. The origin (ST261): a path origin becomes SSH
# with the key and is left alone without it, and an SSH origin is unchanged.
# Checks: a first run installs the four units (ExecStart and User= for this checkout; the heartbeat's ExecStart is
# its own script, ST257), enables both timers and grants the groups, counting changes; a second run counts 0; a dry run changes nothing; with no systemd it prints the
# command and counts nothing; --check reports both ok after the first run and missing before it.
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
# the id stub reads back; systemctl is a stub on PATH that keeps each timer's state in a file ($TIMER_STATE-<unit>).
export STUB_LOG="$tmp/stub.log" GROUPS_FILE="$tmp/groups" TIMER_STATE="$tmp/timer-enabled"
: > "$STUB_LOG"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
# Test stub for systemctl (ST247, ST257): logs changes; a timer is enabled when its state file exists.
case "$1" in
daemon-reload) echo "daemon-reload" >> "$STUB_LOG" ;;
is-enabled | is-active) [ -f "$TIMER_STATE-${!#}" ] ;;
enable) shift; echo "enable $*" >> "$STUB_LOG"; touch "$TIMER_STATE-${!#}" ;;
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

# The checkout: the real unit files and script, and the monitor folders in temp.
mkdir -p "$tmp/checkout/compose/monitor" "$tmp/monitor/gatus" "$tmp/etc/systemd/system"
cp "$src/compose/monitor/health-sync.sh" "$src/compose/monitor/health-sync.service" \
	"$src/compose/monitor/health-sync.timer" "$src/compose/monitor/heartbeat.service" \
	"$src/compose/monitor/heartbeat.timer" "$src/compose/monitor/backup.sh" \
	"$src/compose/monitor/backup.service" "$src/compose/monitor/backup.timer" "$tmp/checkout/compose/monitor/"
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
export MONITOR_BACKUP="$tmp/nas/backup"
mkdir -p "$MONITOR_BACKUP"
source "$src/compose/monitor/health-sync-install.sh"

# 1. A dry run lists the steps and creates nothing.
DRY_RUN=1
hs_run > "$tmp/dry.out"
DRY_RUN=0
grep -q "would: install $tmp/etc/systemd/system/health-sync.service" "$tmp/dry.out" || fail "dry run did not list the service unit"
[ ! -e "$tmp/etc/systemd/system/health-sync.service" ] || fail "dry run wrote a unit"
[ "$CHANGES" -gt 0 ] || fail "dry run counted no changes"
CHANGES=0
: > "$STUB_LOG"

# 2. The first run installs and enables, and counts its changes.
hs_run
[ "$CHANGES" -eq 11 ] || fail "first run: expected 11 changes (6 units, reload, 3 enables, groups), got $CHANGES"
svc="$tmp/etc/systemd/system/health-sync.service"
grep -qx "ExecStart=$src/compose/monitor/health-sync.sh" "$svc" && fail "ExecStart points at the source checkout, not the test checkout"
grep -qx "ExecStart=$tmp/checkout/compose/monitor/health-sync.sh" "$svc" || fail "ExecStart is not this checkout's script"
grep -qx "User=$RUN_USER" "$svc" || fail "no User=$RUN_USER in the service"
cmp -s "$tmp/etc/systemd/system/health-sync.timer" "$src/compose/monitor/health-sync.timer" || fail "timer unit differs from the checkout's file"
hb="$tmp/etc/systemd/system/heartbeat.service"
grep -qx "ExecStart=$tmp/checkout/compose/monitor/heartbeat.sh" "$hb" || fail "heartbeat ExecStart is not this checkout's heartbeat.sh"
grep -qx "User=$RUN_USER" "$hb" || fail "no User=$RUN_USER in the heartbeat service"
cmp -s "$tmp/etc/systemd/system/heartbeat.timer" "$src/compose/monitor/heartbeat.timer" || fail "heartbeat timer unit differs from the checkout's file"
[ -f "$TIMER_STATE-health-sync.timer" ] || fail "the health-sync timer was not enabled"
[ -f "$TIMER_STATE-heartbeat.timer" ] || fail "the heartbeat timer was not enabled"
grep -q "^enable --now health-sync.timer$" "$STUB_LOG" || fail "enable --now not called: $(cat "$STUB_LOG")"
grep -q "^enable --now heartbeat.timer$" "$STUB_LOG" || fail "enable --now heartbeat.timer not called"
grep -q "^enable --now backup.timer$" "$STUB_LOG" || fail "enable --now backup.timer not called"
[ -f "$TIMER_STATE-backup.timer" ] || fail "the backup timer was not enabled"
bsvc="$tmp/etc/systemd/system/backup.service"
grep -qx "ExecStart=$tmp/checkout/compose/monitor/backup.sh" "$bsvc" || fail "backup ExecStart is not this checkout's backup.sh"
grep -qx "User=$RUN_USER" "$bsvc" || fail "no User=$RUN_USER in the backup service"
cmp -s "$tmp/etc/systemd/system/backup.timer" "$src/compose/monitor/backup.timer" || fail "backup timer unit differs from the checkout's file"
grep -qx docker "$GROUPS_FILE" || fail "$RUN_USER not added to docker"
[ "$(stat -c %A "$MONITOR_DIR" | cut -c6)" = w ] || fail "$MONITOR_DIR not group-writable"
[ "$(stat -c %A "$GATUS_DIR" | cut -c6)" = w ] || fail "$GATUS_DIR not group-writable"

# 3. A second run counts nothing.
CHANGES=0
hs_run > "$tmp/second.out"
[ "$CHANGES" -eq 0 ] || fail "second run: changes $CHANGES, expected 0: $(cat "$tmp/second.out")"

# 4. --check, after the install, reports both ok.
MISSING=()
hs_check > "$tmp/check.out"
[ "${#MISSING[@]}" -eq 0 ] || fail "--check after install: missing ${MISSING[*]}: $(cat "$tmp/check.out")"
grep -q "health-sync timer: ok" "$tmp/check.out" || fail "--check: no timer ok line"

# 5. With no systemd, the command is printed and nothing is counted.
NO_SYSTEMD=1
CHANGES=0
hs_run > "$tmp/nosystemd.out"
NO_SYSTEMD=0
[ "$CHANGES" -eq 0 ] || fail "no systemd: counted $CHANGES changes"
grep -q "sudo systemctl enable --now health-sync.timer" "$tmp/nosystemd.out" || fail "no systemd: the command is not printed"

# 6. --check before an install reports the timer and the user missing.
HEALTH_SYNC_UNITS="$tmp/etc2/systemd/system"
MISSING=()
rm -f "$TIMER_STATE"-* "$GROUPS_FILE"
hs_check > "$tmp/check2.out"
[ "${#MISSING[@]}" -eq 2 ] || fail "--check on a fresh machine: expected 2 missing, got ${MISSING[*]:-none}"

# 6b. The backup timer waits for its folder (ST260): with the folder missing, no backup timer is enabled and one line
# says so; once the folder exists, the next run enables it.
HEALTH_SYNC_UNITS="$tmp/etc/systemd/system"
BACKUP_DIR="$tmp/nas/absent"
: > "$STUB_LOG"
hs_run > "$tmp/nobackup.out"
grep -qx "backup timer: not enabled, the backup folder $tmp/nas/absent is missing; host/nas-layout.sh makes it" "$tmp/nobackup.out" || fail "missing backup folder: no one-line message: $(cat "$tmp/nobackup.out")"
grep -q "backup.timer" "$STUB_LOG" && fail "missing backup folder: a backup timer command ran: $(cat "$STUB_LOG")"
[ ! -f "$TIMER_STATE-backup.timer" ] || fail "missing backup folder: the backup timer is enabled"
BACKUP_DIR="$MONITOR_BACKUP"
hs_run > "$tmp/withbackup.out"
[ -f "$TIMER_STATE-backup.timer" ] || fail "backup folder exists: the backup timer was not enabled: $(cat "$tmp/withbackup.out")"

# 7. The origin (ST261): a path origin becomes SSH once the key exists (one change, a second run counts none);
# without the key a path origin is left alone and the message says how to get one; an SSH origin is unchanged.
REPO_DIR="$tmp/origin-repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" remote add origin "$tmp/nas/stacks.git"
HS_KEY="$tmp/key"
: > "$HS_KEY"
CHANGES=0
hs_origin > "$tmp/origin-a.out"
[ "$(git -C "$REPO_DIR" remote get-url origin)" = "$HS_ORIGIN_SSH" ] || fail "path origin with the key: not switched to $HS_ORIGIN_SSH"
[ "$CHANGES" -eq 1 ] || fail "path origin with the key: changes $CHANGES, expected 1"
grep -q "^\[change\] health-sync origin: $tmp/nas/stacks.git -> $HS_ORIGIN_SSH" "$tmp/origin-a.out" || fail "path origin: no change line: $(cat "$tmp/origin-a.out")"
CHANGES=0
hs_origin
[ "$CHANGES" -eq 0 ] || fail "origin second run: changes $CHANGES, expected 0"

git -C "$REPO_DIR" remote set-url origin "$tmp/nas/stacks.git"
HS_KEY="$tmp/no-such-key"
CHANGES=0
hs_origin > "$tmp/origin-b.out"
[ "$(git -C "$REPO_DIR" remote get-url origin)" = "$tmp/nas/stacks.git" ] || fail "path origin without the key: origin was changed"
[ "$CHANGES" -eq 0 ] || fail "path origin without the key: counted $CHANGES changes"
grep -q "run git-access --role prod --deploy-repo andrusone/stacks, then rerun" "$tmp/origin-b.out" || fail "path origin without the key: no message: $(cat "$tmp/origin-b.out")"

git -C "$REPO_DIR" remote set-url origin "$HS_ORIGIN_SSH"
CHANGES=0
hs_origin > "$tmp/origin-c.out"
[ "$(git -C "$REPO_DIR" remote get-url origin)" = "$HS_ORIGIN_SSH" ] || fail "SSH origin: changed"
[ "$CHANGES" -eq 0 ] && [ ! -s "$tmp/origin-c.out" ] || fail "SSH origin: counted or printed: $(cat "$tmp/origin-c.out")"

# 8. render_env (ST270): a template key that setup.sh does not ask for is kept from the env file, or takes the
# template's default when none is stored, and never stops the run; a key setup.sh asks for takes its settled value.
# The two functions are taken from the real setup.sh, not copied.
ENV_FILE="$tmp/env"
ENV_EXAMPLE="$tmp/env.example"
declare -A ENV_VAL=()
printf 'MONITOR_USER=monitor\nGATUS_PORT=8081\n# a comment\nBESZEL_PORT=8091\n' > "$ENV_EXAMPLE"
eval "$(sed -n '/^kept_or_default() {/,/^}/p;/^render_env() {/,/^}/p' "$src/setup.sh")"
ENV_VAL[MONITOR_USER]=monitor
ENV_VAL[GATUS_PORT]=8082
printf 'MONITOR_USER=old\nGATUS_PORT=1\nBESZEL_PORT=8095\n' > "$ENV_FILE"
render_env > "$tmp/rendered.1" || fail "render_env with an extra key: exited non-zero"
grep -qx 'BESZEL_PORT=8095' "$tmp/rendered.1" || fail "render_env: stored BESZEL_PORT not kept: $(cat "$tmp/rendered.1")"
grep -qx 'GATUS_PORT=8082' "$tmp/rendered.1" || fail "render_env: asked GATUS_PORT not the settled value"
grep -qx '# a comment' "$tmp/rendered.1" || fail "render_env: comment line lost"
rm -f "$ENV_FILE"
render_env > "$tmp/rendered.2" || fail "render_env with no env file: exited non-zero"
grep -qx 'BESZEL_PORT=8091' "$tmp/rendered.2" || fail "render_env: no stored BESZEL_PORT, template default not written"
printf 'MONITOR_USER=old\n' > "$ENV_FILE"
render_env > "$tmp/rendered.3" || fail "render_env with an env file lacking the key: exited non-zero"
grep -qx 'BESZEL_PORT=8091' "$tmp/rendered.3" || fail "render_env: env file without the key, default not written"

echo "monitor timers install test: ok (8 checks, render_env 3 checks)"
