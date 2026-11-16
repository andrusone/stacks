#!/usr/bin/env bash
# Remove everything the local monitor made (ST58): containers, network, volumes.
set -euo pipefail

cd "$(dirname "$0")/.."

docker compose -f compose/docker-compose.yml down -v
