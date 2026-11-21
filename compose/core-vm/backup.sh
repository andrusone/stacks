#!/usr/bin/env bash
# The core node's backup (CORE-FR-06, MVP 3, ST266). Writes core-<UTC yyyymmddThhmmssZ>.tar.gz into $CORE_BACKUP
# (default /nas/cloud-backup/services/core/backup), under a temporary name and renamed when complete. Keeps the
# 7 newest. It archives only what git does not hold: the git-ignored files under compose/core-vm and compose/core
# (the node's .env, and generated config such as bind/named.generated.conf), with every key, token, password or
# secret value blanked (the names stay), and notes.txt naming the deploy key's path and fingerprint, never the key.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo="$(cd "$here/../.." && pwd -P)"
backup="$(realpath -m "${CORE_BACKUP:-/nas/cloud-backup/services/core/backup}")"
key="$HOME/.ssh/id_ed25519_github"
keep=7

if [ ! -d "$backup" ]; then
	echo "core-backup: backup folder $backup is missing; host/nas-layout.sh makes it" >&2
	exit 1
fi
case "$backup/" in
"$repo/compose/core/"* | "$repo/compose/core-vm/"*)
	echo "core-backup: CORE_BACKUP must be outside the folders it backs up" >&2
	exit 1
	;;
esac

name="core-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
part="$backup/.$name.part"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage" "$part"' EXIT

# Git-ignored files only, never a private key. The .env values with a key, token, password or secret name are blanked.
listed="$(git -C "$repo" ls-files --others --ignored --exclude-standard -- compose/core compose/core-vm)"
files=()
while IFS= read -r f; do
	case "$f" in "" | */id_* | *.pem | *.key) continue ;; esac
	mkdir -p "$stage/$(dirname "$f")"
	if [ "$(basename "$f")" = .env ]; then
		awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { if (toupper($1) ~ /KEY|TOKEN|PASS|SECRET/) { print $1 "="; next } } { print }' "$repo/$f" > "$stage/$f"
	else
		cp -- "$repo/$f" "$stage/$f"
	fi
	files+=("$f")
done <<< "$listed"

fingerprint="no public key at $key.pub"
if [ -f "$key.pub" ]; then fingerprint="$(ssh-keygen -lf "$key.pub" 2>/dev/null || echo "not readable")"; fi
printf '%s\n' "Deploy key: $key (present: $([ -f "$key" ] && echo yes || echo no); its contents are never archived)" "Fingerprint: $fingerprint" > "$stage/notes.txt"

tar -C "$stage" -czf "$part" notes.txt "${files[@]}"
mv -- "$part" "$backup/$name"

shopt -s nullglob
copies=("$backup"/core-*.tar.gz)
mapfile -t sorted < <(printf '%s\n' "${copies[@]}" | sort -r)
if [ "${#sorted[@]}" -gt "$keep" ]; then
	for old in "${sorted[@]:$keep}"; do
		rm -f -- "$old"
	done
fi

echo "core-backup: wrote $backup/$name"
