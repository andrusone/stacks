#!/usr/bin/env bash
# The forge's health-file check (FG-FR-09, ST263). The check reads origin/main, so the test makes a temporary
# bare origin and clones of it. A real forge setup needs Ubuntu, a /data disk, Docker and root, so the test runs
# the health section of compose/forge-vm/setup.sh itself: the lines from its section marker to the start-the-forge
# marker, read from the real file. Nothing is stubbed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script="$here/../setup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

bind=10.20.30.40
section="$tmp/health-section.sh"
sed -n '/^# --- the health file (FG-FR-09, ST263)/,/^# --- start the forge/p' "$script" | sed '$d' > "$section"
[ -s "$section" ] || { echo "FAIL: health section not found in setup.sh" >&2; exit 1; }

git_id=(-c user.name=test -c user.email=test@example.invalid)
origin="$tmp/origin.git"
seed="$tmp/seed"
git init -q --bare -b main "$origin"
git init -q -b main "$seed"
echo "stacks" > "$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" "${git_id[@]}" commit -q -m "base"
git -C "$seed" push -q "$origin" main

# Runs the real section in a checkout. MODE is run (fetches first) or dry (reads what the checkout has).
run_section() {
	local checkout=$1 mode=$2
	# The variables are read by the sourced section, which shellcheck cannot follow.
	# shellcheck disable=SC2034,SC2329
	(
		step() { :; }
		REPO_DIR="$checkout"
		MODE="$mode"
		ENV_PRESENT=1
		FORGE_BIND="$bind"
		# shellcheck source=/dev/null
		. "$section"
	)
}

expect_line() {
	local out=$1 line=$2
	if ! grep -Fxq -- "$line" <<<"$out"; then
		echo "FAIL: expected line: $line" >&2
		echo "got:" >&2
		echo "$out" >&2
		exit 1
	fi
}

missing="health file: missing. On your own machine run: go run ./cmd/health new forge $bind --commit, push, then rerun."

clone="$tmp/clone"
stale="$tmp/stale"
git clone -q "$origin" "$clone"
git clone -q "$origin" "$stale"

# 1. Not in git: the section says so and the one command, exits 0, and writes no file.
out="$(run_section "$clone" run)"
expect_line "$out" "$missing"
[ ! -e "$clone/health/forge.toml" ] || { echo "FAIL: setup wrote health/forge.toml" >&2; exit 1; }

# 2. The file is pushed to origin: a real run fetches and finds it.
mkdir -p "$seed/health"
printf 'host = "%s"\n' "$bind" > "$seed/health/forge.toml"
git -C "$seed" add health/forge.toml
git -C "$seed" "${git_id[@]}" commit -q -m "add forge health file"
git -C "$seed" push -q "$origin" main
out="$(run_section "$clone" run)"
expect_line "$out" "health file: in git"
[ ! -e "$clone/health/forge.toml" ] || { echo "FAIL: setup wrote health/forge.toml" >&2; exit 1; }

# 3. The stale clone has not fetched: a dry run reads its own origin/main and says missing, and does not fetch.
out="$(run_section "$stale" dry)"
expect_line "$out" "$missing"

# 4. The same stale clone on a real run fetches and finds the file.
out="$(run_section "$stale" run)"
expect_line "$out" "health file: in git"

echo "PASS: forge health-file check (4 cases: missing, in git after fetch, dry run does not fetch, real run fetches)"

# --- the backup timer (FG-FR-03, ST265) -------------------------------------
# The real backup section of setup.sh, with a stub systemctl on PATH, sudo run as this user, the units going to a
# temp folder and the NAS folder a temp folder. Nothing is installed here.
repo="$(cd "$here/../../.." && pwd -P)"
bdir="$tmp/backup"
mkdir -p "$bdir/bin" "$bdir/systemd"
bsection="$bdir/backup-section.sh"
sed -n '/^# --- the backup timer (FG-FR-03, ST265)/,/^# --- start the forge/p' "$script" | sed '$d' > "$bsection"
[ -s "$bsection" ] || { echo "FAIL: backup section not found in setup.sh" >&2; exit 1; }
cat > "$bdir/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
# Test stub: a timer is enabled and active when its state file exists; enable --now creates it.
case "$1" in
daemon-reload) echo "daemon-reload" >> "$BSTUB_LOG" ;;
is-enabled | is-active) [ -f "$BSTATE-${!#}" ] ;;
enable) echo "enable ${*: -1}" >> "$BSTUB_LOG"; touch "$BSTATE-${!#}" ;;
*) exit 2 ;;
esac
STUB
chmod +x "$bdir/bin/systemctl"
export PATH="$bdir/bin:$PATH" BSTUB_LOG="$bdir/stub.log" BSTATE="$bdir/timer-enabled"
sudo() { "$@"; }

# Runs the real section in MODE ($1); the NAS folder exists only when $2 is "nas".
run_backup() {
	local mode=$1 nas=$2
	# shellcheck disable=SC2030,SC2031,SC2034,SC2329
	(
		step() { echo "$*"; }
		change() {
			local description=$1
			shift
			CHANGES=$((CHANGES + 1))
			if [ "$MODE" = dry ]; then echo "[dry-run] would: $description"; return 0; fi
			echo "[change] $description"
			"$@"
		}
		REPO_DIR="$repo" ENV_FILE="$bdir/forge.env" MODE="$mode" ENV_PRESENT=1 CHANGES=0
		SYSTEMD_RUN_DIR="$bdir/systemd" FORGE_UNITS="$bdir/units" FORGE_NAS_BACKUP="$bdir/$nas/backup"
		# shellcheck source=/dev/null
		. "$bsection"
		echo "changes: $CHANGES"
	)
}

# 5. No NAS folder: the one line, no unit, no timer, no change.
out="$(run_backup run none)"
expect_line "$out" "backup timer: not installed, run host/nas-layout.sh first"
expect_line "$out" "changes: 0"
[ ! -e "$bdir/units/backup.timer" ] && [ ! -e "$bdir/timer-enabled-backup.timer" ] || { echo "FAIL: backup section installed without its folder" >&2; exit 1; }

# 6. The folder exists: first run installs both units (paths filled in), reloads, enables the timer: 4 changes.
mkdir -p "$bdir/nas/backup"
out="$(run_backup run nas)"
expect_line "$out" "changes: 4"
expect_line "$(cat "$bdir/stub.log")" "enable backup.timer"
grep -qx "ExecStart=/bin/bash $repo/compose/forge/backup.sh" "$bdir/units/backup.service" || { echo "FAIL: ExecStart not filled in" >&2; exit 1; }
grep -qx "EnvironmentFile=$bdir/forge.env" "$bdir/units/backup.service" || { echo "FAIL: EnvironmentFile not filled in" >&2; exit 1; }
grep -qx "Environment=FORGE_BACKUP=$bdir/nas/backup" "$bdir/units/backup.service" || { echo "FAIL: FORGE_BACKUP not filled in" >&2; exit 1; }
cmp -s "$bdir/units/backup.timer" "$repo/compose/forge/backup.timer" || { echo "FAIL: backup.timer differs from the repo file" >&2; exit 1; }

# 7. A rerun changes nothing and says the timer runs.
out="$(run_backup run nas)"
expect_line "$out" "changes: 0"
expect_line "$out" "backup.timer is enabled and running"

# 8. A dry run on a fresh units folder writes nothing (it says what it would install).
rm -rf "$bdir/units" "$bdir/timer-enabled-backup.timer"
out="$(run_backup dry nas)"
expect_line "$out" "changes: 4"
[ ! -e "$bdir/units" ] || { echo "FAIL: dry run wrote the units folder" >&2; exit 1; }

echo "PASS: forge backup timer (4 cases: no folder, first run installs and enables, rerun changes 0, dry run writes nothing)"
