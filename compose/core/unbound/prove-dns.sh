#!/usr/bin/env bash
# Prove the core resolver (ST178, CORE-FR-02 MVP 1): through Unbound's port,
# the fixture host resolves, example.com resolves, and dnssec-failed.org is
# SERVFAIL. Prints one `ok <what>` line each. Needs core-up. The last two
# need internet.
set -euo pipefail

port="${CORE_DNS_PORT:-5353}"
dig_() { dig +time=10 +tries=1 @127.0.0.1 -p "$port" "$@"; }

host=nas.core.example
want=192.0.2.20
got="$(dig_ +short "$host" A)"
if [ "$got" != "$want" ]; then
  dig_ "$host" A >&2
  echo "FAIL resolver: $host via 127.0.0.1:$port is '${got:-no answer}', want $want" >&2
  exit 1
fi
echo "ok resolver: $host is $want"

got="$(dig_ +short example.com A)"
if [ -z "$got" ]; then
  dig_ example.com A >&2
  echo "FAIL resolver: example.com via 127.0.0.1:$port has no answer" >&2
  exit 1
fi
echo "ok resolver: example.com resolves"

out="$(dig_ dnssec-failed.org A)"
if ! grep -q 'status: SERVFAIL' <<<"$out"; then
  echo "$out" >&2
  echo "FAIL resolver: dnssec-failed.org via 127.0.0.1:$port is not SERVFAIL" >&2
  exit 1
fi
echo "ok resolver: dnssec-failed.org is SERVFAIL"
