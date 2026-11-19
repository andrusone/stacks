#!/usr/bin/env bash
# Remove what core-up made (ST174): containers, networks and volumes of every
# compose/core/*/docker-compose.yml.
set -euo pipefail

cd "$(dirname "$0")/../.."

shopt -s nullglob
for f in compose/core/*/docker-compose.yml; do
  docker compose -f "$f" down -v
done
