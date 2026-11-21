#!/usr/bin/env bash
# Bring up the core stack (ST174, CORE-FR-01). For each
# compose/core/*/docker-compose.yml in name order: the folder's check.sh first
# if it has one, then docker compose up -d --wait. A failing check stops here
# with its message; folders before it stay up.
set -euo pipefail

cd "$(dirname "$0")/../.."

shopt -s nullglob
files=(compose/core/*/docker-compose.yml)
if [ ${#files[@]} -eq 0 ]; then
  echo "core-up: no compose/core/*/docker-compose.yml found" >&2
  exit 1
fi

for f in "${files[@]}"; do
  dir="$(dirname "$f")"
  if [ -f "$dir/check.sh" ]; then
    bash "$dir/check.sh"
  fi
  if [ -f "$dir/zone.sh" ]; then
    bash "$dir/zone.sh"
  fi
  docker compose -f "$f" up -d --wait
done
