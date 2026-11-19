#!/usr/bin/env bash
# Run every core proof (ST174): compose/core/prove-*.sh and
# compose/core/*/prove-*.sh that exist, in that order. Each prints its own
# `ok <what>` line. Stops at the first failure and exits non-zero.
set -euo pipefail

cd "$(dirname "$0")/../.."

shopt -s nullglob
proofs=(compose/core/prove-*.sh compose/core/*/prove-*.sh)
if [ ${#proofs[@]} -eq 0 ]; then
  echo "core-prove: no proofs found" >&2
  exit 1
fi

for p in "${proofs[@]}"; do
  bash "$p"
done
