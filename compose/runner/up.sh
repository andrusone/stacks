#!/usr/bin/env bash
# Start the local Forgejo Actions runner (ST68, FG-FR-04 MVP 1) as its own container.
# It needs the forge up. On the first run it gets a registration token from the forge
# (never printed; passed only to the register step), registers once, then starts.
# A rerun on existing state registers nothing and says so. The data folder is
# RUNNER_DATA if set, else data/ beside this script.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="$(realpath -m "${RUNNER_DATA:-$here/data}")"
export RUNNER_DATA="$data"
RUNNER_UID="$(id -u)"
RUNNER_GID="$(id -g)"
DOCKER_GID="$(stat -c %g /var/run/docker.sock)"
export RUNNER_UID RUNNER_GID DOCKER_GID
instance=http://forge:3000

cd "$here"
compose=(docker compose -f docker-compose.yml)

if [ "$(docker inspect -f '{{.State.Running}}' forge 2>/dev/null || true)" != "true" ]; then
  echo "runner: the forge is not running; run mise run forge-up first" >&2
  exit 1
fi

mkdir -p "$data"
if [ -f "$data/.runner" ]; then
  echo "runner: already registered, nothing to register"
else
  token="$(docker exec --user git forge forgejo forgejo-cli actions generate-runner-token)"
  "${compose[@]}" run --rm --no-deps -T --entrypoint forgejo-runner runner \
    --config /etc/forgejo-runner/config.yml \
    register --no-interactive --instance "$instance" --token "$token" --name st68-runner
  unset token
  echo "runner: registered with the forge at $instance"
fi

"${compose[@]}" up -d
echo "runner: started; data in $data"
