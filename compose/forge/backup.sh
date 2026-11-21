#!/usr/bin/env bash
# Write a state-consistent, encrypted copy of the local Forgejo to the backup folder (ST67, ST271,
# FG-FR-03 MVP 1 and 4). The copy is made by the application: `forgejo dump` runs inside the running
# forge container and writes forge-<UTC yyyymmddThhmmssZ>.zip, which is copied out to a private temp
# folder, encrypted with age to FORGE_BACKUP_AGE_RECIPIENT (a public key, from the environment or
# .env beside this script), and written as forge-<stamp>.zip.age under a temporary name, renamed when
# complete. The plain zip never reaches the backup folder. With no recipient the script refuses.
# Only the 7 newest forge-* archives are kept. The backup folder is FORGE_BACKUP if set, else
# backup/ beside this script; it must lie outside the data folder (FORGE_DATA).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="$(realpath -m "${FORGE_DATA:-$here/data}")"
backup="$(realpath -m "${FORGE_BACKUP:-$here/backup}")"
keep=7

recipient="${FORGE_BACKUP_AGE_RECIPIENT:-}"
[ -n "$recipient" ] || recipient="$(sed -n 's/^FORGE_BACKUP_AGE_RECIPIENT=//p' "$here/.env" 2>/dev/null | tail -n 1 || true)"
[ -n "$recipient" ] || { echo "forge-backup: no FORGE_BACKUP_AGE_RECIPIENT; set the age public key in compose/forge/.env" >&2; exit 1; }

case "$backup/" in
  "$data/"*)
    echo "forge-backup: FORGE_BACKUP must be outside the data folder $data" >&2
    exit 1
    ;;
esac

if [ "$(docker inspect -f '{{.State.Running}}' forge 2>/dev/null || true)" != "true" ]; then
  echo "forge-backup: container forge is not running; start it with mise run forge-up" >&2
  exit 1
fi

name="forge-$(date -u +%Y%m%dT%H%M%SZ).zip.age"
zip="${name%.age}"
part="$backup/.$name.part"
stage="$(mktemp -d "${TMPDIR:-/tmp}/forge-backup.XXXXXX")"
mkdir -p "$backup"

cleanup() {
  rm -rf -- "$stage" "$part"
  docker exec --user git forge rm -f "/tmp/$zip" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker exec --user git forge forgejo dump --type zip --file "/tmp/$zip" >/dev/null
docker cp "forge:/tmp/$zip" "$stage/$zip" >/dev/null
age -r "$recipient" -o "$part" "$stage/$zip"
mv -- "$part" "$backup/$name"

shopt -s nullglob
copies=("$backup"/forge-*)
mapfile -t sorted < <(printf '%s\n' "${copies[@]}" | sort -r)
if [ "${#sorted[@]}" -gt "$keep" ]; then
  for old in "${sorted[@]:$keep}"; do
    rm -f -- "$old"
  done
fi

echo "forge-backup: wrote $backup/$name"
