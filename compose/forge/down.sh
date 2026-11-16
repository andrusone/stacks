#!/usr/bin/env bash
# Remove the local Forgejo container and its network (ST66). Keeps the data folder.
set -euo pipefail

cd "$(dirname "$0")"

docker compose -f docker-compose.yml down
