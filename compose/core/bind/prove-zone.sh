#!/usr/bin/env bash
# Prove the core zone (ST174, CORE-FR-01 MVP 1): a fixture host answers with
# its address from the running BIND container. Needs core-up.
set -euo pipefail

port="${CORE_BIND_PORT:-5300}"
host=nas.core.example
want=192.0.2.20

got="$(dig +short +time=3 +tries=1 @127.0.0.1 -p "$port" "$host" A)"
if [ "$got" != "$want" ]; then
  echo "FAIL zone: $host A via 127.0.0.1:$port is '${got:-no answer}', want $want" >&2
  exit 1
fi
echo "ok zone"
