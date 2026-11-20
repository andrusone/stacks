#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# fleet-check-remote.sh — the half of fleet-check.sh that runs ON a host
#
# Shipped to the host with a copy of stacks/ and run there; do not run it by hand unless you mean
# to. By default it is read-only: every script is run in its check mode (--check, --only validate, or
# a doctor), it writes only to the output file it is given, and nothing on the host is installed,
# changed or recorded in the host's own drift log.
#
# Usage:  fleet-check-remote.sh STACKS_DIR OUT_FILE
#   FLEET_GIT_ROLE   personal|prod|ai: also run git-access.sh --check with this role (default: skip)
#   FLEET_APPLY      none (default) | safe | all
#                    safe: apply the fixes classed "safe", then re-run the checks
#                    all:  apply "safe" and "unsafe" fixes, then re-run the checks
#                    Fixes classed "manual" are never applied. See FIXES.md for every fix and why.
#
# stdout (tab-separated protocol lines, besides the JSON records):
#   {json}                                    drift records from the first pass
#   FIX    order class why command            what would fix this host, in order
#   APPLIED order class result rc why command note      one per fix (apply mode); result is ok,
#                                             failed, skipped (unsafe, not allowed) or deferred
#                                             (apt/dpkg was busy, e.g. PackageKit: not a failure)
#   RECHECK {json}                            drift records from the pass after applying
#   REMAIN order class why command            what is still needed after the recheck
# stderr  what ran, what was skipped and why, and the scripts' own output
#
# Needs sudo for the scripts that read root-only state (post-clone validate, build-core-node.sh,
# the baseline and mount-nas checks): passwordless, or the password from fleet-check.sh --ask-sudo
# (FLEET_ASK_SUDO=1, password on fd 9). Without sudo those are skipped and said so.
# -----------------------------------------------------------------------------
set -uo pipefail
# shellcheck disable=SC2034
SCRIPT_VERSION="2.10.1"

STACKS="${1:?usage: fleet-check-remote.sh STACKS_DIR OUT_FILE}"
OUT1="${2:?usage: fleet-check-remote.sh STACKS_DIR OUT_FILE}"
OUT="$OUT1"
FLEET_GIT_ROLE="${FLEET_GIT_ROLE:-}"
FLEET_APPLY="${FLEET_APPLY:-none}"
case "$FLEET_APPLY" in none | safe | all) ;; *) FLEET_APPLY=none ;; esac
FLEET_CHECK_TIMEOUT="${FLEET_CHECK_TIMEOUT:-600}"
[[ "$FLEET_CHECK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || FLEET_CHECK_TIMEOUT=600
FLEET_HEAD="${FLEET_HEAD:-}" # the controller's checkout commit: a host on the same commit needs no pull
WORK="$(dirname "$OUT1")"
TAB=$'\t'

# shellcheck disable=SC1091
. "$STACKS/os/common/drift/drift-log.sh"
STACK_LIB="$STACKS/os/common/stack/stack-lib.sh"
if [[ ! -r "$STACK_LIB" ]]; then
  echo "fleet-check: stack library not readable: $STACK_LIB" >&2
  exit 97
fi
# shellcheck disable=SC1090
. "$STACK_LIB"
FLEET_HOST="${FLEET_HOST:-$(hostname -s 2>/dev/null || hostname)}"
STACK_MARKER_DIR="${ANDRUSONE_ETC:-/etc}/andrusone/stacks"
declare -A RUN_STACK_VERSIONS=() RUN_STACK_BEHIND=()

: >"$OUT"
chmod 666 "$OUT"        # root-run scripts append to it too
export DRIFT_LOG="$OUT" # every script records here, not in this host's own log
# A non-interactive ssh session has a short PATH; the doctors expect the one a login shell has. The
# bootstrap scripts put Go, Node and ~/.local/bin on PATH through ~/.profile, so take it from there.
export PATH="$HOME/.local/bin:$PATH"
if [[ -r "$HOME/.profile" ]]; then
  profile_path="$(bash -c '. "$HOME/.profile" >/dev/null 2>&1; printf %s "$PATH"' 2>/dev/null || true)"
  [[ -z "$profile_path" ]] || export PATH="$profile_path:$PATH"
fi
MARK="$WORK/.started" # the witness at the end of a pass compares file times with this

say() { printf '[fleet-check] %s\n' "$*" >&2; }
skip() { say "SKIP  $1: $2"; }
say "fleet-check-remote $SCRIPT_VERSION"

# have_record NAME — a record for this script is already in the output
have_record() { grep -qF "\"script\":\"$1\"" "$OUT"; }

# run_check NAME cmd... — run one check; if it left no record (it predates the drift log, or died
# first) record one from its exit code so the host still shows up.
run_check() {
  local name="$1" stack_id="" before after rc
  shift
  if [[ "${1:-}" == --stack ]]; then
    stack_id="${2:?--stack needs an id}"
    shift 2
  fi
  say "RUN   $name"
  before="$(wc -l <"$OUT")"
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=5s "$FLEET_CHECK_TIMEOUT" "$@" >&2 </dev/null
  else
    "$@" >&2 </dev/null
  fi
  rc=$?
  after="$(wc -l <"$OUT")"
  if ((after == before)); then
    local -a stack_option=()
    [[ -z "$stack_id" ]] || stack_option=(--stack "$stack_id")
    if ((rc == 0)); then
      drift_record "$name" unknown 0 0 --mode check "${stack_option[@]}"
    else
      drift_record "$name" unknown 0 1 --mode check --failures "exit ${rc} with no drift record" "${stack_option[@]}"
    fi
  fi
}

emit_run_summary() {
  local file line rec_failed rec_warned rec_script first=1
  local total_failed=0 total_warned=0 checks=0 verdict mode ts
  local stacks_json='{' behind_json='[' failed_json='['
  local -A failed_in=()
  local -a records=("$OUT1")
  [[ "$OUT" == "$OUT1" ]] || records+=("$OUT")
  for file in "${records[@]}"; do
    while IFS= read -r line; do
      [[ "$line" == \{* ]] || continue
      rec_failed=0 rec_warned=0 rec_script=""
      [[ "$line" =~ \"failed\":([0-9]+) ]] && rec_failed="${BASH_REMATCH[1]}"
      [[ "$line" =~ \"warned\":([0-9]+) ]] && rec_warned="${BASH_REMATCH[1]}"
      [[ "$line" =~ \"script\":\"([^\"]*)\" ]] && rec_script="${BASH_REMATCH[1]}"
      total_failed=$((total_failed + rec_failed))
      total_warned=$((total_warned + rec_warned))
      checks=$((checks + 1))
      ((rec_failed == 0)) || failed_in[$rec_script]=1
    done <"$file"
  done
  for id in $(printf '%s\n' "${!RUN_STACK_VERSIONS[@]}" | sort); do
    ((first)) || stacks_json+=','
    stacks_json+="\"$(_drift_json_escape <<<"$id")\":\"$(_drift_json_escape <<<"${RUN_STACK_VERSIONS[$id]}")\""
    first=0
  done
  stacks_json+='}'
  first=1
  for id in $(printf '%s\n' "${!RUN_STACK_BEHIND[@]}" | sort); do
    ((first)) || behind_json+=','
    behind_json+="\"$(_drift_json_escape <<<"$id")\""
    first=0
  done
  behind_json+=']'
  first=1
  for rec_script in $(printf '%s\n' "${!failed_in[@]}" | sort); do
    ((first)) || failed_json+=','
    failed_json+="\"$(_drift_json_escape <<<"$rec_script")\""
    first=0
  done
  failed_json+=']'
  verdict=ok
  ((total_failed == 0)) || verdict=drift
  mode=check
  [[ "$FLEET_APPLY" == none ]] || mode=apply
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'SUMMARY\t{"ts":"%s","host":"%s","verdict":"%s","failed":%d,"warned":%d,"checks":%d,"stacks":%s,"behind":%s,"failed_in":%s,"mode":"%s"}\n' \
    "$ts" "$FLEET_HOST" "$verdict" "$total_failed" "$total_warned" "$checks" "$stacks_json" "$behind_json" "$failed_json" "$mode"
}

stack_version_is_behind() {
  local installed="$1" current="$2"
  [[ "$installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$installed" != "$current" ]] &&
    [[ "$(printf '%s\n' "$installed" "$current" | sort -V | head -n1)" == "$installed" ]]
}

run_manifest_command() {
  local stack_id="$1" command_text="$2" needs_root="$3"
  local -a args=()
  local script_name script_path
  IFS=' ' read -r -a args <<<"$command_text"
  script_name="${args[0]:-}"
  if [[ -z "$script_name" || "$script_name" == /* || "$script_name" == *".."* ]]; then
    drift_record stack-manifest unknown 0 1 --mode check --stack "$stack_id" --failures "invalid command path in manifest"
    return
  fi
  script_path="$STACKS/$stack_id/$script_name"
  if [[ ! -f "$script_path" ]]; then
    drift_record stack-manifest unknown 0 1 --mode check --stack "$stack_id" --failures "manifest command not found: $script_name"
    return
  fi
  if [[ "$needs_root" == 1 ]]; then
    if ((!SUDO_OK)); then
      say "SKIP  $script_name: manifest requires root but passwordless sudo is unavailable"
      drift_record "$script_name" unknown 0 1 --mode check --stack "$stack_id" --failures "requires root; no passwordless sudo"
      return
    fi
    run_check "$script_name" --stack "$stack_id" sudo -n env DRIFT_LOG="$OUT" bash "$script_path" "${args[@]:1}"
  else
    run_check "$script_name" --stack "$stack_id" bash "$script_path" "${args[@]:1}"
  fi
}

run_stack_checks() {
  local marker id manifest host_list current_version repo_script needs_root
  local marker_count=0 expected_count=0
  local -A marked=()
  local -a manifests=()
  RUN_STACK_VERSIONS=()
  RUN_STACK_BEHIND=()

  if [[ -d "$STACK_MARKER_DIR" ]]; then
    for marker in "$STACK_MARKER_DIR"/*; do
      [[ -f "$marker" ]] || continue
      id="${marker##*/}"
      marker_count=$((marker_count + 1))
      if [[ ! "$id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
        drift_record stack-marker unknown 0 1 --mode check --host "$FLEET_HOST" --failures "invalid stack marker filename"
        continue
      fi
      if ! stack_marker_read "$id"; then
        RUN_STACK_VERSIONS[$id]="unknown"
        drift_record stack-marker unknown 0 1 --mode check --host "$FLEET_HOST" --stack "$id" --failures "invalid stack marker: $id"
        continue
      fi
      marked[$id]=1
      if [[ "$STACK_MARKER_SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        RUN_STACK_VERSIONS[$id]="$STACK_MARKER_SCRIPT_VERSION"
      else
        RUN_STACK_VERSIONS[$id]="unknown"
        drift_record stack-marker unknown 0 1 --mode check --host "$FLEET_HOST" --stack "$id" --failures "invalid SCRIPT_VERSION in stack marker"
      fi
      say "STACK $id SCRIPT_VERSION=${RUN_STACK_VERSIONS[$id]}"
    done
  fi

  shopt -s nullglob
  manifests=("$STACKS"/*/stack.env)
  shopt -u nullglob
  for manifest in "${manifests[@]}"; do
    id="$(basename -- "$(dirname -- "$manifest")")"
    [[ "$id" == _template ]] && continue
    if ! stack_manifest_load "$id" "$STACKS"; then
      drift_record stack-manifest unknown 0 1 --mode check --host "$FLEET_HOST" --stack "$id" --failures "invalid stack manifest: $id"
      continue
    fi
    host_list="$STACK_MANIFEST_HOSTS"
    if [[ " $host_list " == *" $FLEET_HOST "* ]]; then
      expected_count=$((expected_count + 1))
      if [[ -z "${marked[$id]:-}" ]]; then
        drift_record stack-missing unknown 0 1 --mode check --host "$FLEET_HOST" --stack "$id" --failures "stack missing: manifest lists $FLEET_HOST but no marker exists"
        continue
      fi
    elif [[ -n "${marked[$id]:-}" ]]; then
      drift_record stack-unlisted "$STACK_MARKER_SCRIPT_VERSION" 0 0 --warned 1 --mode check --host "$FLEET_HOST" --stack "$id" --failures "unlisted stack: $FLEET_HOST is not in the manifest host list"
    fi

    [[ -n "${marked[$id]:-}" ]] || continue
    needs_root="$STACK_MANIFEST_NEEDS_ROOT"
    run_manifest_command "$id" "$STACK_MANIFEST_CHECK" "$needs_root"
    run_manifest_command "$id" "$STACK_MANIFEST_VERIFY" "$needs_root"

    repo_script="${STACK_MANIFEST_CONVERGE%% *}"
    if [[ "$repo_script" == /* || "$repo_script" == *".."* ]]; then
      continue
    fi
    repo_script="$STACKS/$id/$repo_script"
    current_version="$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$repo_script" 2>/dev/null | head -n1)"
    if [[ ! "$current_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      drift_record stack-manifest unknown 0 1 --mode check --host "$FLEET_HOST" --stack "$id" \
        --failures "cannot read a valid SCRIPT_VERSION from the manifest converge script"
      continue
    fi
    if [[ -n "$current_version" ]] &&
      stack_version_is_behind "$STACK_MARKER_SCRIPT_VERSION" "$current_version"; then
      RUN_STACK_BEHIND[$id]=1
      drift_record stack-behind "$STACK_MARKER_SCRIPT_VERSION" 0 0 --warned 1 --mode check --host "$FLEET_HOST" --stack "$id" \
        --failures "stack behind: marker $STACK_MARKER_SCRIPT_VERSION, repository $current_version"
    fi
  done

  for id in "${!marked[@]}"; do
    [[ -f "$STACKS/$id/stack.env" ]] && continue
    drift_record stack-unlisted "${RUN_STACK_VERSIONS[$id]}" 0 0 --warned 1 --mode check --host "$FLEET_HOST" --stack "$id" \
      --failures "unlisted stack: no manifest exists"
  done

  if ((marker_count == 0 && expected_count == 0)); then
    say "STACK os only (no stack markers or expected stacks)"
  fi
}

# --- --ask-sudo: a `sudo` stand-in, first in PATH for this run only -----------------------------
# fleet-check.sh left the sudo password in an unnamed file on fd 9. Every `sudo ...` the scripts run
# goes through the stand-in, which pipes the password (then the caller's own input) to the real
# sudo -S, ignoring any cached ticket (-k) so the password is never left in a pipe a command might
# read. -n is dropped (the point is to authenticate) and `sudo -v` becomes `sudo true`.
if [[ -n "${FLEET_ASK_SUDO:-}" ]]; then
  if [[ -e /proc/self/fd/9 ]]; then
    SHIM_DIR="$WORK/shim"
    mkdir -p "$SHIM_DIR"
    cat >"$SHIM_DIR/sudo" <<'EOF'
#!/bin/bash
args=()
for a in "$@"; do
  case "$a" in -n | --non-interactive) ;; *) args+=("$a") ;; esac
done
((${#args[@]})) || args=(true)
[[ "${args[0]}" == -v ]] && args=(true)
{ cat /proc/self/fd/9; cat; } | exec @REAL_SUDO@ -S -k -p '' "${args[@]}"
EOF
    sed -i "s|@REAL_SUDO@|$(command -v sudo)|" "$SHIM_DIR/sudo"
    chmod 700 "$SHIM_DIR/sudo"
    PATH="$SHIM_DIR:$PATH"
    # Tried once: a wrong password is dropped here instead of being retried by every script.
    if ! sudo -n true 2>/dev/null; then
      say "sudo password not accepted for $(id -un) on this host: root-only checks will be skipped"
      PATH="${PATH#"$SHIM_DIR":}"
    fi
  else
    say "--ask-sudo was set but no password reached this host: root-only checks will be skipped"
  fi
fi

# The Vitals agent runs as root. Preserve the same command path without requiring sudo to be installed.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  sudo() {
    local -a args=()
    local arg
    for arg in "$@"; do
      case "$arg" in -n | --non-interactive) ;; *) args+=("$arg") ;; esac
    done
    ((${#args[@]})) || return 0
    [[ "${args[0]}" == -v ]] && return 0
    "${args[@]}"
  }
fi

SUDO_OK=0
sudo -n true 2>/dev/null && SUDO_OK=1
if [[ "${FLEET_PUSH_AGENT:-0}" == 1 ]]; then
  ((SUDO_OK)) || {
    say "push-agent requires sudo; nothing installed"
    exit 96
  }
  payload="$(dirname "$STACKS")/.fleet"
  commit="$(cat "$payload/VERSION")" || exit 96
  [[ "$commit" =~ ^[0-9a-f]{40}$ && "$commit" == "$FLEET_HEAD" ]] ||
    {
      say "invalid delivery commit"
      exit 96
    }
  sudo -n env DRIFT_LOG="$OUT" bash "$STACKS/vitals/build-vitals-node.sh" \
    --binary "$payload/vitals" --stacks-commit "$commit" --skip prereqs,verify >&2 </dev/null ||
    {
      say "push-agent failed"
      exit 96
    }
fi
KIND=server
[[ "$(systemctl get-default 2>/dev/null)" == graphical.target ]] && KIND=desktop

# ================================================================== one pass of checks
check_qemu_guest_agent() {
  local package_status passed failures=()
  if command -v dpkg-query >/dev/null 2>&1; then
    package_status="$(dpkg-query -W -f='${db:Status-Status}' qemu-guest-agent 2>/dev/null || true)"
    [[ "$package_status" == installed ]] || failures+=("qemu-guest-agent package is not installed")
  else
    failures+=("dpkg-query is unavailable; cannot verify qemu-guest-agent package")
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet qemu-guest-agent 2>/dev/null ||
      failures+=("qemu-guest-agent unit is not active")
  else
    failures+=("systemctl is unavailable; cannot verify qemu-guest-agent unit")
  fi
  [[ -e "$QEMU_GUEST_AGENT_DEVICE" ]] ||
    failures+=("QEMU guest-agent virtio serial channel is missing: $QEMU_GUEST_AGENT_DEVICE")
  passed=$((3 - ${#failures[@]}))
  drift_record qemu-guest-agent "$SCRIPT_VERSION" "$passed" "${#failures[@]}" \
    --mode check --host "$FLEET_HOST" --failures "$(
      IFS='|'
      printf '%s' "${failures[*]}"
    )"
}

run_checks() {
  : >"$OUT"
  chmod 666 "$OUT"
  export DRIFT_LOG="$OUT"
  : >"$MARK"

  # core node: what a real run would change (plan), and the verify phase
  if ((SUDO_OK)) && sudo -n test -r /etc/core-node/node.env 2>/dev/null; then
    run_check build-core-node.sh sudo -n env DRIFT_LOG="$OUT" bash "$STACKS/core/build-core-node.sh" --check
    run_check build-core-node.sh sudo -n env DRIFT_LOG="$OUT" bash "$STACKS/core/build-core-node.sh" --only verify --check
  else
    skip build-core-node.sh "not a core node (no /etc/core-node/node.env) or no passwordless sudo"
  fi

  # golden image: the validate stage
  if ((SUDO_OK)); then
    run_check "post-clone-${KIND}.sh" bash "$STACKS/os/ubuntu/image/post-clone-${KIND}.sh" --only validate
  else
    skip "post-clone-*.sh" "no passwordless sudo"
  fi

  # doctors written by the bootstrap scripts (the validate stage may already have run one)
  local d
  for d in shell-doctor python-doctor dev-doctor; do
    if have_record "$d"; then
      continue
    elif [[ -x "$HOME/.local/bin/$d" ]]; then
      run_check "$d" "$HOME/.local/bin/$d"
    else
      skip "$d" "not installed on this host"
    fi
  done

  # git access
  if [[ -n "$FLEET_GIT_ROLE" ]]; then
    (cd "$HOME" && run_check git-access.sh bash "$STACKS/os/common/git-access/git-access.sh" --role "$FLEET_GIT_ROLE" --check)
  else
    skip git-access.sh "no --git-role given (the role is per machine)"
  fi

  if ((SUDO_OK)); then
    run_check post-install-baseline-all.sh bash "$STACKS/os/ubuntu/image/post-install-baseline-all.sh" --check
    run_check mount-nas.sh bash "$STACKS/os/ubuntu/mount-nas.sh" --check
  else
    skip "post-install-baseline-all.sh, mount-nas.sh" "no passwordless sudo"
  fi
  skip "bootstrap-*-dev.sh" "no read-only check mode; their doctors cover it"

  run_stack_checks
  check_qemu_guest_agent
  witness
}

# witness: did anything change while the checks ran? Files modified under the places these scripts
# manage since the pass started. Not proof (a service may touch its own files), but a check that wrote
# config would show up here.
witness() {
  local changed FIND=(find)
  ((SUDO_OK)) && FIND=(sudo -n find)
  # Not signals: Go's telemetry counter (changes whenever the dev doctor runs `go version`), a desktop's own
  # VS Code state and logs, and CUPS's subscription file.
  changed="$("${FIND[@]}" /etc /usr/local /opt /var/lib/core-node /var/cache/core-node "$HOME/.ssh" "$HOME/.config" "$HOME/.local/bin" \
    -xdev -type f -not -path '*/.config/go/telemetry/*' -not -path '*/.config/Code/*' -not -path '/etc/cups/*' \
    -newer "$MARK" 2>/dev/null | head -n 50)"
  # It reports; it does not count as a failed check. A busy desktop changes files by itself, and counting
  # those would make a clean recheck look broken. The files are listed here and in the record.
  if [[ -z "$changed" ]]; then
    say "WITNESS no managed files changed while the checks ran"
    drift_record fleet-check-witness 1.1.0 1 0 --mode fleet-check
  else
    say "WITNESS files changed while the checks ran (review; not counted as a failure):"
    printf '%s\n' "$changed" | sed 's/^/    /' >&2
    drift_record fleet-check-witness 1.1.0 0 0 --mode fleet-check --warned "$(printf '%s\n' "$changed" | wc -l)" --failures "$(printf '%s\n' "$changed" | tr '\n' '|')"
  fi
}

# ================================================================== fixes
# Every fix has a CLASS (see FIXES.md for the reasoning behind each):
#   safe    less than a 50% chance of breaking the service the host is for: applied by --apply safe|all
#   unsafe  more than a 50% chance of breaking it: applied only by --apply all
#   manual  needs a person, a decision or something outside the VM: never applied, always listed
# Commands are written with @S@ for the stacks directory: the host's own checkout when shown to you,
# the copy shipped with this run when applied (so what is applied is exactly what was checked).
PLAN=()
declare -A PLAN_SEEN=()
declare -A FAILED_CMDS=() # fixes that failed in an earlier round: not tried again
PULL_SKIPPED=""
REPO=""
PRE=""

# needrestart (Ubuntu's default) restarts services after every apt run, which in a fix run would restart
# systemd-networkd and systemd-resolved under you. While fixes run, a drop-in tells it only to list them; it is
# removed afterwards, and the list is reported as a manual item.
NEEDRESTART_DIR="${FLEET_NEEDRESTART_DIR:-/etc/needrestart/conf.d}"
NEEDRESTART_GUARD_FILE="$NEEDRESTART_DIR/90-fleet-check.conf"
NEEDRESTART_GUARD=0
needrestart_guard_on() {
  [[ -d "$NEEDRESTART_DIR" ]] || return 0
  printf "\$nrconf{restart} = 'l';\n" | sudo tee "$NEEDRESTART_GUARD_FILE" >/dev/null 2>&1 && NEEDRESTART_GUARD=1
  return 0
}
needrestart_guard_off() {
  ((NEEDRESTART_GUARD)) && sudo rm -f "$NEEDRESTART_GUARD_FILE" 2>/dev/null
  NEEDRESTART_GUARD=0
  return 0
}
trap needrestart_guard_off EXIT

fix() { # order class why command
  [[ -n "${PLAN_SEEN[$4]:-}" ]] && return
  PLAN_SEEN[$4]=1
  PLAN+=("$1${TAB}$2${TAB}$3${TAB}$4")
}
show_cmd() { printf '%s' "${1//@S@/$REPO/stacks}"; }
real_cmd() { printf '%s' "${1//@S@/$STACKS}"; }
split_failures() { sed 's/","/\n/g; s/^"//; s/"$//' <<<"$1"; }

# apt_lock_pid — the pid holding apt's or dpkg's lock, or nothing. dpkg and apt take POSIX locks, which
# show up in /proc/locks by inode (flock(1) cannot see them, and PackageKit's idle daemon is not a holder).
apt_lock_pid() {
  local f ino pid
  for f in $APT_LOCK_PATHS; do
    ino="$(stat -c %i "$f" 2>/dev/null)" || continue
    pid="$(awk -v i=":$ino " 'index($0, i) { print $5; exit }' "$PROC_LOCKS" 2>/dev/null)"
    [[ -n "$pid" ]] && {
      printf '%s' "$pid"
      return 0
    }
  done
  return 1
}
apt_busy_text() { # "pid N (command)"
  local pid
  pid="$(apt_lock_pid)" || return 1
  printf 'pid %s (%s)' "$pid" "$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-80)"
}

apt_dpkg_fix() {
  local busy
  if busy="$(apt_busy_text)"; then
    fix 95 manual "apt/dpkg is busy, which is not a fault: $busy holds the lock (often PackageKit or unattended-upgrades). Wait for it, then run the checks again" \
      "ps -fp $(apt_lock_pid)"
  else
    fix 95 manual "the package system reports a problem: finish interrupted installs" "sudo dpkg --configure -a && sudo apt-get -f install"
  fi
}
# Orders of the fixes that run apt or dpkg (directly or through a script) and so cannot run while apt is busy.
APT_ORDERS=" 30 40 41 50 60 61 62 70 80 86 "
# Overridable so the tests can stand in for /proc/locks and the lock files.
APT_LOCK_PATHS="${FLEET_APT_LOCK_PATHS:-/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock}"
PROC_LOCKS="${FLEET_PROC_LOCKS:-/proc/locks}"
APT_WAIT="${FLEET_APT_WAIT:-120}" # seconds to wait for apt before deferring a fix
ZERO_UNIT_FILE="${FLEET_ZERO_UNIT:-/etc/systemd/system/zero-free-space.service}"
APT_SOURCES_DIR="${FLEET_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
VITALS_BINARY="${FLEET_VITALS_BINARY:-/var/cache/vitals/vitals-linux-amd64}"
VITALS_TOKEN="${FLEET_VITALS_TOKEN:-/etc/vitals/token}"
QEMU_GUEST_AGENT_DEVICE="${FLEET_QEMU_GUEST_AGENT_DEVICE:-/dev/virtio-ports/org.qemu.guest_agent.0}"

vitals_fix_ready() {
  local script="$STACKS/vitals/build-vitals-node.sh" expected_hash expected_version actual_hash actual_version
  ((SUDO_OK)) || return 1
  [[ -f "$script" && -f "$STACKS/vitals/stack.env" ]] || return 1
  stack_manifest_load vitals "$STACKS" >/dev/null || return 1
  [[ -z "$STACK_MANIFEST_SPEEDTEST_HOST" || "$FLEET_HOST" != "$STACK_MANIFEST_SPEEDTEST_HOST" ]] || return 1
  [[ "$VITALS_BINARY" == /* && "$VITALS_TOKEN" == /* ]] || return 1
  expected_hash="$(sed -n 's/^VITALS_SHA256=\([0-9a-f]\{64\}\)$/\1/p' "$script" | head -n1)"
  expected_version="$(sed -n 's/^VITALS_VERSION=\([0-9][0-9.]*\)$/\1/p' "$script" | head -n1)"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ && "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  sudo -n test -f "$VITALS_BINARY" 2>/dev/null || return 1
  sudo -n test ! -L "$VITALS_BINARY" 2>/dev/null || return 1
  sudo -n test -x "$VITALS_BINARY" 2>/dev/null || return 1
  actual_hash="$(sudo -n sha256sum -- "$VITALS_BINARY" 2>/dev/null | awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || return 1
  actual_version="$(sudo -n "$VITALS_BINARY" --version 2>/dev/null)" || return 1
  [[ "$actual_version" == "vitals $expected_version" ]] || return 1
  sudo -n test -s "$VITALS_TOKEN" 2>/dev/null || return 1
  [[ "$(sudo -n stat -c '%a:%u' "$VITALS_TOKEN" 2>/dev/null)" == 600:0 ]]
}

find_repo() {
  local r
  for r in /etc/bind/network /nas/projects/andrusone.dev/network "$HOME/repo/network"; do
    if [[ -d "$r/.git" ]]; then
      REPO="$r"
      break
    fi
  done
  [[ -n "$REPO" ]] || REPO="<your checkout of the network repo>"
  # A checkout whose .git is root-owned (the core nodes' deploy-key clone) must be pulled with sudo.
  PRE=""
  [[ -d "$REPO/.git" && "$(stat -c %U "$REPO/.git" 2>/dev/null)" == root ]] && PRE="sudo "
}

# suggest_fixes FILE — fill PLAN from the records in FILE
suggest_fixes() {
  local file="$1" line script failed version failures mode f u n pkg port busy host_head record_stack quoted_binary
  local want_ssh=0 want_polish=0 want_zero=0 want_shell=0 want_baseline=0 want_mount=0 want_units=0 want_journal=0 want_vitals=0
  local core_failed=0 core_text="" core_n=0 any=0
  PLAN=()
  PLAN_SEEN=()
  find_repo

  while IFS= read -r line; do
    script="" failed=0 version="" failures="" mode="" record_stack=""
    [[ "$line" =~ \"script\":\"([^\"]*)\" ]] && script="${BASH_REMATCH[1]}"
    [[ "$line" =~ \"version\":\"([^\"]*)\" ]] && version="${BASH_REMATCH[1]}"
    [[ "$line" =~ \"stack\":\"([^\"]*)\" ]] && record_stack="${BASH_REMATCH[1]}"
    [[ "$line" =~ \"failed\":([0-9]+) ]] && failed="${BASH_REMATCH[1]}"
    [[ "$line" =~ \"failures\":\[([^]]*)\] ]] && failures="${BASH_REMATCH[1]}"
    [[ "$line" =~ \"mode\":\"([^\"]*)\" ]] && mode="${BASH_REMATCH[1]}"

    case "$script" in
    qemu-guest-agent)
      ((failed > 0)) || continue
      while IFS= read -r f; do
        case "$f" in
        "qemu-guest-agent package is not installed")
          fix 41 safe "qemu-guest-agent package is not installed on $FLEET_HOST" \
            "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent"
          ;;
        "qemu-guest-agent unit is not active")
          if [[ -e "$QEMU_GUEST_AGENT_DEVICE" ]]; then
            fix 44 safe "qemu-guest-agent is not active on $FLEET_HOST (virtio channel is present)" \
              "sudo systemctl enable --now qemu-guest-agent"
          fi
          ;;
        "QEMU guest-agent virtio serial channel is missing:"*)
          fix 94 manual "QEMU guest-agent virtio channel is missing on $FLEET_HOST; enable it in Proxmox VM Options and reboot" \
            "# on Proxmox: qm set <vmid> --agent enabled=1 ; then restart the VM"
          ;;
        *)
          fix 96 manual "cannot verify the QEMU guest agent on $FLEET_HOST: $f" \
            "# investigate qemu-guest-agent package, unit and virtio channel"
          ;;
        esac
      done < <(split_failures "$failures")
      ;;
    stack-missing)
      [[ "$record_stack" == vitals ]] && want_vitals=1
      ;;
    check-vitals.sh)
      if [[ "$record_stack" == vitals ]] && ((failed > 0)); then
        want_vitals=1
      fi
      ;;
    stack-behind)
      stack_manifest_load "$record_stack" "$STACKS" || continue
      [[ "$STACK_MANIFEST_KIND" == built ]] || continue
      local -a converge=()
      IFS=' ' read -r -a converge <<<"$STACK_MANIFEST_CONVERGE"
      [[ -n "${converge[0]:-}" && "${converge[0]}" != /* && "${converge[0]}" != *".."* ]] || continue
      local marker_command="bash @S@/$record_stack/${converge[0]} --only marker"
      [[ "$STACK_MANIFEST_NEEDS_ROOT" != 1 ]] || marker_command="sudo -n $marker_command"
      fix 85 safe "stack $record_stack marker version $version is behind; adopt through its marker phase" "$marker_command"
      ;;
    git-access.sh)
      ((failed > 0)) || continue
      fix 20 safe "refresh ~/.andrusone (script and drift-log.sh); $failed item(s) drifted" \
        "bash @S@/os/common/git-access/git-access.sh --role ${FLEET_GIT_ROLE:-prod}"
      [[ "$failures" == *"user.name"* ]] &&
        fix 21 manual "git identity is not set (git-access cannot choose it for you)" \
          "git config --global user.name \"<name>\" && git config --global user.email \"<email>\""
      ;;
    post-install-baseline-all.sh)
      ((failed > 0)) || continue
      while IFS= read -r f; do
        case "$f" in
        "package "*" is not installed")
          pkg="${f#package }"
          pkg="${pkg% is not installed}"
          fix 41 safe "baseline: package $pkg is not installed" "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg"
          ;;
        "ssh not enabled and active") want_ssh=1 ;;
        "no ufw rule for ssh on "*)
          port="${f#no ufw rule for ssh on }"
          port="${port%/tcp}"
          fix 43 safe "baseline: ufw has no rule for ssh on $port/tcp (adding a rule does not enable ufw)" "sudo ufw allow $port/tcp comment SSH"
          ;;
        "ufw is inactive") ;;
        "qemu-guest-agent not active")
          fix 44 safe "baseline: qemu-guest-agent is not running (its device is present)" "sudo systemctl enable --now qemu-guest-agent"
          ;;
        "SMB credentials file"* | "fstab has no managed SMB block"*) want_mount=1 ;;
        *) want_baseline=1 ;;
        esac
      done < <(split_failures "$failures")
      ;;
    mount-nas.sh)
      ((failed > 0)) && want_mount=1
      ;;
    shell-doctor)
      if ((failed > 0)) || [[ "$version" == unknown ]]; then
        want_shell=1
      fi
      ;;
    python-doctor)
      if ((failed > 0)) || [[ "$version" == unknown ]]; then
        fix 61 safe "python dev box: $( ((failed > 0)) && echo "$failed check(s) failed" || echo "doctor predates the drift log")" "bash @S@/dev-python/bootstrap-python-dev.sh"
      fi
      ;;
    dev-doctor)
      if ((failed > 0)) || [[ "$version" == unknown ]]; then
        fix 62 safe "dev box: $( ((failed > 0)) && echo "$failed check(s) failed" || echo "doctor predates the drift log")" "bash @S@/dev-wails/bootstrap-wails-dev.sh"
      fi
      ;;
    build-core-node.sh)
      ((failed > 0)) || continue
      core_failed=1
      core_n=$((core_n + failed))
      core_text+="$failures"
      ;;
    post-clone-server.sh | post-clone-desktop.sh)
      ((failed > 0)) || continue
      while IFS= read -r f; do
        case "$f" in
        *"ssh service is not enabled"*) want_ssh=1 ;;
        *"required package is not installed: "*)
          pkg="${f##*: }"
          fix 41 safe "validate: package $pkg is not installed" "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg"
          ;;
        *"default editor"* | *"MOTD component is still executable"* | *"homelab-ntp.conf"* | *"default systemd target"* | *"locale"* | *"LANG "*) want_polish=1 ;;
        *"zero-free-space"*) want_zero=1 ;;
        *"shell-doctor is not installed"*) want_shell=1 ;;
        *"qemu-guest-agent is installed but not active"*) ;; # The dedicated guest-agent check offers a safe enable fix when its channel is present.
        *"virtio port is missing"* | *"virtio serial channel is missing"*)
          fix 94 manual "QEMU guest-agent virtio channel is missing on $FLEET_HOST; enable it in Proxmox VM Options and reboot" \
            "# on Proxmox: qm set <vmid> --agent enabled=1 ; then restart the VM"
          ;;
        *"degraded"* | *"units are failed"*) want_units=1 ;;
        *"error-priority"*) want_journal=1 ;;
        *"lock is currently in use"*) apt_dpkg_fix ;;
        *"dpkg"* | *"apt-get check"*) apt_dpkg_fix ;;
        *) fix 96 manual "validate reports something this tool has no fix for: $f" "# investigate: $f; run: post-clone-$KIND.sh --only validate" ;;
        esac
      done < <(split_failures "$failures")
      ;;
    esac
  done <"$file"

  ((want_ssh)) && fix 42 safe "ssh is not enabled at boot (it is running now)" "sudo systemctl enable --now ssh"
  ((want_baseline)) && fix 40 safe "baseline settings differ (apt periodic, journald, logrotate, timers)" "SKIP_SMB=1 bash @S@/os/ubuntu/image/post-install-baseline-all.sh"
  ((want_mount)) && fix 50 safe "NAS mounts: fstab block or credentials differ (live mounts are left alone)" "bash @S@/os/ubuntu/mount-nas.sh --yes --no-remount"
  ((want_shell)) && fix 60 safe "shell tooling is missing or its doctor predates the drift log" "bash @S@/os/ubuntu/bootstrap-shell.sh"
  ((want_polish)) && fix 70 safe "image polish differs (editor, MOTD, NTP config, locale)" "bash @S@/os/ubuntu/image/post-clone-${KIND}.sh --only polish"
  ((want_zero)) && fix 75 safe "the daily zero-free-space job is not installed (first run is the next scheduled time)" "bash @S@/os/ubuntu/image/post-clone-${KIND}.sh --only zero"
  if ((want_vitals)); then
    if vitals_fix_ready; then
      printf -v quoted_binary '%q' "$VITALS_BINARY"
      fix 86 safe "Vitals is missing or unhealthy; converge the pinned observer and restart only its agent" \
        "sudo -n bash @S@/vitals/build-vitals-node.sh --binary $quoted_binary --restart"
    elif stack_manifest_load vitals "$STACKS" >/dev/null &&
      [[ -n "$STACK_MANIFEST_SPEEDTEST_HOST" && "$FLEET_HOST" == "$STACK_MANIFEST_SPEEDTEST_HOST" ]]; then
      fix 87 manual "Vitals repair on $FLEET_HOST also requires the owner-supplied pinned speed-test engine; fleet repair does not distribute or accept its licence" \
        "# Owner: stage the paired release assets and run stacks/vitals/build-vitals-node.sh with --speedtest-binary PATH"
    else
      fix 87 manual "Vitals needs its pinned binary staged and an enrolled token installed before the safe converge can run" \
        "# Owner: stage the pinned binary at $VITALS_BINARY and install this host's enrolled token at $VITALS_TOKEN mode 0600"
    fi
  fi

  if ((core_failed)); then
    # Converging a core node is one all-or-nothing script, so its class is the worst thing it plans.
    # A VRRP secret generated on one node cannot match the peer's (both would claim the VIP); enabling
    # ufw's default-deny or regenerating host keys can lock you out or break trust in the node.
    local risky='generate VRRP auth secret|ufw default|ufw enable|regenerate SSH host keys'
    if [[ "$core_text" =~ $risky ]]; then
      fix 80 unsafe "converge this core node ($core_n item(s)); its plan includes a step that can split the VIP or lock you out" "sudo @S@/core/build-core-node.sh"
    else
      fix 80 safe "converge this core node ($core_n item(s): helper scripts, firewall allows for the peer, service config with validation gates)" "sudo @S@/core/build-core-node.sh"
    fi
  fi

  # Units that are failed right now (what makes systemd "degraded"). motd-news fails because the image
  # polish removes the exec bit from its script; any other unit needs a person to say why.
  if ((want_units)); then
    for u in $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'); do
      case "$u" in
      motd-news.service | motd-news.timer)
        fix 90 safe "motd-news fails (its script is not executable); the image disables MOTD news on purpose" \
          "sudo systemctl mask --now motd-news.timer && sudo systemctl mask --now motd-news.service && { sudo systemctl reset-failed motd-news.timer motd-news.service 2>/dev/null || true; }"
        ;;
      zero-free-space.service)
        # Found on every VM: the unit wraps the script in `flock -n /run/zero-free-space.lock`, and the script
        # then takes the same lock itself, so it always exits "already active". The corrected unit ships with
        # post-clone-*.sh; writing it again fixes the unit, then the failed state can be cleared.
        if grep -qE 'flock -n /run/zero-free-space.lock|ConditionPathIsExecutable' "$ZERO_UNIT_FILE" 2>/dev/null; then
          fix 75 safe "zero-free-space.service can never succeed: its unit locks the same file the script locks, and uses a directive systemd does not have. This writes the corrected unit" \
            "bash @S@/os/ubuntu/image/post-clone-${KIND}.sh --only zero"
          fix 76 safe "clear the failed state now that the unit is corrected" "sudo systemctl reset-failed zero-free-space.service"
        else
          fix 92 manual "$u is failed: find out why before clearing it" "systemctl status $u --no-pager; journalctl -u $u -n 40 --no-pager"
          fix 93 manual "clear the failed state once $u is fixed" "sudo systemctl reset-failed $u"
        fi
        ;;
      *)
        fix 92 manual "$u is failed: find out why before clearing it" "systemctl status $u --no-pager; journalctl -u $u -n 40 --no-pager"
        fix 93 manual "clear the failed state once $u is fixed" "sudo systemctl reset-failed $u"
        ;;
      esac
    done
  fi
  ((want_journal)) && fix 91 manual "error-priority journal entries since boot stay until the next reboot: read them, then reboot when convenient" "sudo journalctl -b -p err --no-pager | tail -n 40"

  # A repository written both as NAME.list (the vendor's instructions) and NAME.sources (the bootstrap scripts) is
  # configured twice, and apt warns about it on every update. No check looks for this, so look at the files.
  local sf nm uri
  for sf in "$APT_SOURCES_DIR"/*.sources; do
    [[ -e "$sf" ]] || continue
    nm="$(basename "$sf" .sources)"
    [[ -f "$APT_SOURCES_DIR/$nm.list" ]] || continue
    uri="$(awk '/^URIs:/ { print $2; exit }' "$sf")"
    if [[ -n "$uri" ]] && grep -qF "$uri" "$APT_SOURCES_DIR/$nm.list" 2>/dev/null; then
      fix 35 safe "apt repository $nm is configured twice ($nm.list and $nm.sources), so apt warns on every update; the .sources file stays" \
        "sudo rm -f $APT_SOURCES_DIR/$nm.list"
    fi
  done

  # Pending package upgrades (only a warning in the baseline check).
  n="$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst ' || true)"
  if ((n > 0)); then
    fix 30 safe "$n package(s) have pending upgrades (what unattended-upgrades does daily, for every origin; never removes a package, never reboots)" \
      "sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get update -q && sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y -q --with-new-pkgs -o Dpkg::Options::=--force-confold upgrade"
  fi
  [[ -e /var/run/reboot-required ]] && fix 97 manual "a reboot is needed for installed updates to take effect: pick a time when this VM's service can go down" "sudo systemctl reboot"

  # Things only a person can judge, found by looking at the machine rather than at a check.
  if sudo -n journalctl -k -b -p err --no-pager -q 2>/dev/null | grep -Eqi "I/O error|ata[0-9.]+: .*(failed command|exception)|Read-error|Write-error"; then
    fix 98 manual "the kernel logged disk I/O errors this boot: check the storage under this VM (Proxmox host, SMART, cable or controller); not fixable from inside the VM" \
      "sudo journalctl -k -b -p err --no-pager | grep -Ei 'I/O error|ata[0-9.]+:' | tail -n 20"
  fi
  # After upgrades, services may still run the old libraries. Fix runs hold needrestart back (see below), so say so.
  if command -v needrestart >/dev/null 2>&1 && sudo -n needrestart -b 2>/dev/null | grep -q '^NEEDRESTART-SVC:'; then
    fix 89 manual "services are running outdated libraries after the upgrades (restarts were held back so nothing was interrupted): restart them when convenient, or reboot" \
      "sudo needrestart -r i"
  fi
  if sudo -n ufw status 2>/dev/null | head -n1 | grep -q inactive; then
    fix 99 unsafe "ufw is inactive; enabling default-deny blocks non-SSH services and requires verified SSH allow rules" \
      "ENABLE_UFW=1 SKIP_SMB=1 bash @S@/os/ubuntu/image/post-install-baseline-all.sh --only firewall"
  fi

  for f in "${PLAN[@]}"; do
    [[ "$f" == *"${TAB}manual${TAB}"* ]] || any=1
  done
  if ((any)); then
    if [[ -d "$REPO/.git" ]]; then
      # Only when this host's checkout is not on the commit the controller is on. (A pull needs this user to be
      # able to read the remote: the dev VMs hold no GitHub key, so there it fails, and the fixes run from the
      # copy shipped with this run anyway.)
      # shellcheck disable=SC2086
      host_head="$(${PRE}git -C "$REPO" rev-parse HEAD 2>/dev/null)"
      # Not again once it has been tried and skipped in this run: it would only sit under "still to do".
      if [[ -z "$PULL_SKIPPED" ]] && [[ -z "$FLEET_HEAD" || "$host_head" != "$FLEET_HEAD" ]]; then
        fix 10 safe "this host's checkout is not on the commit fleet-check ran from; update it" "${PRE}git -C $REPO pull --ff-only"
      fi
    else
      fix 10 manual "this host has no checkout of the network repo" "git clone git@github.com:andrusone/network.git ~/repo/network"
    fi
  fi
}

# emit TAG ENTRY... — print plan entries (order class why command) as TAG lines, in order
emit_plan() {
  local tag="$1" e order class why cmd
  while IFS= read -r e; do
    IFS="$TAB" read -r order class why cmd <<<"$e"
    printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$order" "$class" "$why" "$(show_cmd "$cmd")"
  done < <(printf '%s\n' "${PLAN[@]}" | sort -t "$TAB" -k1,1n -k4,4)
}

# apply_plan MODE — run the fixes this mode allows, in order; one APPLIED line each
apply_plan() {
  local mode="$1" e order class why cmd rc tmo logf note result busy waited
  while IFS= read -r e; do
    IFS="$TAB" read -r order class why cmd <<<"$e"
    result="" rc="-" note=""
    if [[ "$class" == manual ]]; then
      continue
    elif [[ -n "${FAILED_CMDS[$cmd]:-}" ]]; then
      continue # failed in an earlier round: trying it again would only repeat the failure
    elif [[ "$class" == unsafe && "$mode" != all ]]; then
      result=skipped
      note="unsafe: only --apply all runs it"
    else
      # apt and dpkg allow one user at a time. PackageKit and unattended-upgrades hold the lock for minutes
      # on a desktop; wait a little, then defer (not fail) the fixes that need it, so they are tried again
      # by the next run instead of being reported as broken.
      busy=""
      if [[ "$APT_ORDERS" == *" $order "* ]]; then
        waited=0
        while busy="$(apt_busy_text)" && ((waited < APT_WAIT)); do
          ((waited == 0)) && say "WAIT  apt/dpkg is busy ($busy); waiting up to 2 minutes before $(show_cmd "$cmd")"
          sleep 10
          waited=$((waited + 10))
        done
        busy="$(apt_busy_text || true)"
      fi
      if [[ -n "$busy" ]]; then
        result=deferred
        note="apt/dpkg is busy: $busy. Run again when it has finished."
        say "DEFER [$class] $(show_cmd "$cmd"): $note"
      else
        tmo=900
        case "$order" in 30 | 40 | 60 | 61 | 62 | 70 | 75 | 80) tmo=2400 ;; esac
        logf="$WORK/apply.$order.log"
        say "APPLY [$class] $(show_cmd "$cmd")"
        (
          cd "$HOME" || exit 1
          DRIFT_LOG="$WORK/apply.records" timeout -k 10 "$tmo" bash -c "$(real_cmd "$cmd")" </dev/null 2>&1 | tee "$logf" >&2
          exit "${PIPESTATUS[0]}"
        )
        rc=$?
        if ((rc == 0)); then result=ok; else result=failed; fi
        note="$(tail -n 3 "$logf" 2>/dev/null | tr '\t\r\n' '   ' | tr -d '\000-\010\013-\037' | cut -c1-240)"
        # Updating the host's own checkout is a courtesy: every fix ran from the copy shipped with this run. A
        # failed pull (the dev VMs hold no key GitHub accepts) is reported, but it is not a failed fix.
        if [[ "$order" == 10 && "$result" == failed ]]; then
          result=skipped
          PULL_SKIPPED=1
          note="could not update this host's checkout (${note:0:140}); the fixes ran from the shipped copy"
        fi
        [[ "$result" == failed ]] && FAILED_CMDS[$cmd]=1
      fi
    fi
    printf 'APPLIED\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$order" "$class" "$result" "$rc" "$why" "$(show_cmd "$cmd")" "$note"
  done < <(printf '%s\n' "${PLAN[@]}" | sort -t "$TAB" -k1,1n -k4,4)
}

# ================================================================== run
run_checks
suggest_fixes "$OUT1"

cat "$OUT1"
if ((${#PLAN[@]})); then emit_plan FIX; fi

actionable=0
for e in "${PLAN[@]}"; do [[ "$e" == *"${TAB}manual${TAB}"* ]] || actionable=1; done
if [[ "$FLEET_APPLY" != none ]] && ((actionable)); then
  needrestart_guard_on
  round=1
  while :; do
    say "APPLY mode: $FLEET_APPLY (round $round)"
    apply_plan "$FLEET_APPLY"

    # Run every check again and say what is still wrong. Only the last recheck is reported and logged.
    OUT="$WORK/recheck.$round.jsonl"
    say "RECHECK after applying"
    run_checks
    suggest_fixes "$OUT"

    # A fix can bring something up that only the recheck sees (an upgrade starting motd-news, say). Apply once
    # more if something fixable is left that has not already failed; never more than twice.
    again=0
    for e in "${PLAN[@]}"; do
      IFS="$TAB" read -r o_ c_ _ cmd_ <<<"$e"
      [[ "$c_" == safe || ("$c_" == unsafe && "$FLEET_APPLY" == all) ]] || continue # only what this mode would run
      [[ "$o_" != 10 && -z "${FAILED_CMDS[$cmd_]:-}" ]] && again=1
    done
    ((round < 2 && again)) || break
    round=$((round + 1))
  done
  needrestart_guard_off
  while IFS= read -r line; do printf 'RECHECK\t%s\n' "$line"; done <"$OUT"
  if ((${#PLAN[@]})); then emit_plan REMAIN; fi
fi
emit_run_summary
exit 0
