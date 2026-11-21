#!/usr/bin/env bash
# nas-layout.sh: make the stack folders on the NAS and record where they are.
# Run as your normal user, on any VM that has /nas/cloud-backup mounted (the golden image does that):
#   ./host/nas-layout.sh                     first run: forge monitor core
#   ./host/nas-layout.sh qbt plex            add stacks; the ones already recorded are kept
#   ./host/nas-layout.sh                     on a rebuilt VM: recreates anything missing, reinstalls /etc/stacks/paths.env
#   ./host/nas-layout.sh --check             read only: PASS, FAIL or WARN per item; exits 1 on any FAIL
#
# What it makes, under STACKS_ROOT (default /nas/cloud-backup/services):
#   <stack>/backup   the stack's own backup job writes here (this is what reaches the cloud)
#   <stack>/config   config that is not in git and must survive
#   <stack>/data     live files, or a README naming the volumes that live outside this structure (the script never touches what is in it)
#   shared/          paths.env (the one record of this layout), README.txt, certs/ (public chains only)
# and /etc/stacks/paths.env on this VM, a copy of shared/paths.env, so a stack finds the roots with one source.
#
# Permissions: the share is a CIFS mount, which has no per-folder owner or mode. The mount gives every
# folder the person who ran the baseline as owner, group NAS_GROUP (default nas) and group write.
# A service gets access by its account being in that group. Per-stack isolation, if wanted, is set on
# the TrueNAS side, not here. This script only makes folders and warns when the group or write bit is off.
#
# Never put a secret or a private key under cloud-backup: everything there is sent to the cloud.
# It mounts nothing and edits no fstab. Prints [step] or [change] per item; ends "changes: n".
# Values may come from the environment: NAS_SHARE, STACKS_ROOT, NAS_GROUP, STACKS_ETC,
# NAS_MOUNT_CHECK=0 (tests only: skip the "is a network mount" check).
set -euo pipefail

SCRIPT_VERSION=1
NAS_SHARE=${NAS_SHARE:-/nas/cloud-backup}
NAS_GROUP=${NAS_GROUP:-nas}
STACKS_ROOT=${STACKS_ROOT:-$NAS_SHARE/services}
STACKS_ETC=${STACKS_ETC:-}
ETC_DIR=${STACKS_ETC:-/etc/stacks}
NAS_MOUNT_CHECK=${NAS_MOUNT_CHECK:-1}
DEFAULT_STACKS="forge monitor core"
SHARED=$STACKS_ROOT/shared
PATHS_NAS=$SHARED/paths.env
CHECK=0
CHANGES=0
FAILS=0

stop() {
	echo "nas-layout.sh: $*" >&2
	exit 1
}

ok() {
	if [ "$CHECK" = 1 ]; then echo "PASS  $*"; else echo "[step] $*"; fi
}

warn() {
	echo "WARN  $*"
}

# The only place a change happens. In --check it is reported as FAIL and nothing runs.
act() {
	local description=$1
	shift
	CHANGES=$((CHANGES + 1))
	if [ "$CHECK" = 1 ]; then
		FAILS=$((FAILS + 1))
		echo "FAIL  $description"
	else
		echo "[change] $description"
		"$@"
	fi
}

# sudo only for the one file outside the share; a test points STACKS_ETC at a folder it owns.
priv() {
	if [ -n "$STACKS_ETC" ]; then "$@"; else sudo "$@"; fi
}

valid_id() {
	local id=$1
	[ "${#id}" -ge 2 ] && [ "${#id}" -le 12 ] && [[ $id =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# The unique, sorted words of all arguments, on one line.
words() {
	printf '%s\n' "$@" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

read_var() {
	sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "${2:-$PATHS_NAS}" | head -n 1
}

want_dir() {
	local dir=$1
	if [ -d "$dir" ]; then
		ok "$dir"
	else
		act "make $dir" mkdir -p "$dir"
		[ "$CHECK" = 1 ] && return 0
	fi
	[ -d "$dir" ] || return 0
	if [ ! -w "$dir" ]; then
		FAILS=$((FAILS + 1))
		echo "FAIL  $dir is not writable by $(id -un)"
		return 0
	fi
	local group mode
	group=$(stat -c %G "$dir" 2>/dev/null || echo unknown)
	mode=$(stat -c %a "$dir" 2>/dev/null || echo 000)
	[ "$group" = "$NAS_GROUP" ] || warn "$dir has group $group, not $NAS_GROUP; a service account in $NAS_GROUP cannot rely on it"
	case "${mode: -2:1}" in 2 | 3 | 6 | 7) ;; *) warn "$dir has mode $mode: no group write" ;; esac
}

write_nas() {
	local tmp="$1.tmp.$$"
	printf '%s\n' "$2" > "$tmp"
	mv -f "$tmp" "$1"
}

sync_nas_file() {
	local path=$1 content=$2
	if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
		ok "$path is current"
	else
		act "write $path" write_nas "$path" "$content"
	fi
}

write_local() {
	local tmp
	tmp=$(mktemp)
	printf '%s\n' "$2" > "$tmp"
	priv install -D -m 0644 "$tmp" "$1"
	rm -f "$tmp"
}

sync_local_file() {
	local path=$1 content=$2
	if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
		ok "$path is current"
	else
		act "write $path" write_local "$path" "$content"
	fi
}

render_paths() {
	cat <<EOF
# Written by host/nas-layout.sh (version $SCRIPT_VERSION). The one record of where stack folders live on the NAS.
# A rebuilt VM runs host/nas-layout.sh and gets /etc/stacks/paths.env from this file. No secret belongs here.
# Every stack has $STACKS_ROOT/<stack>/backup, /config and /data, whether or not it uses them yet.
STACKS_NAS_SHARE=$NAS_SHARE
STACKS_ROOT=$STACKS_ROOT
STACKS_SHARED=$SHARED
STACKS_CERTS=$SHARED/certs
STACKS="$ALL_STACKS"
EOF
}

render_readme() {
	cat <<'EOF'
Shared, central files for the stacks. Written by host/nas-layout.sh in the stacks repository.

paths.env   the one record of where each stack's folders are; /etc/stacks/paths.env on each VM is a copy.
certs/      public certificate chains only.
<stack>/data  live files, or a README naming the volumes that live outside this structure.

Everything under cloud-backup is sent to the cloud. Never put a private key, an age key, a password or a
token here. Secrets live encrypted in git (SOPS) or in an env file on the one machine that uses them.
EOF
}

while [ $# -gt 0 ]; do
	case $1 in
		--check) CHECK=1 ;;
		-h | --help)
			sed -n '2,/^set -euo/{/^set -euo/!p}' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		-*) stop "unknown option $1 (try --help)" ;;
		*) REQUESTED="${REQUESTED:-} $1" ;;
	esac
	shift
done

[ "$(id -u)" -ne 0 ] || stop "run as your normal user, not root; it calls sudo itself where needed"

# The share must be a mounted network share, never the VM's own disk (REF-golden-image consequence 1).
ls "$NAS_SHARE" > /dev/null 2>&1 || true
[ -d "$NAS_SHARE" ] || stop "$NAS_SHARE is not there. Mount the NAS shares first: run mount-nas.sh (see docs/REF-golden-image.md). Nothing was changed."
if [ "$NAS_MOUNT_CHECK" = 1 ]; then
	fstype=$(findmnt -n -T "$NAS_SHARE" -o FSTYPE 2>/dev/null || true)
	case $fstype in
		cifs | smb3) ;;
		*) stop "$NAS_SHARE is not a mounted network share (found '${fstype:-none}'). Run mount-nas.sh (see docs/REF-golden-image.md). Nothing was changed." ;;
	esac
fi

# This VM's copy must agree with this run: two different roots on one VM is how a rebuild goes wrong.
if [ -f "$ETC_DIR/paths.env" ]; then
	local_root=$(read_var STACKS_ROOT "$ETC_DIR/paths.env")
	[ -z "$local_root" ] || [ "$local_root" = "$STACKS_ROOT" ] ||
		stop "$ETC_DIR/paths.env says STACKS_ROOT is $local_root, but this run says $STACKS_ROOT. Fix one; nothing was changed."
fi

EXISTING_STACKS=""
if [ -f "$PATHS_NAS" ]; then
	EXISTING_STACKS=$(read_var STACKS)
fi

# shellcheck disable=SC2086
if [ -n "${REQUESTED:-}" ]; then
	ALL_STACKS=$(words $EXISTING_STACKS $REQUESTED)
elif [ -n "$EXISTING_STACKS" ]; then
	ALL_STACKS=$(words $EXISTING_STACKS)
else
	ALL_STACKS=$(words $DEFAULT_STACKS)
fi

for id in $ALL_STACKS; do
	valid_id "$id" || stop "'$id' is not a stack ID (2 to 12 lowercase letters, digits or single hyphens). Nothing was changed."
done

want_dir "$STACKS_ROOT"
want_dir "$SHARED"
want_dir "$SHARED/certs"
for id in $ALL_STACKS; do
	want_dir "$STACKS_ROOT/$id"
	want_dir "$STACKS_ROOT/$id/backup"
	want_dir "$STACKS_ROOT/$id/config"
	want_dir "$STACKS_ROOT/$id/data"
done

PATHS_CONTENT=$(render_paths)
sync_nas_file "$PATHS_NAS" "$PATHS_CONTENT"
sync_nas_file "$SHARED/README.txt" "$(render_readme)"
sync_local_file "$ETC_DIR/paths.env" "$PATHS_CONTENT"

if [ "$CHECK" = 1 ]; then
	echo "would change: $CHANGES"
	[ "$FAILS" -eq 0 ] || exit 1
else
	echo "changes: $CHANGES"
fi
