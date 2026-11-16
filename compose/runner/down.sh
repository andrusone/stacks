#!/usr/bin/env bash
# Remove the local runner container and everything compose made for it (ST68). Keeps the data folder.
set -euo pipefail

cd "$(dirname "$0")"

docker compose -f docker-compose.yml down
