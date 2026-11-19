#!/usr/bin/env bash
# Prove the core time service (ST176, CORE-FR-03 MVP 1): a throwaway client asks
# the chrony container for the time and prints the offset it measured.
# Starts the container if it is not running.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose="$dir/docker-compose.yml"
port="${CORE_NTP_PORT:-12300}"

if [ -z "$(docker compose -f "$compose" ps -q --status running)" ]; then
  docker compose -f "$compose" up -d --wait
fi

image="$(docker compose -f "$compose" config --images | head -n 1)"
if ! out="$(docker run --rm --network host --entrypoint chronyd "$image" \
      -f /dev/null -Q "server 127.0.0.1 port $port iburst" 2>&1)"; then
  printf '%s\n' "$out" >&2
  echo "FAIL time: chronyd -Q against 127.0.0.1:$port failed" >&2
  exit 1
fi

offset="$(sed -n 's/.*System clock wrong by \(-\{0,1\}[0-9.]*\) seconds.*/\1/p' <<<"$out" | head -n 1)"
if [ -z "$offset" ]; then
  printf '%s\n' "$out" >&2
  echo "FAIL time: no offset in the client output" >&2
  exit 1
fi
echo "ok time offset=${offset}s"
