# shellcheck shell=bash
# -----------------------------------------------------------------------------
# drift-log.sh
#
# The drift log: one JSON line per script run that checked something, appended to a file that no
# rotation touches. Sourced, never run. Used to measure drift over time (which script, which host,
# how many checks failed, when), and later to drive self-healing.
#
# Usage (after sourcing):
#   drift_record SCRIPT VERSION PASSED FAILED [--warned N] [--fixed N] [--mode MODE] [--failures "a|b|c"] [--host NAME] [--stack ID]
#
#   MODE      run (default) | check | doctor | validate | plan (check-only runs that count steps a
#             real run would take, as failed, with nothing passed) | fleet-check (fleet-check.sh)
#   failures  names of failed checks, "|" separated; the first 20 are kept
#   host      the machine the result is about, when that is not this one (fleet-check.sh)
#   stack     the stack the run belongs to, when known
#
# Line format (JSONL, UTC):
#   {"ts":"2026-10-25T14:03:11Z","host":"vpnx1","script":"build-core-node.sh","version":"1.0.0",
#    "mode":"run","passed":41,"failed":1,"warned":0,"fixed":0,"failures":["haproxy active"],"user":"root"}
#
# Where it goes (DRIFT_LOG overrides):
#   /var/lib/drift-log/drift.jsonl     state, not a log: /var/log is what logrotate and journald manage,
#                                      and nothing in this repo rotates /var/lib/drift-log
#   ~/.local/state/drift-log/drift.jsonl   fallback when neither root nor passwordless sudo is available
# Append-only. Recording never fails the script that calls it (it warns on stderr and returns 0).
#
# Generated doctors run on their own, without this file: they get a copy of drift_record and its
# helpers through `drift_inline_functions` (see bootstrap-common.sh).
# -----------------------------------------------------------------------------

[[ -n "${DRIFT_LOG_LOADED:-}" ]] && return 0
DRIFT_LOG_LOADED=1
# shellcheck disable=SC2034
DRIFT_LOG_LIB_VERSION="1.2.0"

DRIFT_LOG_SYSTEM="/var/lib/drift-log/drift.jsonl"

_drift_json_escape() { # stdin -> JSON string body
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\010\013-\037' | tr '\t' ' ' | tr -d '\r\n'
}

_drift_target() { # prints the file to append to, creating the directory when it can
  local f="${DRIFT_LOG:-}"
  if [[ -n "$f" ]]; then
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf '%s' "$f"
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    install -d -m 755 "$(dirname "$DRIFT_LOG_SYSTEM")" 2>/dev/null && printf '%s' "$DRIFT_LOG_SYSTEM" && return 0
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n install -d -m 755 "$(dirname "$DRIFT_LOG_SYSTEM")" 2>/dev/null && printf '%s' "$DRIFT_LOG_SYSTEM" && return 0
  fi
  f="${XDG_STATE_HOME:-$HOME/.local/state}/drift-log/drift.jsonl"
  mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s' "$f"
}

drift_record() {
  local script="${1:-}" version="${2:-}" passed="${3:-0}" failed="${4:-0}"
  shift 4 2>/dev/null || {
    echo "drift_record: need SCRIPT VERSION PASSED FAILED" >&2
    return 0
  }
  local warned=0 fixed=0 mode=run failures="" host="" stack="" file line f fl="" n=0
  while (($#)); do
    case "$1" in
    --host) host="${2:-}" ;;
    --warned) warned="${2:-0}" ;;
    --fixed) fixed="${2:-0}" ;;
    --mode) mode="${2:-run}" ;;
    --failures) failures="${2:-}" ;;
    --stack) stack="${2:-}" ;;
    esac
    shift 2 || break
  done
  if [[ -n "$failures" ]]; then
    local IFS='|'
    for f in $failures; do
      [[ -n "$f" ]] || continue
      ((n++ < 20)) || break
      fl+="${fl:+,}\"$(printf '%s' "$f" | _drift_json_escape)\""
    done
  fi
  [[ -n "$host" ]] || host="$(hostname -s 2>/dev/null || hostname)"
  if [[ -n "$stack" ]]; then
    line="$(printf '{"ts":"%s","host":"%s","script":"%s","version":"%s","stack":"%s","mode":"%s","passed":%d,"failed":%d,"warned":%d,"fixed":%d,"failures":[%s],"user":"%s"}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$host" | _drift_json_escape)" \
      "$(printf '%s' "$script" | _drift_json_escape)" "$(printf '%s' "$version" | _drift_json_escape)" \
      "$(printf '%s' "$stack" | _drift_json_escape)" "$(printf '%s' "$mode" | _drift_json_escape)" \
      "$passed" "$failed" "$warned" "$fixed" "$fl" "$(id -un 2>/dev/null | _drift_json_escape)")"
  else
    line="$(printf '{"ts":"%s","host":"%s","script":"%s","version":"%s","mode":"%s","passed":%d,"failed":%d,"warned":%d,"fixed":%d,"failures":[%s],"user":"%s"}' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$host" | _drift_json_escape)" \
      "$(printf '%s' "$script" | _drift_json_escape)" "$(printf '%s' "$version" | _drift_json_escape)" \
      "$(printf '%s' "$mode" | _drift_json_escape)" "$passed" "$failed" "$warned" "$fixed" "$fl" \
      "$(id -un 2>/dev/null | _drift_json_escape)")"
  fi
  file="$(_drift_target)" || file=""
  if [[ -z "$file" ]]; then
    echo "drift-log: no writable location; not recorded: $line" >&2
    return 0
  fi
  if [[ -w "$file" || (! -e "$file" && -w "$(dirname "$file")") ]]; then
    printf '%s\n' "$line" >>"$file" 2>/dev/null || echo "drift-log: could not append to $file" >&2
  elif sudo -n true 2>/dev/null; then
    printf '%s\n' "$line" | sudo -n tee -a "$file" >/dev/null 2>&1 || echo "drift-log: could not append to $file" >&2
  else
    echo "drift-log: $file is not writable; not recorded: $line" >&2
  fi
  return 0
}

_drift_history_host_dir() {
  local host="${1:-}" log
  if [[ ! "$host" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "drift_run_summary/detail: invalid host id: ${host:-<empty>}" >&2
    return 1
  fi
  log="${DRIFT_LOG:-}"
  if [[ -z "$log" ]]; then
    log="$(_drift_target)" || {
      echo "drift history: no writable log location" >&2
      return 1
    }
  else
    mkdir -p "$(dirname "$log")" || {
      echo "drift history: cannot create log directory" >&2
      return 1
    }
  fi
  printf '%s/hosts/%s' "$(dirname "$log")" "$host"
}

_drift_history_write_privileged() {
  local action="${1:-}" dir="${2:-}" input="${3:-}"
  if ! command -v sudo >/dev/null 2>&1; then
    echo "drift history: $dir is not writable and sudo is unavailable" >&2
    return 1
  fi
  sudo -n bash -c '
    set -euo pipefail
    action=$1
    dir=$2
    input=$3
    mkdir -p "$dir" || { echo "drift history: cannot create $dir" >&2; exit 1; }
    exec 9>"$dir/.lock" || { echo "drift history: cannot open lock in $dir" >&2; exit 1; }
    flock -x 9 || { echo "drift history: cannot lock $dir" >&2; exit 1; }
    case "$action" in
    summary)
      target="$dir/summary.jsonl"
      combined="$(mktemp "$dir/.summary.XXXXXX")" || exit 1
      trimmed="$(mktemp "$dir/.summary.XXXXXX")" || exit 1
      if [[ -f "$target" ]]; then
        cat -- "$target" >"$combined"
        if [[ -s "$combined" && "$(tail -c 1 "$combined" | wc -l)" -eq 0 ]]; then
          printf "\n" >>"$combined"
        fi
      fi
      printf "%s\n" "$input" >>"$combined"
      tail -n 60 "$combined" >"$trimmed"
      chmod 0644 "$trimmed"
      rm -f -- "$combined"
      mv -f -- "$trimmed" "$target"
      ;;
    detail)
      target="$dir/last-run.jsonl"
      temp="$(mktemp "$dir/.last-run.XXXXXX")" || exit 1
      cat -- "$input" >"$temp"
      chmod 0644 "$temp"
      mv -f -- "$temp" "$target"
      ;;
    *)
      echo "drift history: unknown write type $action" >&2
      exit 1
      ;;
    esac
  ' _ "$action" "$dir" "$input"
}

drift_run_summary() {
  local host="${1:-}" line="${2:-}" dir summary lock_fd combined trimmed status
  if [[ $# -ne 2 || -z "$line" || "$line" == *$'\n'* || "$line" == *$'\r'* ]]; then
    echo "drift_run_summary: need HOST and one summary line" >&2
    return 1
  fi
  dir="$(_drift_history_host_dir "$host")" || return 1
  if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
    _drift_history_write_privileged summary "$dir" "$line" || return 1
    return 0
  fi
  summary="$dir/summary.jsonl"
  (
    exec {lock_fd}>"$dir/.lock" || exit 1
    flock -x "$lock_fd" || {
      echo "drift_run_summary: cannot lock $dir" >&2
      exit 1
    }
    combined="$(mktemp "$dir/.summary.XXXXXX")" || {
      echo "drift_run_summary: cannot create temporary summary" >&2
      exit 1
    }
    trimmed="$(mktemp "$dir/.summary.XXXXXX")" || {
      rm -f -- "$combined"
      echo "drift_run_summary: cannot create trimmed summary" >&2
      exit 1
    }
    if [[ -f "$summary" ]]; then
      cat -- "$summary" >"$combined" || {
        rm -f -- "$combined" "$trimmed"
        echo "drift_run_summary: cannot read existing summary" >&2
        exit 1
      }
      if [[ -s "$combined" && "$(tail -c 1 "$combined" | wc -l)" -eq 0 ]]; then
        printf '\n' >>"$combined" || exit 1
      fi
    fi
    printf '%s\n' "$line" >>"$combined" || {
      rm -f -- "$combined" "$trimmed"
      echo "drift_run_summary: cannot append summary line" >&2
      exit 1
    }
    if ! tail -n 60 "$combined" >"$trimmed" || ! chmod 0644 "$trimmed"; then
      rm -f -- "$combined" "$trimmed"
      echo "drift_run_summary: cannot prepare bounded summary" >&2
      exit 1
    fi
    rm -f -- "$combined"
    if ! mv -f -- "$trimmed" "$summary"; then
      rm -f -- "$trimmed"
      echo "drift_run_summary: cannot replace $summary" >&2
      exit 1
    fi
    flock -u "$lock_fd" || exit 1
    exec {lock_fd}>&-
  )
  status=$?
  return "$status"
}

drift_run_detail() {
  local host="${1:-}" source="${2:-}" dir detail lock_fd temp status
  if [[ $# -ne 2 || -z "$source" || ! -f "$source" || ! -r "$source" ]]; then
    echo "drift_run_detail: need HOST and a readable detail file" >&2
    return 1
  fi
  dir="$(_drift_history_host_dir "$host")" || return 1
  if ! mkdir -p "$dir" 2>/dev/null || [[ ! -w "$dir" ]]; then
    _drift_history_write_privileged detail "$dir" "$source" || return 1
    return 0
  fi
  detail="$dir/last-run.jsonl"
  (
    exec {lock_fd}>"$dir/.lock" || exit 1
    flock -x "$lock_fd" || {
      echo "drift_run_detail: cannot lock $dir" >&2
      exit 1
    }
    temp="$(mktemp "$dir/.last-run.XXXXXX")" || {
      echo "drift_run_detail: cannot create temporary detail file" >&2
      exit 1
    }
    if ! cat -- "$source" >"$temp" || ! chmod 0644 "$temp"; then
      rm -f -- "$temp"
      echo "drift_run_detail: cannot prepare detail file" >&2
      exit 1
    fi
    if ! mv -f -- "$temp" "$detail"; then
      rm -f -- "$temp"
      echo "drift_run_detail: cannot replace $detail" >&2
      exit 1
    fi
    flock -u "$lock_fd" || exit 1
    exec {lock_fd}>&-
  )
  status=$?
  return "$status"
}

# Prints the function definitions a standalone script needs to call drift_record.
drift_inline_functions() {
  declare -p DRIFT_LOG_SYSTEM
  declare -f _drift_json_escape _drift_target drift_record
}
