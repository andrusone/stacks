#!/usr/bin/env bash
# Restore the local Forgejo's application state from the newest backup (ST69, FG-FR-14
# MVP 1). Run after the data folder has been emptied and forge-down has removed the
# container. The newest forge-*.zip in the backup folder (written by backup.sh, ST67) is
# unpacked into the data folder at the paths the image uses:
#   archive data/   -> <data>/gitea/           (gitea.db and its -wal/-shm, jwt, indexers, ...)
#   archive repos/  -> <data>/git/repositories/
# The archive does not hold admin.password, so the restore brings the forge up with
# up.sh and reports the password reset as a separate step. The data folder is FORGE_DATA
# if set, else data/ beside this script; the backup folder is FORGE_BACKUP if set, else
# backup/ beside this script (both resolved as in up.sh and backup.sh).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="$(realpath -m "${FORGE_DATA:-$here/data}")"
backup="$(realpath -m "${FORGE_BACKUP:-$here/backup}")"
url=http://127.0.0.1:3000

if [ "$(docker inspect -f '{{.State.Running}}' forge 2>/dev/null || true)" = "true" ]; then
  echo "forge-restore: container forge is running; stop it first with mise run forge-down" >&2
  exit 1
fi

mkdir -p "$data"
if [ -n "$(ls -A "$data")" ]; then
  echo "forge-restore: data folder $data is not empty; empty it first (restore writes only into an empty folder)" >&2
  exit 1
fi

shopt -s nullglob
copies=("$backup"/forge-*.zip)
if [ "${#copies[@]}" -eq 0 ]; then
  echo "forge-restore: no forge-*.zip in $backup; run mise run forge-backup on the old data first" >&2
  exit 1
fi
mapfile -t sorted < <(printf '%s\n' "${copies[@]}" | sort -r)
archive="${sorted[0]}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/forge-restore.XXXXXX")"
cleanup() {
  rm -rf -- "$tmp"
}
trap cleanup EXIT

unzip -q "$archive" -d "$tmp"
if [ ! -d "$tmp/data" ] || [ ! -d "$tmp/repos" ]; then
  echo "forge-restore: $archive has no data/ or repos/ folder" >&2
  exit 1
fi

mkdir -p "$data/gitea" "$data/git"
cp -a "$tmp/data/." "$data/gitea/"
cp -a "$tmp/repos" "$data/git/repositories"

has_pass=no
if [ -f "$tmp/admin.password" ]; then
  cp -a "$tmp/admin.password" "$data/admin.password"
  chmod 600 "$data/admin.password"
  has_pass=yes
fi

chown -R "$(id -u):$(id -g)" "$data"

# up.sh creates forge-admin when admin.password is absent. The restored database already
# has that user, so its create step fails after the forge is healthy; accept that failure
# only when the admin user is in the restored database and the forge answers.
if ! bash "$here/up.sh"; then
  if [ "$has_pass" = yes ] || ! curl -fsS -o /dev/null "$url/api/healthz"; then
    echo "forge-restore: up.sh failed" >&2
    exit 1
  fi
  users="$(docker exec --user git forge forgejo admin user list 2>/dev/null || true)"
  if ! grep -q 'forge-admin' <<< "$users"; then
    echo "forge-restore: up.sh failed and forge-admin is not in the restored database" >&2
    exit 1
  fi
fi

if [ "$has_pass" = yes ]; then
  echo "forge: restored from $(basename "$archive"); admin.password restored from the backup"
else
  echo "forge: restored; admin.password not in the backup, set a new password with the forgejo admin CLI"
fi
