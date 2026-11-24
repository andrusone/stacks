#!/usr/bin/env bash
# SI-FR-01 MVP 1 (ST280): the stacks installer. Run from the stacks clone: ./setup-stacks.sh [flags]
# It finds Go (the one on the PATH, or mise's Go for this folder's mise.toml), then runs cmd/setup-stacks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

GO=()
if command -v go >/dev/null 2>&1; then
  GO=(go)
elif command -v mise >/dev/null 2>&1 && (cd "$ROOT" && mise where go >/dev/null 2>&1); then
  GO=(mise x go -- go)
fi

missing=()
[ "${#GO[@]}" -gt 0 ] || missing+=("Go")
command -v git >/dev/null 2>&1 || missing+=("git")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "error: missing ${missing[*]}. Run ./setup.sh --profile server from your machine clone, then run this again." >&2
  exit 1
fi

cd "$ROOT"
exec "${GO[@]}" run ./cmd/setup-stacks "$@"
