#!/usr/bin/env bash
# The monitor's state backup (HL-FR-14, MVP 3, ST250, ST259). Copies what is not a secret under $MONITOR_DIR,
# Gatus's history (gatus/history) and the Beszel hub's data (beszel, minus its private key id_ed25519, ST260), into $MONITOR_BACKUP as
# monitor-<UTC yyyymmddThhmmssZ>.tar.gz, written under a temporary name and renamed when complete. Only the 7
# newest monitor-* archives are kept. The ntfy folder is never archived: its cache.db may hold the topic, a
# secret (HL-NFR-02), and the topic is given again on a rebuild. Values come from the environment, else from
# compose/monitor/.env. It never creates the NAS layout: host/nas-layout.sh does.
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

members=()
[ -d "$mon/gatus/history" ] && members+=(gatus/history)
[ -d "$mon/beszel" ] && members+=(beszel)

name="monitor-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
part="$backup/.$name.part"
trap 'rm -f -- "$part"' EXIT
if [ "${#members[@]}" -gt 0 ]; then
	tar -C "$mon" -czf "$part" --exclude='.env' --exclude='cache.db' --exclude='*ntfy*' --exclude='id_ed25519*' "${members[@]}"
else
	echo "monitor-backup: nothing to back up in $mon" >&2
	tar -czf "$part" -T /dev/null
fi
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
