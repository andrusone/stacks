#!/usr/bin/env bash
# Write a state-consistent copy of the local Forgejo to the backup folder (ST67,
# FG-FR-03 MVP 1). The copy is made by the application: `forgejo dump` runs inside
# the running forge container and writes forge-<UTC yyyymmddThhmmssZ>.zip, which is
# copied out under a temporary name and renamed when complete. Only the 7 newest
# forge-* archives are kept. The backup folder is FORGE_BACKUP if set, else
# backup/ beside this script; it must lie outside the data folder (FORGE_DATA).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="$(realpath -m "${FORGE_DATA:-$here/data}")"
backup="$(realpath -m "${FORGE_BACKUP:-$here/backup}")"
keep=7

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

name="forge-$(date -u +%Y%m%dT%H%M%SZ).zip"
part="$backup/.$name.part"
mkdir -p "$backup"

cleanup() {
  rm -f -- "$part"
  docker exec --user git forge rm -f "/tmp/$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker exec --user git forge forgejo dump --type zip --file "/tmp/$name" >/dev/null
docker cp "forge:/tmp/$name" "$part" >/dev/null
mv -- "$part" "$backup/$name"
trap - EXIT
docker exec --user git forge rm -f "/tmp/$name" >/dev/null 2>&1 || true

shopt -s nullglob
copies=("$backup"/forge-*)
mapfile -t sorted < <(printf '%s\n' "${copies[@]}" | sort -r)
if [ "${#sorted[@]}" -gt "$keep" ]; then
  for old in "${sorted[@]:$keep}"; do
    rm -f -- "$old"
  done
fi

echo "forge-backup: wrote $backup/$name"
