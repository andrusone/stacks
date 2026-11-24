#!/usr/bin/env bash
# SI-FR-11 MVP 1 (ST282): write test stacks from tests/template. Usage: tests/make-stacks.sh <dest> <name> [<name>...]
# Each name gets a folder in <dest>; @NAME@ and @PORT@ (18000 up, in the order given) are the only things replaced.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TPL="$HERE/template"

die() { echo "error: $*" >&2; exit 1; }
fill() { sed -e "s/@NAME@/$NAME/g" -e "s/@PORT@/$PORT/g" "$TPL/$1" > "$2"; }

[ $# -ge 2 ] || die "usage: tests/make-stacks.sh <dest> <name> [<name>...]"
dest="$1"
shift

# Refuse everything before anything is written.
seen=" "
for name in "$@"; do
  [[ "$name" =~ ^[a-z0-9]+$ ]] || die "name '$name' must be lowercase letters and digits"
  [[ "$seen" != *" $name "* ]] || die "name '$name' is given twice"
  seen="$seen$name "
  [ ! -e "$dest/$name" ] || die "$dest/$name already exists; pick a new name or remove it"
done

mkdir -p "$dest"
i=0
for name in "$@"; do
  NAME="$name"
  PORT=$((18000 + i))
  d="$dest/$name"
  mkdir "$d"
  fill stack.toml.tmpl "$d/stack.toml"
  fill example.env.tmpl "$d/example.env"
  fill install.tmpl "$d/install"
  fill check.tmpl "$d/check"
  chmod +x "$d/install" "$d/check"
  i=$((i + 1))
done
