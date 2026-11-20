# shellcheck shell=bash
# -----------------------------------------------------------------------------
# backup-receipt.sh
#
# Sourced helper for append-only backup and restore-test receipts.
# -----------------------------------------------------------------------------

[[ -n "${BACKUP_RECEIPT_LOADED:-}" ]] && return 0
BACKUP_RECEIPT_LOADED=1
# shellcheck disable=SC2034
BACKUP_RECEIPT_LIB_VERSION="1.0.1"
BACKUP_RECEIPTS_SYSTEM="/var/lib/backup-receipts/receipts.jsonl"

_backup_receipt_warn() {
  printf 'backup-receipt: %s\n' "$*" >&2 || true
}

_backup_receipt_target() {
  local f="${BACKUP_RECEIPTS_LOG:-}" state_home
  if [[ -n "$f" ]]; then
    mkdir -p -- "$(dirname -- "$f")" 2>/dev/null || true
    printf '%s' "$f"
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    if install -d -m 755 "$(dirname "$BACKUP_RECEIPTS_SYSTEM")" 2>/dev/null; then
      printf '%s' "$BACKUP_RECEIPTS_SYSTEM"
      return 0
    fi
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if sudo -n install -d -m 755 "$(dirname "$BACKUP_RECEIPTS_SYSTEM")" 2>/dev/null; then
      printf '%s' "$BACKUP_RECEIPTS_SYSTEM"
      return 0
    fi
  fi

  if [[ -n "${XDG_STATE_HOME:-}" ]]; then
    state_home="$XDG_STATE_HOME"
  elif [[ -n "${HOME:-}" ]]; then
    state_home="$HOME/.local/state"
  else
    return 1
  fi
  f="${state_home}/backup-receipts/receipts.jsonl"
  mkdir -p -- "$(dirname -- "$f")" 2>/dev/null || return 1
  printf '%s' "$f"
}

backup_receipt_record() {
  local record_type="" host="" stack="" archive_class="" recovery_group=""
  local artifact_path="" bytes="" sha256="" result="" duration_seconds="" warning=""
  local artifact_restored="" outcome="" encrypted="" timestamp="" file="" line=""

  while (($#)); do
    case "$1" in
    --type | --host | --stack | --archive-class | --recovery-group | --artifact-path | --bytes | --sha256 | --result | --duration-seconds | --artifact-restored | --outcome | --warning | --encrypted)
      if (($# < 2)); then
        _backup_receipt_warn "missing value for $1"
        return 0
      fi
      case "$1" in
      --type) record_type="$2" ;;
      --host) host="$2" ;;
      --stack) stack="$2" ;;
      --archive-class) archive_class="$2" ;;
      --recovery-group) recovery_group="$2" ;;
      --artifact-path) artifact_path="$2" ;;
      --bytes) bytes="$2" ;;
      --sha256) sha256="$2" ;;
      --result) result="$2" ;;
      --duration-seconds) duration_seconds="$2" ;;
      --artifact-restored) artifact_restored="$2" ;;
      --outcome) outcome="$2" ;;
      --warning) warning="$2" ;;
      --encrypted) encrypted="$2" ;;
      esac
      shift 2
      ;;
    *)
      _backup_receipt_warn "unknown argument"
      return 0
      ;;
    esac
  done

  if [[ ! "$record_type" =~ ^(backup|restore_test)$ ||
    -z "$host" || -z "$stack" || ! "$archive_class" =~ ^(cloud|local|none)$ ||
    -z "$recovery_group" || ! "$bytes" =~ ^[0-9]+$ ||
    ! "$duration_seconds" =~ ^[0-9]+$ || ! "$result" =~ ^(ok|failed)$ ||
    (-n "$encrypted" && ! "$encrypted" =~ ^(true|false)$) ||
    (-n "$sha256" && ! "$sha256" =~ ^[[:xdigit:]]{64}$) ]]; then
    _backup_receipt_warn "invalid or incomplete receipt fields"
    return 0
  fi
  if [[ "$record_type" == restore_test && (-z "$artifact_restored" || -z "$outcome") ]]; then
    _backup_receipt_warn "restore_test requires --artifact-restored and --outcome"
    return 0
  fi
  if [[ "$record_type" == restore_test && -z "$artifact_path" ]]; then
    _backup_receipt_warn "restore_test requires --artifact-path"
    return 0
  fi
  if [[ "$record_type" == restore_test && -n "$warning" ]]; then
    _backup_receipt_warn "--warning is only valid for backup receipts"
    return 0
  fi
  if [[ "$result" == ok && (-z "$artifact_path" || ! "$sha256" =~ ^[[:xdigit:]]{64}$) ]]; then
    _backup_receipt_warn "successful receipt requires an artifact path and SHA-256"
    return 0
  fi

  if ! timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
    _backup_receipt_warn "could not determine receipt timestamp"
    return 0
  fi
  if ! line="$(
    python3 - "$timestamp" "$record_type" "$host" "$stack" "$archive_class" "$recovery_group" \
      "$artifact_path" "$bytes" "$sha256" "$result" "$duration_seconds" "$artifact_restored" "$outcome" "$warning" "$encrypted" <<'PY'
import json
import sys

(
    timestamp,
    record_type,
    host,
    stack,
    archive_class,
    recovery_group,
    artifact_path,
    byte_count,
    sha256,
    result,
    duration_seconds,
    artifact_restored,
    outcome,
    warning,
    encrypted,
) = sys.argv[1:]

record = {
    "ts": timestamp,
    "type": record_type,
    "host": host,
    "stack": stack,
    "archive_class": archive_class,
    "recovery_group": recovery_group,
    "artifact_path": artifact_path,
    "bytes": int(byte_count),
    "sha256": sha256.lower(),
    "result": result,
    "duration_seconds": int(duration_seconds),
}
if record_type == "restore_test":
    record["artifact_restored"] = artifact_restored
    record["outcome"] = outcome
if warning:
    record["warning"] = warning
if encrypted:
    record["encrypted"] = encrypted == "true"
print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
PY
  )"; then
    _backup_receipt_warn "could not encode receipt as JSON"
    return 0
  fi

  if ! file="$(_backup_receipt_target 2>/dev/null)"; then
    _backup_receipt_warn "no writable receipt location"
    return 0
  fi
  if [[ -w "$file" || (! -e "$file" && -w "$(dirname -- "$file")") ]]; then
    if printf '%s\n' "$line" >>"$file" 2>/dev/null; then
      return 0
    fi
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if printf '%s\n' "$line" | sudo -n tee -a "$file" >/dev/null 2>&1; then
      return 0
    fi
  fi
  _backup_receipt_warn "could not append receipt; record was not written"
  return 0
}
