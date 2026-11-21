#!/usr/bin/env bash
# The LAN zone sync for the core VM (CORE-FR-07, MVP 2, ST212). Keeps a read-only clone of the zone
# repository (origin by address), pulls it, runs named-checkzone on the zone file in a throwaway
# container (as compose/core/bind/check.sh does), and only on a pass copies the file to CORE_ZONE_OUT,
# the folder BIND reads, through a temp file and a rename. An origin that cannot be reached or a zone
# that fails the check exits 0 and keeps the old copy, printing one line that says which.
# Values come from the environment; zone-sync.service reads them from /etc/core/zone-sync.env:
#   CORE_ZONE_URL   the origin, by address (http(s), or git@github.com:owner/repo.git over SSH)
#   CORE_ZONE_KEY   the SSH form's deploy key (optional; default ~/.ssh/id_ed25519_github)
#   CORE_ZONE_DIR   where the clone lives
#   CORE_ZONE_OUT   the folder BIND reads
#   CORE_ZONE_NAME  the zone's origin for the checker (core.andrusonline.com); the file is db.<name>
set -euo pipefail

: "${CORE_ZONE_URL:?set CORE_ZONE_URL in /etc/core/zone-sync.env}"
: "${CORE_ZONE_DIR:?set CORE_ZONE_DIR in /etc/core/zone-sync.env}"
: "${CORE_ZONE_OUT:?set CORE_ZONE_OUT in /etc/core/zone-sync.env}"
: "${CORE_ZONE_NAME:?set CORE_ZONE_NAME in /etc/core/zone-sync.env}"

image=internetsystemsconsortium/bind9:9.18
file="db.$CORE_ZONE_NAME"
# A timer must never wait on a credential prompt.
export GIT_TERMINAL_PROMPT=0
# The SSH form uses the node's deploy key (ST252) and the host keys in that key's folder, which
# git-access's key phase fills. Never StrictHostKeyChecking=no.
if [[ $CORE_ZONE_URL == git@* ]]; then
	key="${CORE_ZONE_KEY:-$HOME/.ssh/id_ed25519_github}"
	known="$(dirname "$key")/known_hosts"
	qkey="$(printf '%q' "$key")"
	qknown="$(printf '%q' "$known")"
	export GIT_SSH_COMMAND="ssh -i $qkey -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$qknown"
fi

if [ ! -d "$CORE_ZONE_DIR/.git" ]; then
	if ! git clone -q "$CORE_ZONE_URL" "$CORE_ZONE_DIR" 2>/dev/null; then
		echo "zone-sync: origin clone failed, kept the old copy in $CORE_ZONE_OUT"
		exit 0
	fi
elif ! git -C "$CORE_ZONE_DIR" pull -q --ff-only 2>/dev/null; then
	echo "zone-sync: origin pull failed, kept the old copy in $CORE_ZONE_OUT"
	exit 0
fi

if ! out="$(docker run --rm --entrypoint named-checkzone -v "$CORE_ZONE_DIR:/zone:ro" \
	"$image" "$CORE_ZONE_NAME" "/zone/$file" 2>&1)"; then
	echo "$out" >&2
	echo "zone-sync: zone check failed for $file, kept the old copy in $CORE_ZONE_OUT"
	exit 0
fi

mkdir -p "$CORE_ZONE_OUT"
tmp="$(mktemp "$CORE_ZONE_OUT/.$file.XXXXXX")"
cp "$CORE_ZONE_DIR/$file" "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$CORE_ZONE_OUT/$file"
echo "zone-sync: copied $file to $CORE_ZONE_OUT"
