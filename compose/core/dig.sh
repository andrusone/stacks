#!/usr/bin/env bash
# dig inside a throwaway container of the BIND image (ST211, CORE-FR-09 MVP 2),
# so the host needs no dig package. Arguments pass through unchanged; stdout
# and the exit code are dig's.
set -euo pipefail

exec docker run --rm --network host --entrypoint dig internetsystemsconsortium/bind9:9.18 "$@"
