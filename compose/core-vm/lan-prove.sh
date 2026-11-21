#!/usr/bin/env bash
# Prove a core node from a LAN client (ST215, CORE-FR-10 MVP 2). Run it from any LAN client:
#   lan-prove.sh <core-ip> [--closed <port>...]
# Prints one `ok` or `FAIL` line per check and exits 1 if any fails. A missing tool fails
# alone. The time check is skipped, not failed, when ntpdate is not installed.
# Checks: a name resolves through <core-ip>; example.com resolves; dnssec-failed.org is
# SERVFAIL; the time offset; each --closed port refuses a TCP connection.
set -u

usage() {
	echo "usage: lan-prove.sh <core-ip> [--closed <port>...]" >&2
	exit 2
}

[ $# -ge 1 ] || usage
case "$1" in -*) usage ;; esac
ip="$1"
shift
closed=(5300 5353 12300 22222)
while [ $# -gt 0 ]; do
	case "$1" in
	--closed) shift; closed=("$@"); break ;;
	*) usage ;;
	esac
done
host="${CORE_PROVE_HOST:-nas.core.andrusonline.com}"

fails=0
ok() { echo "ok $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

missing=()
for tool in dig nc; do
	command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
	bad "tools: missing ${missing[*]}"
	exit 1
fi

resolves() {
	local line got=""
	while IFS= read -r line; do
		[[ -z $line || $line == ';;'* ]] || got+="${got:+, }$line"
	done < <(dig +short +time=5 +tries=1 "@$ip" "$1" A 2>/dev/null)
	if [ -n "$got" ]; then
		ok "dns: $1 via $ip is $got"
	else
		bad "dns: $1 via $ip has no answer"
	fi
}
resolves "$host"
resolves example.com

out="$(dig +time=5 +tries=1 "@$ip" dnssec-failed.org A 2>&1)"
if [[ $out == *"status: SERVFAIL"* ]]; then
	ok "dnssec: dnssec-failed.org via $ip is SERVFAIL"
else
	bad "dnssec: dnssec-failed.org via $ip is not SERVFAIL"
fi

if ! command -v ntpdate >/dev/null 2>&1; then
	echo "skip time: no ntpdate on this client"
else
	out="$(ntpdate -q "$ip" 2>&1)"
	if [[ $out =~ offset[[:space:]]+(-?[0-9.]+) ]]; then
		ok "time: offset ${BASH_REMATCH[1]}s from $ip"
	else
		bad "time: ntpdate -q $ip gave no offset: ${out//$'\n'/ }"
	fi
fi

for port in "${closed[@]}"; do
	if nc -z -w 3 "$ip" "$port" >/dev/null 2>&1; then
		bad "closed: $ip:$port accepts a connection"
	else
		ok "closed: $ip:$port refuses"
	fi
done

[ "$fails" -eq 0 ] || exit 1
