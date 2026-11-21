#!/usr/bin/env bash
# The BIND primary and secondary test (ST213, CORE-FR-08 MVP 2): a primary and a secondary, two BIND
# containers on a throwaway Docker network with fixed addresses, and a third container that asks.
# Checks: the secondary answers the fixture host after the transfer; an AXFR from the third container
# is refused by the primary and by the secondary. It starts and removes only what it made; no host port.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
bind_dir="$here/../../core/bind"
image=internetsystemsconsortium/bind9:9.18
tag="zt$$"
net="$tag-net"
tmp="$(mktemp -d)"

cleanup() {
	docker rm -f "$tag-pri" "$tag-sec" >/dev/null 2>&1 || true
	docker network rm "$net" >/dev/null 2>&1 || true
	rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

pri_ip=172.31.213.10
sec_ip=172.31.213.11
third_ip=172.31.213.12

docker network create --subnet 172.31.213.0/24 "$net" >/dev/null
CORE_ROLE=primary CORE_PEER="$sec_ip" CORE_NAMED_OUT="$tmp/primary.conf" bash "$bind_dir/zone.sh" >/dev/null
CORE_ROLE=secondary CORE_PEER="$pri_ip" CORE_NAMED_OUT="$tmp/secondary.conf" bash "$bind_dir/zone.sh" >/dev/null

docker run -d --name "$tag-pri" --network "$net" --ip "$pri_ip" \
	-v "$tmp/primary.conf:/etc/bind/named.conf:ro" \
	-v "$bind_dir/zone:/etc/bind/zone:ro" "$image" >/dev/null
docker run -d --name "$tag-sec" --network "$net" --ip "$sec_ip" \
	-v "$tmp/secondary.conf:/etc/bind/named.conf:ro" "$image" >/dev/null

# The third container: dig from an address that is neither the primary nor the secondary.
ask() {
	docker run --rm --network "$net" --ip "$third_ip" --entrypoint dig "$image" "$@"
}

# The secondary has the zone once the transfer lands; a bounded wait for it.
got=""
for _ in $(seq 1 30); do
	got="$(ask +short +time=2 +tries=1 "@$sec_ip" nas.core.example A 2>/dev/null || true)"
	if [ "$got" = "192.0.2.20" ]; then break; fi
	sleep 1
done
[ "$got" = "192.0.2.20" ] || fail "secondary did not answer nas.core.example after the transfer (got '${got:-nothing}')"

# dig prints only "Transfer failed." for a refused AXFR, so the refusal is checked in the server's log:
# BIND logs each denied transfer. The answer must carry no zone data either.
for name_server in "$tag-pri" "$tag-sec"; do
	ip="$pri_ip"
	[ "$name_server" = "$tag-sec" ] && ip="$sec_ip"
	out="$(ask "@$ip" core.example AXFR 2>&1 || true)"
	if grep -q SOA <<< "$out"; then fail "AXFR from $third_ip to $ip returned zone data"; fi
	grep -q "zone transfer 'core.example/AXFR/IN' denied" <(docker logs "$name_server" 2>&1) ||
		fail "AXFR from $third_ip to $ip was not refused (no denial in $name_server's log): $out"
done

echo "bind-secondary test: ok (secondary answers after transfer; AXFR refused from $third_ip)"
