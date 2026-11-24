#!/usr/bin/env bash
# SI-FR-11 MVP 1 (ST282): tests/make-stacks.sh writes alpha beta gamma into a temp folder, and refuses what it must.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GEN="$HERE/make-stacks.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -Fxq -- "$2" "$1" || fail "$1 lacks line: $2"; }

bash "$GEN" "$T/out" alpha beta gamma || fail "generator exited non-zero"
for n in alpha beta gamma; do
  d="$T/out/$n"
  [ -d "$d" ] || fail "no folder $d"
  has "$d/stack.toml" "name = \"$n\""
  has "$d/stack.toml" "meaning = \"test stack $n\""
  has "$d/stack.toml" 'version = "1.0.0"'
  has "$d/stack.toml" "user = \"stk-$n\""
  has "$d/stack.toml" "units = [\"stk-$n.service\"]"
  has "$d/stack.toml" 'nas_paths = []'
  has "$d/stack.toml" 'env = ["EXAMPLE_KEY"]'
  has "$d/example.env" 'EXAMPLE_KEY=changeme'
  [ -x "$d/install" ] && [ -x "$d/check" ] || fail "steps not executable in $d"
done
has "$T/out/alpha/stack.toml" 'ports = [18000]'
has "$T/out/beta/stack.toml" 'ports = [18001]'
has "$T/out/gamma/stack.toml" 'ports = [18002]'

[ "$("$T/out/alpha/install" plan)" = "$(printf 'would: install alpha\nchanges: 1')" ] || fail "install plan output"
[ "$("$T/out/alpha/install" apply)" = "$(printf 'done: install alpha\nchanges: 1')" ] || fail "install apply output"
if "$T/out/alpha/install" bogus >/dev/null 2>&1; then fail "install accepted bogus"; fi
if "$T/out/alpha/install" >/dev/null 2>&1; then fail "install accepted no argument"; fi
[ "$("$T/out/gamma/check")" = ok ] || fail "check output"

# Refusals: one stderr line, exit 1, and nothing written for the good names.
err="$T/err"
if bash "$GEN" "$T/bad" good Bad 2>"$err"; then fail "accepted uppercase name"; fi
[ "$(wc -l <"$err")" -eq 1 ] || fail "uppercase refusal is not one line"
[ ! -e "$T/bad" ] || fail "refusal wrote a folder"
if bash "$GEN" "$T/out" alpha 2>"$err"; then fail "accepted a name already in dest"; fi
[ "$(wc -l <"$err")" -eq 1 ] || fail "existing-name refusal is not one line"
has "$T/out/alpha/stack.toml" 'ports = [18000]'

# The script and templates hold no names of their own.
for f in "$GEN" "$HERE"/template/*; do
  if grep -Eq 'alpha|beta|gamma' "$f"; then fail "$f holds a generated name"; fi
done
echo "ok: make-stacks.test"
