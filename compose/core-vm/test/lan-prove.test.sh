#!/usr/bin/env bash
# The lan-prove test (ST215, CORE-FR-10 MVP 2): stubs of dig, nc and ntpdate on PATH in a temp folder.
# Each run clears the environment, so only PATH and the STUB_ values reach the script.
# Checks: all pass; one failed name; an open closed-port; a missing dig; no ntpdate means a skip;
# the DNS and time calls use the default ports 53 and 123 (ST223).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script="$here/../lan-prove.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash_bin="$(command -v bash)"
core=192.0.2.20

mkdir -p "$tmp/bin"
cat > "$tmp/bin/dig" <<'STUB'
#!/usr/bin/env bash
# Test stub for dig (ST215): answers only when the script asks the core node (@$STUB_CORE_IP).
[ -n "${STUB_LOG:-}" ] && echo "dig $*" >> "$STUB_LOG"
server=""; name=""
for a; do case "$a" in @*) server="${a#@}" ;; +*|A) ;; *) name="$a" ;; esac; done
[ "$server" = "$STUB_CORE_IP" ] || exit 0
case "$name" in
dnssec-failed.org) echo ";; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1"; exit 0 ;;
"$STUB_FAIL") echo ";; communications error to $server#53: timed out"; exit 0 ;;
*) echo "192.0.2.99" ;;
esac
STUB
cat > "$tmp/bin/nc" <<'STUB'
#!/usr/bin/env bash
# Test stub for nc (ST215): `nc -z -w 3 IP PORT` succeeds only for a port listed in $STUB_OPEN.
port="${*: -1}"
for p in $STUB_OPEN; do [ "$p" = "$port" ] && exit 0; done
exit 1
STUB
cat > "$tmp/bin/ntpdate" <<'STUB'
#!/usr/bin/env bash
# Test stub for ntpdate (ST215): `ntpdate -q IP` prints a fixed offset.
[ -n "${STUB_LOG:-}" ] && echo "ntpdate $*" >> "$STUB_LOG"
echo "server $2, stratum 2, offset 0.000312, delay 0.02345"
STUB
chmod +x "$tmp/bin/"*

# A folder with no ntpdate, and one with no dig. Every folder links bash: the stubs start with env.
mkdir -p "$tmp/nontp" "$tmp/nodig"
ln -s "$tmp/bin/dig" "$tmp/nontp/dig"
ln -s "$tmp/bin/nc" "$tmp/nontp/nc"
ln -s "$tmp/bin/nc" "$tmp/nodig/nc"
for d in bin nontp nodig; do ln -s "$bash_bin" "$tmp/$d/bash"; done

fail() { echo "FAIL: $*" >&2; exit 1; }

# run <PATH folder> <script args...>: sets rc and out. STUB_FAIL and STUB_OPEN come from this shell.
run() {
	local path="$1"
	shift
	rc=0
	out="$(env -i STUB_CORE_IP="$core" STUB_FAIL="${STUB_FAIL:-}" STUB_OPEN="${STUB_OPEN:-}" STUB_LOG="${STUB_LOG:-}" \
		PATH="$path" "$bash_bin" "$script" "$@" 2>&1)" || rc=$?
}

count() { grep -c "^$1" <<<"$out" || true; }

# 1. Everything passes: one ok per check (name, example.com, dnssec, time, five closed ports), exit 0.
run "$tmp/bin" "$core"
[ "$rc" -eq 0 ] || fail "all pass exited $rc: $out"
[ "$(count ok)" -eq 9 ] || fail "all pass: want 9 ok lines: $out"
[ "$(count FAIL)" -eq 0 ] || fail "all pass: unexpected FAIL: $out"

# 2. One failed name: exit 1 and exactly one FAIL, for example.com.
STUB_FAIL=example.com run "$tmp/bin" "$core"
[ "$rc" -eq 1 ] || fail "one failure exited $rc, want 1"
[ "$(count FAIL)" -eq 1 ] || fail "one failure: want 1 FAIL line: $out"
grep -q '^FAIL dns: example.com' <<<"$out" || fail "one failure: FAIL line does not name example.com: $out"

# 3. A closed port that accepts: exit 1 and one FAIL for 5353.
STUB_OPEN=5353 run "$tmp/bin" "$core" --closed 5353 12300
[ "$rc" -eq 1 ] || fail "open port exited $rc, want 1"
[ "$(count FAIL)" -eq 1 ] || fail "open port: want 1 FAIL line: $out"
grep -q '^FAIL closed: 192.0.2.20:5353' <<<"$out" || fail "open port: FAIL does not name 5353: $out"

# 4. A missing tool: exit 1, and only dig is named.
run "$tmp/nodig" "$core"
[ "$rc" -eq 1 ] || fail "missing dig exited $rc, want 1"
[ "$out" = "FAIL tools: missing dig" ] || fail "missing dig: want one line naming dig: $out"

# 5. No ntpdate: the time check is a skip line, not a failure, and the run passes.
run "$tmp/nontp" "$core"
[ "$rc" -eq 0 ] || fail "no ntpdate exited $rc: $out"
grep -qx 'skip time: no ntpdate on this client' <<<"$out" || fail "no ntpdate: no skip line: $out"
[ "$(count FAIL)" -eq 0 ] || fail "no ntpdate: unexpected FAIL: $out"

# 6. The default closed ports include 5300, and the DNS and time calls ask <core-ip> on the default ports.
calls="$tmp/calls"
: > "$calls"
STUB_LOG="$calls" run "$tmp/bin" "$core"
[ "$rc" -eq 0 ] || fail "default ports exited $rc: $out"
grep -q '^ok closed: 192.0.2.20:5300 refuses' <<<"$out" || fail "5300 is not probed closed by default: $out"
grep -q '^ok closed: 192.0.2.20:8080 refuses' <<<"$out" || fail "8080 is not probed closed by default: $out"
grep -q '^dig .*@192.0.2.20 ' "$calls" || fail "dig did not ask $core: $(cat "$calls")"
grep -qE '^dig .*(\+port|-p )' "$calls" && fail "dig was given a port: $(cat "$calls")"
grep -qx "ntpdate -q $core" "$calls" || fail "ntpdate was not asked on the default port: $(cat "$calls")"

echo "ok lan-prove test: 6 cases"
