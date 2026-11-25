#!/usr/bin/env bash
# SI-FR-11 MVP 1 (ST294): no stack name is in the installer, and stacks come and go with the folder.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
T="$(mktemp -d)"
W="$(mktemp -d)"
trap 'rm -rf "$T" "$W"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
listing() { find "$T" -mindepth 1 | sed "s|^$T||" | sort; }
# Between two listings, only lines under /stacks/<name> may differ.
only_stack() {
  local extra
  extra="$(diff "$1" "$2" | grep '^[<>]' | grep -v "^[<>] /stacks/$3\(/\|$\)" || true)"
  [ -z "$extra" ] || fail "folder changed outside stacks/$3: $extra"
}
run_help() { STACKS_DIR="$2" "$BIN" --help > "$W/$1" || fail "--help exited non-zero for $2"; }

bash "$HERE/make-stacks.sh" "$T/stacks" alpha beta gamma || fail "generator exited non-zero"

# (1) No generated name in setup-stacks.sh or a non-test Go file of the installer.
src=("$ROOT/setup-stacks.sh")
while IFS= read -r f; do src+=("$f"); done < <(find "$ROOT/cmd/setup-stacks" "$ROOT/internal" -name '*.go' ! -name '*_test.go')
for n in alpha beta gamma; do
  hits="$(grep -Fl -- "$n" "${src[@]}" || true)"
  [ -z "$hits" ] || fail "$n appears in: $hits"
done

# (2) One binary, run against each state of the stacks folder.
BIN="$T/bin/setup-stacks"
(cd "$ROOT" && go build -o "$BIN" ./cmd/setup-stacks) || fail "build failed"
mkdir "$T/empty"
run_help empty "$T/empty"
grep -Fq "no stacks yet: a stack is a folder with a stack.toml in $T/empty" "$W/empty" || fail "empty folder lacks the no-stacks line"

run_help three "$T/stacks"
for n in alpha beta gamma; do grep -Fxq "  $n  test stack $n" "$W/three" || fail "help lacks $n"; done
listing > "$W/l1"

rm -r "$T/stacks/beta"
listing > "$W/l2"
only_stack "$W/l1" "$W/l2" beta
run_help without "$T/stacks"
changed="$(diff "$W/three" "$W/without" | grep '^[<>]' || true)"
[ "$changed" = "< $(grep -F '  beta  ' "$W/three")" ] || fail "help changed by more than the beta line: $changed"

bash "$HERE/make-stacks.sh" "$T/stacks" delta || fail "generator exited non-zero for delta"
listing > "$W/l3"
only_stack "$W/l2" "$W/l3" delta
run_help added "$T/stacks"
grep -Fxq "  delta  test stack delta" "$W/added" || fail "help lacks delta after it was added"
echo "ok: no-stack-names.test"
