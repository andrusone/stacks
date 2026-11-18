#!/usr/bin/env bash
# Smoke test for a Docker host (SK-FR-09, ST117): bring one throwaway container up to
# healthy, read its state with docker compose ps, and always remove it with down -v.
# Prints "smoke: healthy" and exits 0, or "smoke: not healthy" with the container's
# state and exits 1. Uses sudo only while the user is not yet in the docker group.
set -u

cd "$(dirname "$0")" || exit 1

dc=(docker)
if ! id -nG | tr ' ' '\n' | grep -qx docker; then
  dc=(sudo docker)
fi
compose=("${dc[@]}" compose -f smoke-compose.yml)

# Progress and errors from compose go to stderr; the verdict lines go to stdout.
"${compose[@]}" up -d --wait >&2 || true

state=$("${compose[@]}" ps -a --format '{{.State}} {{.Health}}' smoke 2>&1)
verdict=1
if [ "$state" = "running healthy" ]; then
  echo "smoke: healthy"
  verdict=0
else
  echo "smoke: not healthy"
  echo "smoke: state: ${state:-no container}"
fi

if ! "${compose[@]}" down -v >&2; then
  echo "smoke: down -v failed; check docker ps -a" >&2
  verdict=1
fi
exit "$verdict"
