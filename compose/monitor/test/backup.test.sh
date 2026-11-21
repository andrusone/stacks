#!/usr/bin/env bash
# The monitor backup test (ST250, HL-FR-14 MVP 3). Temp folders only: a fixture state folder with an
# ntfy cache, and a fixture NAS folder. A date stub counts up so quick runs get distinct names.
# Checks: one archive made with no temp file left; eight runs leave seven, the newest kept; a missing
# backup folder fails with its message; a backup folder inside the state folder is refused; the archive
# lists only the ntfy folder, holds no topic value, and restores the cache file byte-for-byte.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script="$here/../backup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

mkdir -p "$tmp/bin"
cat > "$tmp/bin/date" <<'STUB'
#!/usr/bin/env bash
# Test stub for date (ST250): "date -u +FORMAT" returns 20260101T000001Z, then 000002Z, and so on.
n=$(( $(cat "$DATE_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$DATE_COUNT"
printf '20260101T%06dZ\n' "$n"
STUB
chmod +x "$tmp/bin/date"
export DATE_COUNT="$tmp/date-count"
export PATH="$tmp/bin:$PATH"

topic="sekrit-topic-7731"
mon="$tmp/monitor"
nas="$tmp/nas/monitor/backup"
mkdir -p "$mon/ntfy" "$nas"
printf 'cache-bytes-42' > "$mon/ntfy/cache.db"

run() {
	MONITOR_DIR="$mon" MONITOR_BACKUP="$nas" NTFY_TOPIC="$topic" bash "$script"
}
count() {
	shopt -s nullglob
	local a=("$nas"/monitor-*.tar.gz)
	echo "${#a[@]}"
}

run >/dev/null || fail "first run exited non-zero"
[ "$(count)" = 1 ] || fail "one run should leave one archive, found $(count)"
[ -z "$(find "$nas" -mindepth 1 -name '.*')" ] || fail "a temporary .part file was left behind"

for _ in $(seq 7); do run >/dev/null || fail "run exited non-zero"; done
[ "$(count)" = 7 ] || fail "eight runs should leave seven archives, found $(count)"
[ -f "$nas/monitor-20260101T000008Z.tar.gz" ] || fail "the newest archive was not kept"
[ ! -f "$nas/monitor-20260101T000001Z.tar.gz" ] || fail "the oldest archive was not removed"

newest="$nas/monitor-20260101T000008Z.tar.gz"
files="$(tar -tzf "$newest")"
[ "$files" = "$(printf 'ntfy/\nntfy/cache.db')" ] || fail "archive lists unexpected files: $files"
plain="$tmp/plain.tar"
gunzip -c "$newest" > "$plain"
grep -q -- "$topic" "$plain" && fail "the archive holds the topic value"
restore="$tmp/restore"
mkdir "$restore"
tar -xf "$plain" -C "$restore"
cmp -s "$restore/ntfy/cache.db" "$mon/ntfy/cache.db" || fail "restored cache.db differs from the original"

out="$(MONITOR_DIR="$mon" MONITOR_BACKUP="$tmp/absent" bash "$script" 2>&1 >/dev/null)" &&
	fail "a missing backup folder exited zero"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "a missing folder should print one line, got: $out"
case "$out" in *missing*) ;; *) fail "the missing-folder message is wrong: $out" ;; esac

mkdir "$mon/backup"
out="$(MONITOR_DIR="$mon" MONITOR_BACKUP="$mon/backup" bash "$script" 2>&1 >/dev/null)" &&
	fail "a backup folder inside the state folder was accepted"
case "$out" in *outside*) ;; *) fail "the inside-folder message is wrong: $out" ;; esac

echo "ok: backup.test.sh"
