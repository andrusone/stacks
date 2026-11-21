#!/usr/bin/env bash
# The core backup test (ST266, CORE-FR-06 MVP 3). A fixture checkout in a temp folder: a git repository with
# a tracked file, git-ignored .env (secret values in it) and bind/named.generated.conf, a fake deploy key in a
# fake HOME (its private half holds marker bytes), and a fixture NAS folder. A date stub counts up so quick runs
# get distinct names. Checks: one archive and no temp file; eight runs leave seven, the newest kept; the archive
# lists only notes.txt and the two ignored files, no private key; the .env names stay with blank values and no
# secret value is in the archive; notes.txt names the key's path, not its contents; a missing backup folder fails
# with one line; a backup folder inside compose/core-vm is refused.
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
# Test stub for date (ST266): "date -u +FORMAT" returns 20260101T000001Z, then 000002Z, and so on.
n=$(( $(cat "$DATE_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$DATE_COUNT"
printf '20260101T%06dZ\n' "$n"
STUB
chmod +x "$tmp/bin/date"
export DATE_COUNT="$tmp/date-count"
export PATH="$tmp/bin:$PATH"
export HOME="$tmp/home"

# The fixture checkout: the script under compose/core-vm, one tracked file, and git-ignored state.
stacks="$tmp/stacks"
mkdir -p "$stacks/compose/core-vm/test" "$stacks/compose/core/bind" "$HOME/.ssh"
cp "$script" "$stacks/compose/core-vm/backup.sh"
git -C "$stacks" init -q
printf '.env\n*.generated.conf\n' > "$stacks/.gitignore"
printf 'tracked\n' > "$stacks/compose/core/up.sh"
cat > "$stacks/compose/core-vm/.env" <<'ENV'
# the node's values
CORE_BIND=192.168.1.5
CORE_ZONE_KEY=sekrit-zone-key-7731
GIT_TOKEN=tok-value-9911
DB_PASSWORD=pw-value-5522
SAMPLE_SECRET=sample-value-3300
ENV
printf 'options { recursion no; };\n' > "$stacks/compose/core/bind/named.generated.conf"
printf 'BEGIN OPENSSH PRIVATE KEY private-key-bytes\n' > "$HOME/.ssh/id_ed25519_github"
printf 'ssh-ed25519 AAAAC3fixture test-key\n' > "$HOME/.ssh/id_ed25519_github.pub"

nas="$tmp/nas/core/backup"
mkdir -p "$nas"
run() {
	CORE_BACKUP="$nas" bash "$stacks/compose/core-vm/backup.sh"
}
count() {
	shopt -s nullglob
	local a=("$nas"/core-*.tar.gz)
	echo "${#a[@]}"
}

run >/dev/null || fail "first run exited non-zero"
[ "$(count)" = 1 ] || fail "one run should leave one archive, found $(count)"
[ -z "$(find "$nas" -mindepth 1 -name '.*')" ] || fail "a temporary .part file was left behind"

for _ in $(seq 7); do run >/dev/null || fail "run exited non-zero"; done
[ "$(count)" = 7 ] || fail "eight runs should leave seven archives, found $(count)"
[ -f "$nas/core-20260101T000008Z.tar.gz" ] || fail "the newest archive was not kept"
[ ! -f "$nas/core-20260101T000001Z.tar.gz" ] || fail "the oldest archive was not removed"

newest="$nas/core-20260101T000008Z.tar.gz"
files="$(tar -tzf "$newest" | LC_ALL=C sort)"
want="$(printf '%s\n' compose/core-vm/.env compose/core/bind/named.generated.conf notes.txt)"
[ "$files" = "$want" ] || fail "archive lists unexpected files: $files"

plain="$tmp/plain.tar"
gunzip -c "$newest" > "$plain"
grep -q 'BEGIN' "$plain" && fail "the archive holds a BEGIN line"
grep -q 'private-key-bytes' "$plain" && fail "the archive holds the deploy key"
for secret in sekrit-zone-key-7731 tok-value-9911 pw-value-5522 sample-value-3300; do
	grep -q -- "$secret" "$plain" && fail "the archive holds a secret value: $secret"
done

extract="$tmp/extract"
mkdir "$extract"
tar -xzf "$newest" -C "$extract"
env_out="$extract/compose/core-vm/.env"
grep -qx 'CORE_ZONE_KEY=' "$env_out" || fail "CORE_ZONE_KEY name missing or value not blank"
grep -qx 'GIT_TOKEN=' "$env_out" || fail "GIT_TOKEN name missing or value not blank"
grep -qx 'DB_PASSWORD=' "$env_out" || fail "DB_PASSWORD name missing or value not blank"
grep -qx 'SAMPLE_SECRET=' "$env_out" || fail "SAMPLE_SECRET name missing or value not blank"
grep -qx 'CORE_BIND=192.168.1.5' "$env_out" || fail "a plain value was not kept"
cmp -s "$extract/compose/core/bind/named.generated.conf" "$stacks/compose/core/bind/named.generated.conf" ||
	fail "restored named.generated.conf differs from the original"

notes="$extract/notes.txt"
grep -q "$HOME/.ssh/id_ed25519_github" "$notes" || fail "notes.txt does not name the deploy key's path"
grep -q 'Fingerprint:' "$notes" || fail "notes.txt has no fingerprint line"
grep -q 'private-key-bytes' "$notes" && fail "notes.txt holds the key contents"

out="$(CORE_BACKUP="$tmp/absent" bash "$stacks/compose/core-vm/backup.sh" 2>&1 >/dev/null)" &&
	fail "a missing backup folder exited zero"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "a missing folder should print one line, got: $out"
case "$out" in *missing*) ;; *) fail "the missing-folder message is wrong: $out" ;; esac

mkdir "$stacks/compose/core-vm/inside"
out="$(CORE_BACKUP="$stacks/compose/core-vm/inside" bash "$stacks/compose/core-vm/backup.sh" 2>&1 >/dev/null)" &&
	fail "a backup folder inside compose/core-vm was accepted"
case "$out" in *outside*) ;; *) fail "the inside-folder message is wrong: $out" ;; esac

echo "ok: backup.test.sh"
