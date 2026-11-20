#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# fleet-check.sh — run every script's check mode on every Linux VM and log the results HERE
#
# Reads the DNS zone file for the Linux VMs (the same list git-access.ps1 uses for VM access:
# A records named v<env><intent>x<n>; physical, network and Windows machines are ignored), then for
# each one over ssh:
#   1. sends a copy of this checkout's stacks/ to a temp directory on the VM,
#   2. runs fleet-check-remote.sh there: the doctors, the golden-image validate stage and, on a core
#      node, build-core-node.sh --check and --only verify --check,
#   3. removes the temp directory,
# and appends the drift records that came back to the LOCAL drift log. Results are measured against
# THIS checkout, so run it from a clean, current one (`git pull`).
#
# DETECTS ONLY unless you pass --apply: each script runs in its read-only check mode, the host key
# must already be in known_hosts (it never trusts a new one), and the only thing written on a VM is
# the temp directory. A VM that cannot be reached is itself recorded as a failure.
#
# --apply safe|all makes it fix what it found (see FIXES.md next to this script for every fix and why
# it is classed as it is). Each VM works out its own fixes. A fix is "safe" (less than a 50% chance of
# breaking the service the VM is for), "unsafe" (more than 50%) or "manual" (needs you; never applied):
#   --apply safe   apply the safe fixes, in order, then run every check again
#   --apply all    apply the safe and the unsafe fixes, then run every check again
# The fix summary then says, per machine, what was applied, whether the recheck passed and what still
# needs doing. Nothing is applied to a VM unless you pass --apply; it never reboots a VM.
#
# Usage:  fleet-check.sh [--only a,b] [--skip a,b] [--list] [--git-role ROLE] [--user NAME]
#                        [--domain D] [--zone FILE] [--key FILE] [--log FILE] [--ask-sudo]
#                        [--apply safe|all] [--push-agent --binary PATH]
#   --push-agent      explicitly install/update Vitals and committed stacks; token must exist
#   --binary PATH     pinned Linux AMD64 binary on this controller (or VITALS_BINARY)
#                     The designated speed-test host requires the manual paired-engine install.
#   --only / --skip   comma lists of VM short names (vpnx1,vdcx2,...)
#   --list            print the VMs found in the zone file and stop
#   --git-role ROLE   personal|prod|ai: also run git-access.sh --check on each VM with this role
#   --user NAME       ssh user (default dave)
#   --domain D        default core.andrusonline.com
#   --zone FILE       default stacks/core/dns/bind/db.core.andrusonline.com in this checkout
#   --key FILE        ssh identity (default: ~/.ssh/id_ed25519_github, the key git-access makes)
#   --log FILE        where results go (default: DRIFT_LOG, else ~/.local/state/drift-log/drift.jsonl)
#   --ask-sudo        for VMs where the ssh user has no passwordless sudo: ask for the sudo password
#                     once (hidden; or the first line of stdin when it is not a terminal) and use it
#                     for the checks that read root-only state. See "The sudo password" below.
#
# The sudo password: held in this script's memory only. It is sent to each VM as the first line of
# the ssh input (never in a command line, an environment variable or a file on either side), and
# on the VM lives in an unnamed temp file held open by the runner, so it has no path and goes away
# with the run. A `sudo` stand-in, placed first in the runner's PATH for the run only, feeds it to
# the real sudo for each call; nothing is installed and no sudoers rule is changed. A wrong password
# is tried once per VM and then those checks are skipped, so it cannot pile up failed attempts.
#
# Each record is the line the script wrote on the VM plus "via":"fleet-check@<this machine>", so
# fleet results can be told from a host's own runs. Exit 0 = every VM reached and nothing failed;
# 1 = a VM was unreachable or a check failed; 2 = bad usage.
#
# Sequential for now. Centralising (a collector that pulls these from each VM, a schedule) comes
# later; the record format is already the one a collector would read.
# -----------------------------------------------------------------------------
set -uo pipefail
SCRIPT_VERSION="2.4.2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACKS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_ROOT="$(cd "$STACKS_DIR/.." && pwd)"

DOMAIN="core.andrusonline.com"
VM_USER="dave"
ZONE=""
KEY=""
ONLY=""
SKIP=""
LIST=0
GIT_ROLE=""
ASK_SUDO=0
SUDO_PW=""
APPLY=none
PUSH_AGENT=0
BINARY="${VITALS_BINARY:-}"
LOG="${DRIFT_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/drift-log/drift.jsonl}"

usage() {
  sed -n '2,/^# ----/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  exit "${1:-0}"
}
die() {
  echo "fleet-check: $*" >&2
  exit 2
}

while (($#)); do
  case "$1" in
  --only)
    ONLY="${2:?--only needs a list}"
    shift
    ;;
  --skip)
    SKIP="${2:?--skip needs a list}"
    shift
    ;;
  --list) LIST=1 ;;
  --git-role)
    GIT_ROLE="${2:?--git-role needs personal|prod|ai}"
    shift
    ;;
  --user)
    VM_USER="${2:?--user needs a name}"
    shift
    ;;
  --domain)
    DOMAIN="${2:?--domain needs a name}"
    shift
    ;;
  --zone)
    ZONE="${2:?--zone needs a file}"
    shift
    ;;
  --key)
    KEY="${2:?--key needs a file}"
    shift
    ;;
  --log)
    LOG="${2:?--log needs a file}"
    shift
    ;;
  --ask-sudo) ASK_SUDO=1 ;;
  --push-agent) PUSH_AGENT=1 ;;
  --binary)
    BINARY="${2:?--binary needs a file}"
    shift
    ;;
  --apply)
    APPLY="${2:?--apply needs safe or all}"
    shift
    ;;
  -h | --help) usage 0 ;;
  *)
    echo "unknown option: $1" >&2
    usage 2
    ;;
  esac
  shift
done
case "$GIT_ROLE" in "" | personal | prod | ai) ;; *) die "--git-role must be personal, prod or ai" ;; esac
case "$APPLY" in none | safe | all) ;; *) die "--apply must be safe or all" ;; esac
[[ -n "$ZONE" ]] || ZONE="$REPO_ROOT/stacks/core/dns/bind/db.${DOMAIN}"
[[ -r "$ZONE" ]] || die "zone file not found: $ZONE (use --zone)"

# shellcheck disable=SC1091
. "$STACKS_DIR/os/common/drift/drift-log.sh"
export DRIFT_LOG="$LOG"

# Linux VMs: v<env><intent>x<n>, from the A records ("name IN A ip ; comment").
mapfile -t VMS < <(tr -d '\r' <"$ZONE" | awk '{ sub(/;.*/, "") } $2 == "IN" && $3 == "A" && $1 ~ /^v[a-z][a-z]x[0-9]+$/ { print $1 }' | sort -V)
((${#VMS[@]})) || die "no Linux VMs found in $ZONE"

selected() { # name
  [[ -z "$ONLY" || ",$ONLY," == *",$1,"* ]] && [[ ",$SKIP," != *",$1,"* ]]
}

write_down_history() {
  local host="$1" detail="$2" ts host_json summary mode
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  host_json="$(printf '%s' "$host" | _drift_json_escape)"
  mode=check
  [[ "$APPLY" == none ]] || mode=apply
  summary="$(printf '{"ts":"%s","host":"%s","verdict":"down","failed":1,"warned":0,"checks":1,"stacks":{},"behind":[],"failed_in":["fleet-check"],"mode":"%s"}' \
    "$ts" "$host_json" "$mode")"
  drift_run_summary "$host" "$summary" || {
    echo "fleet-check: could not write summary for $host" >&2
    return 1
  }
  drift_run_detail "$host" "$detail" || {
    echo "fleet-check: could not write last-run detail for $host" >&2
    return 1
  }
}

valid_summary() {
  python3 -c 'import json, re, sys
obj=json.load(sys.stdin)
host=sys.argv[1]
assert set(obj) == {"ts","host","verdict","failed","warned","checks","stacks","behind","failed_in","mode"}
assert obj["host"] == host and re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", obj["host"])
assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", obj["ts"])
assert obj["verdict"] in {"ok","drift"} and obj["mode"] in {"check","apply"}
assert all(type(obj[k]) is int and obj[k] >= 0 for k in ("failed","warned","checks"))
assert obj["verdict"] == ("ok" if obj["failed"] == 0 else "drift")
assert isinstance(obj["stacks"], dict) and isinstance(obj["behind"], list) and isinstance(obj["failed_in"], list)
assert all(re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", k) and re.fullmatch(r"[A-Za-z0-9._-]*", v) for k,v in obj["stacks"].items())
assert all(isinstance(v, str) and re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", v) for v in obj["behind"])
assert all(isinstance(v, str) and re.fullmatch(r"[A-Za-z0-9._/-]+", v) for v in obj["failed_in"])' "$1" <<<"$2"
}

if ((LIST)); then
  for vm in "${VMS[@]}"; do selected "$vm" && echo "$vm.$DOMAIN"; done
  exit 0
fi
command -v ssh >/dev/null || die "ssh not found"
command -v tar >/dev/null || die "tar not found"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=30 -o StrictHostKeyChecking=yes)
# The ssh config git-access writes matches the short names (vpnx1), not the FQDN used here, so name
# the key as git-access does.
[[ -n "$KEY" || ! -r "$HOME/.ssh/id_ed25519_github" ]] || KEY="$HOME/.ssh/id_ed25519_github"
[[ -z "$KEY" ]] || SSH+=(-i "$KEY" -o IdentitiesOnly=yes)
VIA="fleet-check@$( (hostname -s 2>/dev/null || hostname) | tr -cd 'A-Za-z0-9._-')"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null | tr -cd '0-9a-f')" # lets each VM tell whether its own checkout is behind
TMP="$(mktemp -d)"
trap 'SUDO_PW=""; rm -rf "$TMP"' EXIT

if ((PUSH_AGENT)); then
  [[ "$APPLY" == none ]] || die "--push-agent cannot be combined with --apply"
  [[ "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]] || die "push requires a committed checkout"
  speedtest_host="$(git -C "$REPO_ROOT" show "$HEAD_SHA:stacks/vitals/stack.env" |
    sed -n 's/^SPEEDTEST_HOST="\{0,1\}\([a-z0-9-]*\)"\{0,1\}$/\1/p' | head -n1)" ||
    die "cannot read the committed Vitals speed-test host"
  for vm in "${VMS[@]}"; do
    [[ "$vm" != "$speedtest_host" ]] || {
      selected "$vm" &&
        die "--push-agent cannot target $speedtest_host; use the manual Vitals converge with its locally supplied pinned speed-test engine"
    }
  done
  [[ -f "$BINARY" && ! -L "$BINARY" && -x "$BINARY" ]] || die "provide the pinned binary with --binary or VITALS_BINARY"
  pin="$(git -C "$REPO_ROOT" show "$HEAD_SHA:stacks/vitals/build-vitals-node.sh" |
    sed -n 's/^VITALS_SHA256=//p')" || die "cannot read committed binary pin"
  version="$(git -C "$REPO_ROOT" show "$HEAD_SHA:stacks/vitals/build-vitals-node.sh" |
    sed -n 's/^VITALS_VERSION=//p')" || die "cannot read committed binary version"
  [[ "$pin" =~ ^[0-9a-f]{64}$ ]] || die "invalid committed binary pin"
  [[ "$(sha256sum "$BINARY" | awk '{print $1}')" == "$pin" ]] || die "SHA256 mismatch for the local Vitals binary"
  [[ "$("$BINARY" --version)" == "vitals $version" ]] || die "unexpected local Vitals binary version"
  mkdir -p "$TMP/payload/.fleet" || die "cannot create payload"
  git -C "$REPO_ROOT" archive "$HEAD_SHA" stacks | tar -x -C "$TMP/payload" ||
    die "cannot archive committed stacks"
  cp -- "$BINARY" "$TMP/payload/.fleet/vitals" || die "cannot stage Vitals binary"
  printf '%s\n' "$HEAD_SHA" >"$TMP/payload/.fleet/VERSION"
  tar -C "$TMP/payload" -czf "$TMP/push.tgz" . || die "cannot create delivery archive"
fi

# What to do remotely (run under `bash -c`: the VMs' login shell is zsh): unpack to a temp dir, run, always clean up. With --ask-sudo the first input
# line is the sudo password: read it with builtins only, park it in an unlinked file on fd 9 (the
# runner's sudo stand-in reads it from there) and forget the variable.
# shellcheck disable=SC2016
REMOTE='d=$(mktemp -d) || exit 97; trap "rm -rf \"$d\"" EXIT
if [ -n "${FLEET_ASK_SUDO:-}" ]; then IFS= read -r pw; umask 077; pwf=$(mktemp -p "$d") && exec 9<>"$pwf" && rm -f "$pwf" && printf "%s\n" "$pw" >&9; pw=; fi
tar -xz -C "$d" || exit 98
if [ "${FLEET_PUSH_AGENT:-0}" = 1 ]; then
  chmod 755 "$d/.fleet/vitals" || exit 98
  bash "$d/stacks/os/common/drift/fleet-check-remote.sh" "$d/stacks" "$d/out.jsonl"
else
  bash "$d/os/common/drift/fleet-check-remote.sh" "$d" "$d/out.jsonl"
fi'
if ((ASK_SUDO)); then
  if [[ -t 0 ]]; then
    read -rsp "sudo password for $VM_USER on the VMs (not stored): " SUDO_PW
    echo
  else
    IFS= read -r SUDO_PW
  fi
  [[ -n "$SUDO_PW" ]] || die "--ask-sudo: no password given"
fi

mkdir -p "$(dirname "$LOG")" || die "cannot create $(dirname "$LOG")"
echo "fleet-check $SCRIPT_VERSION: ${#VMS[@]} Linux VM(s) in the zone, results to $LOG"

declare -a SUMMARY=()
declare -a RAN=()
declare -A DOWN=() INITIAL=() FINAL=() RECHECKED=() RECHECK_N=()
TABC="$(printf '	')"
final_failed=0
total_failed=0
unreachable=0

for vm in "${VMS[@]}"; do
  selected "$vm" || continue
  fqdn="$vm.$DOMAIN"
  echo
  echo "== $vm ($fqdn)"
  out="$TMP/$vm.out"
  err="$TMP/$vm.err"
  {
    ((ASK_SUDO)) && printf '%s\n' "$SUDO_PW"
    if ((PUSH_AGENT)); then cat "$TMP/push.tgz"; else tar -C "$STACKS_DIR" --exclude=.git -czf - .; fi
  } | "${SSH[@]}" "$VM_USER@$fqdn" "bash -c 'export FLEET_GIT_ROLE=$GIT_ROLE FLEET_APPLY=$APPLY FLEET_HEAD=$HEAD_SHA FLEET_PUSH_AGENT=$PUSH_AGENT$( ((ASK_SUDO)) && echo " FLEET_ASK_SUDO=1"); $REMOTE'" >"$out" 2>"$err"
  statuses=("${PIPESTATUS[@]}")
  rc="${statuses[1]}"
  if ((statuses[0] != 0 && rc == 0)); then
    echo "fleet-check: archive transfer failed for $vm" >&2
    rc=98
  fi
  sed 's/^/   /' "$err"
  RAN+=("$vm")

  if ((rc != 0)); then
    # 255 is ssh itself (down, refused, host key unknown or changed, key not accepted).
    if ((rc == 255)); then reason="ssh failed: $(grep -v '^Warning:' "$err" | tail -n1)"; else reason="remote step failed (exit $rc)"; fi
    DRIFT_LOG="$TMP/$vm.syn" drift_record fleet-check "$SCRIPT_VERSION" 0 1 --mode fleet-check --host "$vm" --failures "$reason"
    sed 's/}$/,"via":"'"$VIA"'"}/' "$TMP/$vm.syn" >>"$LOG"
    sed 's/}$/,"via":"'"$VIA"'"}/' "$TMP/$vm.syn" >"$TMP/$vm.detail"
    write_down_history "$vm" "$TMP/$vm.detail" || exit 1
    echo "   UNREACHABLE: $reason"
    SUMMARY+=("$(printf '%-8s  %s' "$vm" "UNREACHABLE")")
    unreachable=$((unreachable + 1))
    DOWN[$vm]=1
    continue
  fi

  # What the VM sent back besides the JSON records is data, not instructions: keep only well-formed
  # protocol lines and strip control characters (the tab is kept).
  clean="$TMP/$vm.clean"
  tr -d '\000-\010\013-\037' <"$out" | grep -a -E "^(\{|FIX|APPLIED|RECHECK|REMAIN|SUMMARY)" >"$clean" || true
  grep -a -E "^FIX${TABC}[0-9]{1,3}${TABC}(safe|unsafe|manual)${TABC}[^${TABC}]*${TABC}[^${TABC}]*\$" "$clean" >"$TMP/$vm.fix" || true
  grep -a -E "^APPLIED${TABC}[0-9]{1,3}${TABC}(safe|unsafe)${TABC}(ok|failed|skipped|deferred)${TABC}[0-9-]+${TABC}[^${TABC}]*${TABC}[^${TABC}]*${TABC}[^${TABC}]*\$" "$clean" >"$TMP/$vm.applied" || true
  grep -a -E "^REMAIN${TABC}[0-9]{1,3}${TABC}(safe|unsafe|manual)${TABC}[^${TABC}]*${TABC}[^${TABC}]*\$" "$clean" >"$TMP/$vm.remain" || true

  # The VM's temp directory name changes every run; keep it out of the failure text so the same
  # failure reads the same each time.
  tmpre='\/tmp\/tmp\.[A-Za-z0-9]{10}'
  n=0
  failed=0
  detail="$TMP/$vm.detail"
  : >"$detail"
  summary_line=""
  while IFS= read -r line; do
    if [[ "$line" == SUMMARY$'\t'* ]]; then
      candidate="${line#SUMMARY$'\t'}"
      if ! valid_summary "$vm" "$candidate"; then
        echo "fleet-check: invalid summary received from $vm" >&2
        exit 1
      fi
      summary_line="$candidate"
      continue
    fi
    [[ "$line" =~ ^\{\"ts\":\"[0-9T:Z-]+\",\"host\":\"[A-Za-z0-9._-]*\",\"script\":\"[^\"]*\",\"version\":\"[^\"]*\",(\"stack\":\"[a-z0-9-]+\",)?\"mode\":\"[a-z-]*\", ]] || continue
    line="$(sed -E "s/$tmpre/<fleet-tmp>/g" <<<"$line")"
    line="${line%\}},\"via\":\"$VIA\"}"
    printf '%s\n' "$line" >>"$LOG"
    printf '%s\n' "$line" >>"$detail"
    n=$((n + 1))
    f="${line#*\"failed\":}"
    f="${f%%,*}"
    [[ "$f" =~ ^[0-9]+$ ]] && failed=$((failed + f))
  done <"$clean"
  total_failed=$((total_failed + failed))
  INITIAL[$vm]=$failed
  FINAL[$vm]=$failed

  # The recheck after --apply: logged too, marked "phase":"recheck" so drift before and after a fix
  # can be told apart.
  rn=0
  rfailed=0
  while IFS= read -r line; do
    line="${line#RECHECK"${TABC}"}"
    [[ "$line" =~ ^\{\"ts\":\"[0-9T:Z-]+\",\"host\":\"[A-Za-z0-9._-]*\",\"script\":\"[^\"]*\",\"version\":\"[^\"]*\",(\"stack\":\"[a-z0-9-]+\",)?\"mode\":\"[a-z-]*\", ]] || continue
    line="$(sed -E "s/$tmpre/<fleet-tmp>/g" <<<"$line")"
    line="${line%\}},\"phase\":\"recheck\",\"via\":\"$VIA\"}"
    printf '%s\n' "$line" >>"$LOG"
    printf '%s\n' "$line" >>"$detail"
    rn=$((rn + 1))
    f="${line#*\"failed\":}"
    f="${f%%,*}"
    [[ "$f" =~ ^[0-9]+$ ]] && rfailed=$((rfailed + f))
  done < <(grep -a "^RECHECK${TABC}" "$clean")
  if ((rn > 0)); then
    RECHECKED[$vm]=1
    FINAL[$vm]=$rfailed
    RECHECK_N[$vm]=$rn
  fi
  final_failed=$((final_failed + ${FINAL[$vm]}))

  if [[ -z "$summary_line" ]]; then
    echo "fleet-check: remote summary missing for $vm" >&2
    exit 1
  fi
  drift_run_summary "$vm" "$summary_line" || {
    echo "fleet-check: could not write summary for $vm" >&2
    exit 1
  }
  drift_run_detail "$vm" "$detail" || {
    echo "fleet-check: could not write last-run detail for $vm" >&2
    exit 1
  }

  echo "   recorded $n check(s), $failed failed"
  if ((rn > 0)); then
    echo "   recheck after fixes: $rn check(s), $rfailed failed"
    SUMMARY+=("$(printf '%-8s  %3d recorded  %3d failed  ->  %3d failed after fixes' "$vm" "$n" "$failed" "$rfailed")")
  else
    SUMMARY+=("$(printf '%-8s  %3d recorded  %3d failed' "$vm" "$n" "$failed")")
  fi
done

# ---------------------------------------------------------------- the fix summary
# list_fixes FILE INDENT: numbered, in order; FIX/REMAIN lines are tag order class why command
list_fixes() {
  sort -t "$TABC" -k2,2n -k5,5 -u "$1" | awk -F '\t' -v ind="$2" '{ printf "%s%d. [%s] %s\n%s   # %s\n", ind, NR, $3, $5, ind, $4 }'
}

echo
if [[ "$APPLY" == none ]]; then
  echo "== Fix summary (per machine, in the order to run them; nothing here has been run)"
  echo "   Each fix is [safe] (unlikely to break the VM's service), [unsafe] (likely to) or [manual] (needs you)."
  echo "   Run on the machine itself, or let fleet-check do it: --apply safe | --apply all. Read them first."
else
  echo "== Fix summary (--apply $APPLY): what was applied, whether the recheck passed, what is still to do"
  echo "   Fixes ran from the copy of stacks/ shipped with this run: the same version the checks used."
fi
for vm in "${RAN[@]}"; do
  echo
  if [[ -n "${DOWN[$vm]:-}" ]]; then
    echo "   $vm: unreachable; fix access first (git-access.ps1 -Only vms, then run this again)"
    continue
  fi
  if [[ "$APPLY" == none ]]; then
    if [[ -s "$TMP/$vm.fix" ]]; then
      echo "   $vm   (ssh $VM_USER@$vm.$DOMAIN)"
      list_fixes "$TMP/$vm.fix" "     "
    else
      echo "   $vm: nothing to fix"
    fi
    continue
  fi

  if [[ ! -s "$TMP/$vm.fix" ]]; then
    echo "   $vm: nothing to fix"
    continue
  fi
  echo "   $vm   (ssh $VM_USER@$vm.$DOMAIN)"
  if [[ -s "$TMP/$vm.applied" ]]; then
    echo "     applied:"
    sort -t "$TABC" -k2,2n "$TMP/$vm.applied" | awk -F '\t' '{
      tag = ($4 == "ok") ? "ok" : (($4 == "failed") ? "FAILED, exit " $5 : $4)
      printf "       [%s] [%s] %s\n          # %s\n", tag, $3, $7, $6
      if ($4 != "ok" && $8 != "") printf "          > %s\n", $8
    }'
  else
    echo "     applied: nothing (only manual items)"
  fi
  if [[ -n "${RECHECKED[$vm]:-}" ]]; then
    if ((${FINAL[$vm]} == 0)); then
      echo "     recheck: PASSED (${RECHECK_N[$vm]} checks, 0 failed)"
    else
      more=""
      grep -qE "^REMAIN${TABC}[0-9]+${TABC}(safe|unsafe)" "$TMP/$vm.remain" 2>/dev/null || more="; nothing left can be automated, the rest needs you"
      echo "     recheck: NOT PASSED (${RECHECK_N[$vm]} checks, ${FINAL[$vm]} failed; was ${INITIAL[$vm]})$more"
    fi
  else
    echo "     recheck: not run (nothing was applied)"
  fi
  if [[ -s "$TMP/$vm.remain" ]]; then
    echo "     still to do:"
    list_fixes "$TMP/$vm.remain" "       "
  elif [[ -z "${RECHECKED[$vm]:-}" ]]; then
    echo "     still to do:"
    list_fixes "$TMP/$vm.fix" "       "
  else
    echo "     still to do: nothing"
  fi
done

echo
echo "== Summary"
printf '   %s\n' "${SUMMARY[@]}"
if [[ "$APPLY" == none ]]; then
  echo "   unreachable: $unreachable   failed checks: $total_failed   log: $LOG"
else
  echo "   unreachable: $unreachable   failed checks: $total_failed before, $final_failed after   log: $LOG"
fi
((unreachable == 0 && final_failed == 0))
