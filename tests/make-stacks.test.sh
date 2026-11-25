#!/usr/bin/env bash
# SI-FR-11 MVP 1 (ST282): tests/make-stacks.sh writes alpha beta gamma into a temp folder, and refuses what it must.
# ST295: the install step writes and enables its unit, and a rerun changes nothing (SI-FR-07, SI-FR-08), with sudo and systemctl stubbed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GEN="$HERE/make-stacks.sh"
T="$(mktemp -d)"
S="$(mktemp -d)"
trap 'rm -rf "$T" "$S"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -Fxq -- "$2" "$1" || fail "$1 lacks line: $2"; }

# Stubs: sudo runs its command; systemctl logs its arguments, and an enabled unit is a file in $STK_STATE.
mkdir -p "$S/bin" "$S/state" "$S/units"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'echo "sudo $*" >> "$STK_LOG"' 'exec "$@"' > "$S/bin/sudo"
cat > "$S/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STK_LOG"
if [ "$1" = is-enabled ]; then [ -e "$STK_STATE/${!#}" ]; exit; fi
[ "$1" = enable ] && touch "$STK_STATE/${!#}"
exit 0
EOF
chmod +x "$S/bin/sudo" "$S/bin/systemctl"; export PATH="$S/bin:$PATH" STK_LOG="$S/log" STK_STATE="$S/state" STK_UNIT_DIR="$S/units"

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

# Install: a fresh stack writes and enables its unit; a rerun changes nothing and calls nothing.
I="$T/out/alpha/install"; U="$S/units/stk-alpha.service"; L="$S/log"
[ "$("$I" plan)" = "$(printf 'would: write unit %s\nwould: enable stk-alpha.service\nchanges: 2' "$U")" ] || fail "install plan on a fresh stack"
[ "$("$I" apply)" = "$(printf 'done: write unit %s\ndone: enable stk-alpha.service\nchanges: 2' "$U")" ] || fail "install apply on a fresh stack"
for line in 'Type=oneshot' 'RemainAfterExit=yes' 'ExecStart=/bin/true'; do has "$U" "$line"; done
has "$L" "sudo tee $U"
has "$L" 'sudo systemctl daemon-reload'
has "$L" 'sudo systemctl enable --now stk-alpha.service'
: > "$L"
[ "$("$I" plan)" = 'changes: 0' ] || fail "install plan after apply"
[ "$("$I" apply)" = 'changes: 0' ] || fail "install apply on a rerun"
! grep -q '^sudo ' "$L" || fail "a rerun called sudo"
# The unit present but not enabled: only the enable is listed and run.
: > "$L"; rm "$S/state/stk-alpha.service"
[ "$("$I" plan)" = "$(printf 'would: enable stk-alpha.service\nchanges: 1')" ] || fail "install plan with the unit not enabled"
[ "$("$I" apply)" = "$(printf 'done: enable stk-alpha.service\nchanges: 1')" ] || fail "install apply with the unit not enabled"
has "$L" 'sudo systemctl enable --now stk-alpha.service'
if "$I" bogus >/dev/null 2>&1; then fail "install accepted bogus"; fi
if "$I" >/dev/null 2>&1; then fail "install accepted no argument"; fi
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
