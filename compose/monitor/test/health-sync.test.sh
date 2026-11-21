#!/usr/bin/env bash
# The health-sync test (ST242, HL-FR-13 MVP 3). A temp bare repository is the origin; its working copy
# holds the real generator (cmd/health, internal/) and two fixture health files. Stubs stand in for
# docker, curl and mise (mise x -- CMD runs CMD), so no Docker or ntfy is needed. Nothing is written
# outside the temp folder, which is removed on exit.
# Checks: a pushed file changes the config and restarts Gatus once; a second run with no change restarts
# nothing; a pushed removal removes its checks; a pushed broken file keeps the config byte-for-byte,
# posts one message naming the file, and a second run posts no second message; an unreachable origin
# exits 0 and keeps the config.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
src="$(cd "$here/../../.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export STUB_LOG="$tmp/stub.log"
: > "$STUB_LOG"

# The stubs: docker names one container for the compose service and logs each restart; curl logs each
# post; mise x -- CMD runs CMD.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Test stub for docker (ST242): "compose ... ps -q gatus" names a container; "restart ID" is logged.
case "$1" in
compose) echo gatus-test-id ;;
restart) echo "restart $2" >> "$STUB_LOG" ;;
*) exit 2 ;;
esac
STUB
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Test stub for curl (ST242): logs the message and the URL, which holds the topic.
echo "post $*" >> "$STUB_LOG"
STUB
cat > "$tmp/bin/mise" <<'STUB'
#!/usr/bin/env bash
# Test stub for mise (ST242): "mise x -- CMD..." runs CMD. The test needs no mise trust.
[ "$1" = x ] || exit 2
shift
[ "$1" = -- ] && shift
exec "$@"
STUB
chmod +x "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/mise"
# go is the repo's pinned toolchain: a mise shim needs a mise project, so link the real binary.
go_bin="$(cd "$src" && { mise which go 2>/dev/null || command -v go; })" || fail "no go toolchain"
[ -x "$go_bin" ] || fail "no go toolchain at $go_bin"
ln -s "$go_bin" "$tmp/bin/go"
export PATH="$tmp/bin:$PATH"

# A health file for a fixture target, valid unless its second argument is "broken".
health_file() {
	if [ "${2:-}" = broken ]; then
		printf 'host = "%s"\n' "$1"
		return
	fi
	printf 'host = "%s"\nservice = "%s:8080"\nrequest = "http://%s:8080/"\nexpect_status = 200\nneeds = []\n' "$1" "$1" "$1"
}

# The origin: a working copy with the real generator and the script, pushed to a bare repository.
mkdir -p "$tmp/work/health" "$tmp/work/compose/monitor"
cp -r "$src/cmd" "$src/internal" "$src/go.mod" "$tmp/work/"
cp "$here/../health-sync.sh" "$here/../health-sync.service" "$here/../health-sync.timer" "$tmp/work/compose/monitor/"
health_file probe-a > "$tmp/work/health/probe-a.toml"
git init -q -b main "$tmp/work"
git -C "$tmp/work" add -A
git -C "$tmp/work" commit -qm "first checks"
git init -q --bare "$tmp/origin.git"
git -C "$tmp/work" remote add origin "$tmp/origin.git"
git -C "$tmp/work" push -q origin main
git clone -q "$tmp/origin.git" "$tmp/checkout"

# The monitor's values, as setup.sh writes them to compose/monitor/.env (never committed).
topic=test-topic-7f3a
cat > "$tmp/checkout/compose/monitor/.env" <<ENV
MONITOR_DIR=$tmp/monitor
MONITOR_BIND=192.0.2.5
NTFY_PORT=8090
NTFY_TOPIC=$topic
ENV

# One run of the checkout's script. Sets rc and msg.
sync_run() {
	rc=0
	msg="$(bash "$tmp/checkout/compose/monitor/health-sync.sh" 2>&1)" || rc=$?
}

# Pushes one commit from the working copy to the origin. $1 is the message.
push_commit() {
	git -C "$tmp/work" add -A
	git -C "$tmp/work" commit -qm "$1"
	git -C "$tmp/work" push -q origin main
}

count() { grep -c "^$1" "$STUB_LOG" || true; }
config="$tmp/monitor/gatus/config.yaml"

# 1. The first run writes the config from the file and restarts Gatus.
sync_run
[ "$rc" -eq 0 ] || fail "first run exited $rc: $msg"
grep -q "probe-a" "$config" || fail "first run did not write probe-a's checks: $msg"
[ "$(count restart)" -eq 1 ] || fail "first run: expected one restart, log: $(cat "$STUB_LOG")"

# 2. A second run with no change restarts nothing and rewrites nothing.
cp "$config" "$tmp/config.before"
sync_run
[ "$rc" -eq 0 ] || fail "no change: exited $rc: $msg"
[ "$(count restart)" -eq 1 ] || fail "no change: restarted Gatus again"
cmp -s "$config" "$tmp/config.before" || fail "no change: the config changed"

# 3. A pushed new file changes the config and restarts Gatus once.
health_file probe-b > "$tmp/work/health/probe-b.toml"
push_commit "add probe-b"
sync_run
[ "$rc" -eq 0 ] || fail "new file: exited $rc: $msg"
grep -q "probe-b" "$config" || fail "new file did not reach the config"
[ "$(count restart)" -eq 2 ] || fail "new file: expected one more restart, log: $(cat "$STUB_LOG")"
grep -q "loaded 2 files" <<< "$msg" || fail "new file: no 'loaded 2 files' line: $msg"

# 4. A pushed removal removes its checks.
git -C "$tmp/work" rm -q health/probe-b.toml
push_commit "remove probe-b"
sync_run
[ "$rc" -eq 0 ] || fail "removal: exited $rc: $msg"
! grep -q "probe-b" "$config" || fail "removal left probe-b in the config"
[ "$(count restart)" -eq 3 ] || fail "removal: expected one more restart"

# 5. A pushed broken file keeps the last good config, posts one message naming the file, and exits 0.
cp "$config" "$tmp/config.good"
health_file probe-c broken > "$tmp/work/health/probe-c.toml"
push_commit "break probe-c"
sync_run
[ "$rc" -eq 0 ] || fail "broken file: exited $rc: $msg"
cmp -s "$config" "$tmp/config.good" || fail "broken file changed the config"
[ "$(count restart)" -eq 3 ] || fail "broken file restarted Gatus"
grep -q "health-sync: rejected probe-c.toml, kept the last good checks" <<< "$msg" || fail "no rejection line names probe-c.toml: $msg"
! grep -q "$topic" <<< "$msg" || fail "the topic was printed"
[ "$(count post)" -eq 1 ] || fail "broken file: expected one post, log: $(cat "$STUB_LOG")"
grep -q "probe-c.toml" "$STUB_LOG" || fail "the post does not name probe-c.toml"

# 6. A second run on the same bad commit posts nothing more.
sync_run
[ "$rc" -eq 0 ] || fail "second bad run: exited $rc: $msg"
[ "$(count post)" -eq 1 ] || fail "second bad run posted again"
cmp -s "$config" "$tmp/config.good" || fail "second bad run changed the config"

# 7. An unreachable origin exits 0 and keeps the config.
mv "$tmp/origin.git" "$tmp/origin.gone"
sync_run
[ "$rc" -eq 0 ] || fail "origin gone: exited $rc: $msg"
grep -q "origin pull failed" <<< "$msg" || fail "origin gone: no line says the pull failed: $msg"
cmp -s "$config" "$tmp/config.good" || fail "origin gone changed the config"

echo "health-sync test: ok (7 checks)"
