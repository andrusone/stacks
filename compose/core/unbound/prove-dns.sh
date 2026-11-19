#!/usr/bin/env bash
# Prove the core resolver (ST178, CORE-FR-02 MVP 1): through Unbound's port,
# the fixture host resolves, example.com resolves, and dnssec-failed.org is
# SERVFAIL. Prints one `ok <what>` line each. Needs core-up. The last two
# need internet. example.com retries for up to 10 s, and dnssec-failed.org
# gets 3 tries 2 s apart, so a cold first query is not a failure (ST181).
set -euo pipefail

port="${CORE_DNS_PORT:-5353}"
dig_() { dig +time=10 +tries=1 @127.0.0.1 -p "$port" "$@"; }

host=nas.core.example
want=192.0.2.20
got="$(dig_ +short "$host" A 2>/dev/null | grep -v '^;;' || true)"
if [ "$got" != "$want" ]; then
  dig_ "$host" A >&2 || true
  echo "FAIL resolver: $host via 127.0.0.1:$port is '${got:-no answer}', want $want" >&2
  exit 1
fi
echo "ok resolver: $host is $want"

end=$((SECONDS + 10))
while :; do
  got="$(dig_ +short example.com A 2>/dev/null | grep -v '^;;' || true)"
  if [ -n "$got" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$end" ]; then
    dig_ example.com A >&2 || true
    echo "FAIL resolver: example.com via 127.0.0.1:$port has no answer after 10 s" >&2
    exit 1
  fi
  sleep 1
done
echo "ok resolver: example.com resolves"

ok=
for try in 1 2 3; do
  out="$(dig_ dnssec-failed.org A 2>&1)" || true
  if grep -q 'status: SERVFAIL' <<<"$out"; then
    ok=1
    break
  fi
  if [ "$try" -lt 3 ]; then
    sleep 2
  fi
done
if [ -z "$ok" ]; then
  echo "$out" >&2
  echo "FAIL resolver: dnssec-failed.org via 127.0.0.1:$port is not SERVFAIL after 3 tries" >&2
  exit 1
fi
echo "ok resolver: dnssec-failed.org is SERVFAIL"
