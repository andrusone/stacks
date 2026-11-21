#!/usr/bin/env bash
# The zone-sync test (ST212, CORE-FR-07 MVP 2). A local bare repository is the origin; a stub docker
# runs a plain named-checkzone stub (a zone with BAD-ZONE in it fails), so no BIND image is needed.
# Checks: the first run clones; a pushed change reaches the out folder; a pushed bad zone does not;
# a removed origin leaves exit 0 and the copy.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script="$here/../zone-sync.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# The stubs: docker maps the -v folder and runs the named-checkzone stub on the zone file in it.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Test stub for docker (ST212): answers only "docker run ... named-checkzone ORIGIN /zone/FILE".
args=("$@")
host_dir=""
for ((i = 0; i < ${#args[@]}; i++)); do
	if [ "${args[i]}" = "-v" ]; then host_dir="${args[i + 1]%%:/zone*}"; fi
done
origin="${args[-2]}"
zone="${args[-1]}"
exec "$STUB_BIN/named-checkzone" "$origin" "$host_dir/${zone#/zone/}"
STUB
cat > "$tmp/bin/named-checkzone" <<'STUB'
#!/usr/bin/env bash
# Plain stand-in for named-checkzone (ST212): a zone file with BAD-ZONE in it fails.
if grep -q BAD-ZONE "$2"; then echo "zone $1: BAD-ZONE (stub)" >&2; exit 1; fi
echo "zone $1: loaded (stub)"
STUB
chmod +x "$tmp/bin/docker" "$tmp/bin/named-checkzone"
export STUB_BIN="$tmp/bin"
export PATH="$tmp/bin:$PATH"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# The origin: a working copy of the zone, pushed to a bare repository.
git init -q -b main "$tmp/work"
cat > "$tmp/work/db.core.example" <<'ZONE'
$ORIGIN core.example.
$TTL 300
ns1 IN A 192.0.2.21
ZONE
git -C "$tmp/work" add -A
git -C "$tmp/work" commit -qm "first zone"
git init -q --bare "$tmp/origin.git"
git -C "$tmp/work" remote add origin "$tmp/origin.git"
git -C "$tmp/work" push -q origin main

# One run of the script with the four values from the environment. Sets rc and msg.
sync_run() {
	rc=0
	msg="$(CORE_ZONE_URL="$tmp/origin.git" CORE_ZONE_DIR="$tmp/clone" CORE_ZONE_OUT="$tmp/out" \
		CORE_ZONE_NAME=core.example bash "$script" 2>&1)" || rc=$?
}

push_zone() {
	printf '%s\n' "$1" >> "$tmp/work/db.core.example"
	git -C "$tmp/work" commit -qam "$2"
	git -C "$tmp/work" push -q origin main
}

# 1. The first run clones and copies.
sync_run
[ "$rc" -eq 0 ] || fail "first run exited $rc: $msg"
[ -d "$tmp/clone/.git" ] || fail "first run did not clone"
cmp -s "$tmp/clone/db.core.example" "$tmp/out/db.core.example" || fail "first run did not copy the zone"

# 2. A pushed change reaches the out folder on the next run.
push_zone "www IN A 192.0.2.20" "add www"
sync_run
[ "$rc" -eq 0 ] || fail "good change: exited $rc: $msg"
grep -q "^www IN A 192.0.2.20$" "$tmp/out/db.core.example" || fail "good change did not reach the out folder"

# 3. A pushed bad zone does not: the old copy stays, exit 0, one line that says why.
push_zone "BAD-ZONE" "break the zone"
sync_run
[ "$rc" -eq 0 ] || fail "bad zone: exited $rc: $msg"
grep -q "zone check failed" <<< "$msg" || fail "bad zone: no line says the check failed: $msg"
grep -q "^www IN A 192.0.2.20$" "$tmp/out/db.core.example" || fail "bad zone replaced the good copy"
! grep -q BAD-ZONE "$tmp/out/db.core.example" || fail "bad zone reached the out folder"

# 4. The origin removed: exit 0, the copy stays, one line that says the pull failed.
mv "$tmp/origin.git" "$tmp/origin.gone"
sync_run
[ "$rc" -eq 0 ] || fail "origin removed: exited $rc: $msg"
grep -q "origin pull failed" <<< "$msg" || fail "origin removed: no line says the pull failed: $msg"
grep -q "^www IN A 192.0.2.20$" "$tmp/out/db.core.example" || fail "origin removed lost the copy"

echo "zone-sync test: ok (4 checks)"
