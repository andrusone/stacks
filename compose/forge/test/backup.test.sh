#!/usr/bin/env bash
# The forge backup test (ST271, FG-FR-03 MVP 4). The real age (mise) with a throwaway key pair made here,
# and stubs for docker and curl in a temp folder. A fixture zip stands in for `forgejo dump`: app.ini holds
# a SECRET_KEY line, data/ and repos/ hold marker files. Checks: no recipient is refused with one line; with
# the recipient in .env one forge-*.zip.age is written and nothing else is in the backup folder; the .age file
# does not hold the SECRET_KEY bytes; restore without an identity is refused; restore with it brings the
# markers back into an empty data folder. With age hidden from PATH (as under sudo) backup is refused with
# the install line and writes nothing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
forge="$here/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

command -v age >/dev/null || fail "age is not on PATH; run this with mise run check"

# The scripts under test, in a folder of their own so a .env written there is not the real one.
work="$tmp/forge"
mkdir -p "$work" "$tmp/bin" "$tmp/forge-fs" "$tmp/nas/forge/backup"
cp "$forge/backup.sh" "$forge/restore.sh" "$forge/up.sh" "$work/"

# Stubs: docker reports the container as STUB_RUNNING; `forgejo dump` writes the fixture zip into a fake
# container folder; `docker cp` copies it out; everything else succeeds. curl answers the health check.
cat > "$tmp/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Test stub for docker (ST271).
case "$1" in
inspect) echo "${STUB_RUNNING:-false}" ;;
exec)
	case " $* " in
	*" dump "*)
		for last; do :; done
		cp "$FIXTURE_ZIP" "$FORGE_FS/$(basename "$last")" || exit 1
		;;
	esac
	;;
cp) cp "$FORGE_FS/$(basename "${2#forge:}")" "$3" || exit 1 ;;
esac
exit 0
STUB
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Test stub for curl (ST271): the health check always answers.
exit 0
STUB
chmod +x "$tmp/bin/docker" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
export FORGE_FS="$tmp/forge-fs"
mkdir -p "$tmp/scratch"
export TMPDIR="$tmp/scratch"
export FORGE_DATA="$tmp/data" FORGE_BACKUP="$tmp/nas/forge/backup"

# The fixture archive: the secret is a byte string that must not appear in the encrypted file.
export FIXTURE_ZIP="$tmp/dump.zip"
python3 -I -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("app.ini", "SECRET_KEY = sekrit-forge-key-5150\n")
    z.writestr("data/gitea.db", "marker-db\n")
    z.writestr("repos/forge-admin/smoke.git/marker", "marker-repo\n")' "$FIXTURE_ZIP"

# A throwaway identity, made in the test and removed with the folder.
age-keygen -o "$tmp/identity" >/dev/null 2>&1 || fail "age-keygen could not make the test key"
recipient="$(age-keygen -y "$tmp/identity")" || fail "age-keygen -y failed"

# 1. No recipient anywhere: refused, one line naming the variable.
out="$(STUB_RUNNING=true bash "$work/backup.sh" 2>&1 >/dev/null)" && fail "backup with no recipient exited zero"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "no recipient should print one line, got: $out"
case "$out" in *FORGE_BACKUP_AGE_RECIPIENT*) ;; *) fail "the no-recipient message is wrong: $out" ;; esac
[ -z "$(ls -A "$FORGE_BACKUP")" ] || fail "a refused backup left files in the backup folder"

# 1b. age not on PATH (as under sudo, where mise's shim is missing): refused with the install line, nothing written.
mapfile -t path_dirs < <(tr : '\n' <<< "$PATH")
nopath="$tmp/bin"
for d in "${path_dirs[@]}"; do
  [ -x "$d/age" ] || nopath="$nopath:$d"
done
env PATH="$nopath" sh -c 'command -v age' >/dev/null 2>&1 && fail "could not hide age from PATH for the test"
out="$(env PATH="$nopath" FORGE_BACKUP_AGE_RECIPIENT="$recipient" STUB_RUNNING=true bash "$work/backup.sh" 2>&1 >/dev/null)" &&
	fail "backup without age on PATH exited zero"
case "$out" in *"install age"*) ;; *) fail "the no-age message is wrong: $out" ;; esac
[ -z "$(ls -A "$FORGE_BACKUP")" ] || fail "a backup without age left files in the backup folder"

# 2. The recipient in .env (the forge's own file), not in the environment: one encrypted archive.
printf 'FORGE_BACKUP_AGE_RECIPIENT=%s\n' "$recipient" > "$work/.env"
STUB_RUNNING=true bash "$work/backup.sh" >/dev/null || fail "backup with the recipient in .env failed"
shopt -s nullglob
listed=("$FORGE_BACKUP"/*)
[ "${#listed[@]}" = 1 ] || fail "the backup folder should hold one file, found: ${listed[*]:-none}"
archive="${listed[0]}"
case "$(basename "$archive")" in
forge-*.zip.age) ;;
*) fail "the archive name is wrong: $(basename "$archive")" ;;
esac
grep -aq 'sekrit-forge-key-5150' "$archive" && fail "the encrypted archive holds the SECRET_KEY bytes"
[ "$(head -c 2 "$archive")" = PK ] && fail "the archive starts as a plain zip"

# 3. Restore without an identity is refused and writes nothing.
mkdir -p "$FORGE_DATA"
out="$(env -u FORGE_BACKUP_AGE_IDENTITY STUB_RUNNING=false bash "$work/restore.sh" 2>&1)" &&
	fail "restore with no identity exited zero"
case "$out" in *FORGE_BACKUP_AGE_IDENTITY*) ;; *) fail "the no-identity message is wrong: $out" ;; esac
[ -z "$(ls -A "$FORGE_DATA")" ] || fail "a refused restore wrote into the data folder"

# 4. Restore with the identity brings the markers back.
FORGE_BACKUP_AGE_IDENTITY="$tmp/identity" STUB_RUNNING=false bash "$work/restore.sh" >/dev/null ||
	fail "restore with the identity failed"
[ "$(cat "$FORGE_DATA/gitea/gitea.db")" = marker-db ] || fail "gitea.db marker not restored"
[ "$(cat "$FORGE_DATA/git/repositories/forge-admin/smoke.git/marker")" = marker-repo ] ||
	fail "repository marker not restored"
[ -z "$(ls -A "$TMPDIR")" ] || fail "a step left a temp folder behind"

echo "ok: backup.test.sh"
