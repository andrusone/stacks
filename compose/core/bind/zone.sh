#!/usr/bin/env bash
# Writes BIND's named.conf for this role (CORE-FR-08, ST213): the template named.conf with the zone's
# name and the role's lines, into named.generated.conf (git-ignored; the compose file mounts it).
# Run it before the stack comes up. Values come from the environment, all optional:
#   CORE_ROLE       primary (default) or secondary
#   CORE_PEER       the other BIND's IPv4 address. A primary allows transfers to it only and notifies it;
#                   a secondary pulls the zone from it. Required for a secondary; empty for a primary
#                   means it allows no transfers.
#   CORE_ZONE_NAME  the zone's name (default core.example)
#   CORE_ZONE_FILE  the zone file in compose/core/bind/zone (default db.fixture.zone)
#   CORE_BIND_PORT  the port BIND answers on at its address (default 5300); the peer's transfers use it
#   CORE_NAMED_OUT  where to write (default compose/core/bind/named.generated.conf)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
role="${CORE_ROLE:-primary}"
peer="${CORE_PEER:-}"
name="${CORE_ZONE_NAME:-core.example}"
file="${CORE_ZONE_FILE:-db.fixture.zone}"
port="${CORE_BIND_PORT:-5300}"
out="${CORE_NAMED_OUT:-$here/named.generated.conf}"

fail() {
	echo "zone.sh: $*" >&2
	exit 1
}

[[ $name =~ ^[A-Za-z0-9.-]+$ ]] || fail "CORE_ZONE_NAME is a zone name: letters, digits, dots and hyphens"
[[ $file =~ ^[A-Za-z0-9._-]+$ ]] || fail "CORE_ZONE_FILE is a file name: letters, digits, dots, hyphens, underscores"
[[ $port =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail "CORE_BIND_PORT is a port number: $port"
if [ -n "$peer" ] && ! [[ $peer =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
	fail "CORE_PEER is an IPv4 address: $peer"
fi

case "$role" in
	primary)
		if [ -n "$peer" ]; then
			xfer="{ $peer; }"
		else
			xfer="{ none; }"
		fi
		lines="$(printf '\ttype primary;\n\tfile "/etc/bind/zone/%s";\n\tallow-transfer %s;' "$file" "$xfer")"
		if [ -n "$peer" ]; then
			lines+="$(printf '\n\talso-notify { %s port %s; };' "$peer" "$port")"
		fi
		;;
	secondary)
		[ -n "$peer" ] || fail "CORE_PEER must name the primary's address for a secondary"
		lines="$(printf '\ttype secondary;\n\tprimaries { %s port %s; };\n\tfile "/var/cache/bind/%s";\n\tallow-transfer { none; };' \
			"$peer" "$port" "$file")"
		;;
	*) fail "CORE_ROLE is primary or secondary: $role" ;;
esac

text="$(cat "$here/named.conf")"
text="${text//@ZONE_NAME@/$name}"
text="${text//@ROLE_LINES@/$lines}"
printf '%s\n' "$text" > "$out"
echo "zone.sh: wrote $out for $role"
