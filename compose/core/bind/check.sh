#!/usr/bin/env bash
# Zone gate for core-up (ST174, CORE-FR-01): run named-checkzone on the zone
# file in a throwaway container. A bad zone prints the checker's message and
# exits 1, so core-up stops before docker compose up.
set -euo pipefail

cd "$(dirname "$0")"

zone=db.fixture.zone
image=internetsystemsconsortium/bind9:9.18

if ! out="$(docker run --rm --entrypoint named-checkzone \
  -v "$PWD/zone:/zone:ro" "$image" core.example "/zone/$zone" 2>&1)"; then
  echo "$out" >&2
  echo "core-up: zone check failed: compose/core/bind/zone/$zone" >&2
  exit 1
fi
echo "$out"
