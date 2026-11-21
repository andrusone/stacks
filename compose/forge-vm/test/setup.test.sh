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
