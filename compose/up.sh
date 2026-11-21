#!/usr/bin/env bash
# Bring up the local monitor (ST58). Generates the Gatus config from the
# health files and the test probes (health-test/probe) first; a bad health file
# stops here and changes nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p compose/gatus
tmp="$(mktemp compose/gatus/config.yaml.XXXXXX)"
all="$(mktemp -d)"
trap 'rm -rf "$all"; rm -f "$tmp"' EXIT

cp health/*.toml health-test/probe/*.toml "$all"/
go run ./cmd/health generate "$all" > "$tmp"
rm -rf "$all"
mv "$tmp" compose/gatus/config.yaml
trap - EXIT

docker compose -f compose/docker-compose.yml up -d --wait
