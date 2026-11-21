#!/usr/bin/env bash
# The monitor's state backup (HL-FR-14, MVP 3, ST250). Copies $MONITOR_DIR/ntfy, the alert cache, into
# $MONITOR_BACKUP as monitor-<UTC yyyymmddThhmmssZ>.tar.gz, written under a temporary name and renamed
# when complete. Only the 7 newest monitor-* archives are kept. The archive holds the ntfy folder alone,
# so compose/monitor/.env and the topic never reach the NAS (HL-NFR-02). Values come from the environment,
# else from compose/monitor/.env. It never creates the NAS layout: host/nas-layout.sh does.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# A value from the environment, else from compose/monitor/.env, else the default given here.
value() {
	local v="${!1-}"
	[ -n "$v" ] || v="$(sed -n "s/^$1=//p" "$here/.env" 2>/dev/null | tail -n1)"
	printf '%s' "${v:-$2}"
}
mon="$(realpath -m "$(value MONITOR_DIR /srv/monitor)")"
backup="$(realpath -m "$(value MONITOR_BACKUP /nas/cloud-backup/services/monitor/backup)")"
keep=7

if [ ! -d "$backup" ]; then
	echo "monitor-backup: backup folder $backup is missing; host/nas-layout.sh makes it" >&2
	exit 1
fi
case "$backup/" in
"$mon/"*)
	echo "monitor-backup: MONITOR_BACKUP must be outside the state folder $mon" >&2
	exit 1
	;;
esac
[ -d "$mon/ntfy" ] || { echo "monitor-backup: no ntfy folder in $mon" >&2; exit 1; }

name="monitor-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
part="$backup/.$name.part"
trap 'rm -f -- "$part"' EXIT
tar -C "$mon" -czf "$part" ntfy
mv -- "$part" "$backup/$name"
trap - EXIT

shopt -s nullglob
copies=("$backup"/monitor-*.tar.gz)
mapfile -t sorted < <(printf '%s\n' "${copies[@]}" | sort -r)
if [ "${#sorted[@]}" -gt "$keep" ]; then
	for old in "${sorted[@]:$keep}"; do
		rm -f -- "$old"
	done
fi

echo "monitor-backup: wrote $backup/$name"
