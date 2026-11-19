#!/usr/bin/env bash
# Prove the Mullvad relay rollover (ST182, QBT-FR-02 MVP 1).
# Runs the unchanged qbt/ops/mullvad-health.sh against the mullvad and curl
# stubs in a temp folder that is removed on exit. No network, no real Mullvad.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
ops="${root}/qbt/ops/mullvad-health.sh"

fail() {
  echo "FAIL $*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

export STUB_STATE="${tmp}/state"
export MULLVAD_HEALTH_LOCK_FILE="${tmp}/mullvad-health.lock"
mkdir -p "${STUB_STATE}"
export PATH="${here}/stub:${PATH}"

# The relay list comes from the script itself, not a copy.
mapfile -t relays < <(
  sed -n '/^RELAYS=(/,/^)/p' "${ops}" |
    sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
)
((${#relays[@]} >= 2)) || fail "could not read RELAYS from ${ops}"

first="${relays[0]}"
second="${relays[1]}"

current_relay() {
  mullvad status -v | sed -n 's/^[[:space:]]*Relay: //p'
}

is_connected() {
  [[ "$(mullvad status -v | head -n 1)" == "Connected" ]]
}

run_health_script() {
  local rc=0
  OUT="$(bash "${ops}" 2>&1)" || rc=$?
  ((rc == 0)) || fail "mullvad-health.sh exited ${rc}: ${OUT}"
}

# (1) Connected on the first relay, which is marked bad: roll over to the second.
mullvad relay set location "${first}" >/dev/null
mullvad connect >/dev/null
printf '%s\n' "${first}" >"${STUB_STATE}/bad-relays"

run_health_script
is_connected || fail "not connected after rollover: ${OUT}"
[[ "$(current_relay)" == "${second}" ]] ||
  fail "expected relay ${second}, got $(current_relay): ${OUT}"
echo "ok rollover ${first} -> ${second}"

# (2) Connected on a relay that is not marked bad: no change.
: >"${STUB_STATE}/bad-relays"
mullvad relay set location "${second}" >/dev/null
mullvad connect >/dev/null

run_health_script
is_connected || fail "not connected after healthy check: ${OUT}"
[[ "$(current_relay)" == "${second}" ]] ||
  fail "healthy check changed relay to $(current_relay): ${OUT}"
echo "ok healthy no change"
