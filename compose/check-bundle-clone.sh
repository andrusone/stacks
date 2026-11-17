#!/usr/bin/env bash
# Guard for FG-FR-15 (ST115): a line that clones the bundle must name the branch with
# -b main, because a bundle of main has no HEAD. Searches docs/*.md, the scripts under
# compose/ and the repo root's *.sh. Prints file:line for each bad line and exits 1;
# exits 0 when every line names the branch.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
bad=0
files=$(find "$root/docs" -maxdepth 1 -name '*.md'; find "$root/compose" -name '*.sh'; find "$root" -maxdepth 1 -name '*.sh')
while IFS= read -r file; do
  [ -n "$file" ] || continue
  while IFS= read -r hit; do
    printf '%s:%s\n' "${file#"$root"/}" "$hit"
    bad=1
  done < <(grep -nE 'git clone.*stacks\.bundle' "$file" | grep -v -- '-b main' | cut -d: -f1)
done <<< "$files"
if [ "$bad" -ne 0 ]; then
  echo "check-bundle-clone: clone of stacks.bundle without -b main (see lines above)" >&2
  exit 1
fi
echo "check-bundle-clone: ok"
