#!/usr/bin/env bash
# The heartbeat test (ST256, HL-FR-09 MVP 2). A curl stub in a temp folder stands in for both the local
# Gatus check (a /health URL, which succeeds when GATUS_UP=1) and the outside heartbeat (any other URL,
# logged as "beat"). Nothing reaches the network, and the temp folder is removed on exit.
# Checks: Gatus up sends one ping to the URL; Gatus down sends none; no URL exits 0 with the message and
# sends none; the URL never appears in the output, even when the outside service fails; the environment
# value wins over the .env one; the local check reads MONITOR_BIND and GATUS_PORT from .env, and falls back
# to 127.0.0.1:8080 when .env lacks them.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

unset HEARTBEAT_URL GATUS_PORT
export STUB_LOG="$tmp/stub.log"
: > "$STUB_LOG"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Test stub for curl (ST256): the last argument is the URL. A /health URL is the local Gatus check, up
# when GATUS_UP=1; any other URL is the outside heartbeat, logged, which fails when BEAT_FAIL=1.
for a; do url="$a"; done
case "$url" in
*/health)
	echo "check $url" >> "$STUB_LOG"
	[ "${GATUS_UP:-0}" = 1 ] ;;
*)
	echo "beat $url" >> "$STUB_LOG"
	[ "${BEAT_FAIL:-0}" = 0 ] ;;
esac
STUB
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"

# The checkout's copy of the script, with its own compose/monitor folder for the .env.
mkdir -p "$tmp/checkout/compose/monitor"
cp "$here/../heartbeat.sh" "$tmp/checkout/compose/monitor/"
env_file="$tmp/checkout/compose/monitor/.env"
url="https://beat.example.invalid/hb-7f3a9c"

# One run of the script. Sets rc and msg.
beat_run() {
	rc=0
	msg="$(bash "$tmp/checkout/compose/monitor/heartbeat.sh" 2>&1)" || rc=$?
}
beats() { grep -c '^beat' "$STUB_LOG" || true; }

# 1. Gatus up: one request to the URL, nothing printed.
printf 'HEARTBEAT_URL=%s\nMONITOR_BIND=192.0.2.10\nGATUS_PORT=8081\n' "$url" > "$env_file"
GATUS_UP=1 beat_run
[ "$rc" -eq 0 ] || fail "gatus up: exited $rc: $msg"
[ "$(beats)" -eq 1 ] || fail "gatus up: expected one beat, log: $(cat "$STUB_LOG")"
grep -qx "beat $url" "$STUB_LOG" || fail "gatus up: the beat did not go to the URL"
grep -qx "check http://192.0.2.10:8081/health" "$STUB_LOG" || fail "gatus up: the check did not use MONITOR_BIND and GATUS_PORT from .env"
[ -z "$msg" ] || fail "gatus up: printed output: $msg"

# 2. Gatus down: no request to the URL, and the run still exits 0.
GATUS_UP=0 beat_run
[ "$rc" -eq 0 ] || fail "gatus down: exited $rc: $msg"
[ "$(beats)" -eq 1 ] || fail "gatus down: sent a beat, log: $(cat "$STUB_LOG")"
grep -q "sent no ping" <<< "$msg" || fail "gatus down: no line says no ping was sent: $msg"
! grep -q "$url" <<< "$msg" || fail "gatus down: the URL was printed"

# 3. No URL: exit 0 with the message, and no request at all.
rm -f "$env_file"
before="$(wc -l < "$STUB_LOG")"
GATUS_UP=1 beat_run
[ "$rc" -eq 0 ] || fail "no URL: exited $rc: $msg"
grep -q "heartbeat: off, set HEARTBEAT_URL" <<< "$msg" || fail "no URL: no off line: $msg"
[ "$(wc -l < "$STUB_LOG")" -eq "$before" ] || fail "no URL: sent a request, log: $(cat "$STUB_LOG")"

# 4. The outside service fails: exit 0, a line without the URL.
printf 'HEARTBEAT_URL=%s\n' "$url" > "$env_file"
GATUS_UP=1 BEAT_FAIL=1 beat_run
[ "$rc" -eq 0 ] || fail "beat failed: exited $rc: $msg"
grep -q "did not take the ping" <<< "$msg" || fail "beat failed: no line says the ping failed: $msg"
! grep -q "$url" <<< "$msg" || fail "beat failed: the URL was printed"
grep -qx "check http://127.0.0.1:8080/health" "$STUB_LOG" || fail "beat failed: with no MONITOR_BIND or GATUS_PORT in .env the check did not fall back to 127.0.0.1:8080"

# 5. The environment value wins over the .env one.
other="https://beat.example.invalid/from-env"
HEARTBEAT_URL="$other" GATUS_UP=1 beat_run
[ "$rc" -eq 0 ] || fail "env value: exited $rc: $msg"
grep -qx "beat $other" "$STUB_LOG" || fail "env value: the environment URL was not used"

echo "heartbeat test: ok (5 checks)"
