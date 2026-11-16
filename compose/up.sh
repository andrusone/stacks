#!/usr/bin/env bash
# Bring up the local monitor (ST58). Generates the Gatus config from the
# health files first; a bad health file stops here and changes nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p compose/gatus
tmp="$(mktemp compose/gatus/config.yaml.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

go run ./cmd/health generate health > "$tmp"
mv "$tmp" compose/gatus/config.yaml
trap - EXIT

docker compose -f compose/docker-compose.yml up -d --wait
