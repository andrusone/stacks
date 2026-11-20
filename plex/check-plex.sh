#!/usr/bin/env bash
# Read-only health checks for Plex and the embedded plexcurator database.
set -uo pipefail
SCRIPT_VERSION="1.0.5"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DRIFT_LIB="$SCRIPT_DIR/../os/common/drift/drift-log.sh"
if [[ ! -r "$DRIFT_LIB" ]]; then
  echo "check-plex.sh: missing drift library: $DRIFT_LIB" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$DRIFT_LIB"

CONFIG="/etc/plexcurator/config.toml"
INSTALL_DIR="/opt/plexcurator"
APPDATA="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
RECEIPTS_LOG="${BACKUP_RECEIPTS_LOG:-/var/lib/backup-receipts/receipts.jsonl}"
MARKER="${ANDRUSONE_MARKER_PATH:-${ANDRUSONE_ETC:-/etc}/andrusone/stacks/plex}"
KOMETA_CONFIG="/etc/kometa/config.yml"
SHARES=()

usage() {
  echo "Usage: check-plex.sh [--check] [--config FILE] [--install-dir DIR] [--appdata DIR] [--backup-receipts FILE] [--marker FILE] [--kometa-config FILE] [--share DIR ...]"
}

while (($#)); do
  case "$1" in
  --check) ;;
  --config | --install-dir | --appdata | --backup-receipts | --marker | --kometa-config | --share)
    option="$1"
    shift
    (($#)) || {
      usage >&2
      exit 2
    }
    case "$option" in
    --config) CONFIG="$1" ;;
    --install-dir) INSTALL_DIR="$1" ;;
    --appdata) APPDATA="$1" ;;
    --backup-receipts) RECEIPTS_LOG="$1" ;;
    --marker) MARKER="$1" ;;
    --kometa-config) KOMETA_CONFIG="$1" ;;
    --share) SHARES+=("$1") ;;
    esac
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "check-plex.sh: unknown option: $1" >&2
    usage >&2
    exit 2
    ;;
  esac
  shift
done

args=(--config "$CONFIG" --install-dir "$INSTALL_DIR" --appdata "$APPDATA" --backup-receipts "$RECEIPTS_LOG" --marker "$MARKER" --kometa-config "$KOMETA_CONFIG")
for share in "${SHARES[@]}"; do args+=(--share "$share"); done

output="$(python3 "$SCRIPT_DIR/check-plex.py" "${args[@]}" 2>&1)"
status=$?
printf '%s\n' "$output"
passed="$(grep -c '^PASS  ' <<<"$output" || true)"
failed="$(grep -c '^FAIL  ' <<<"$output" || true)"
warned="$(grep -c '^WARN  ' <<<"$output" || true)"
failures="$(sed -n 's/^FAIL  \([^:]*\).*/\1/p' <<<"$output" | paste -sd'|' -)"
if ((status != 0 && failed == 0)); then
  echo "check-plex.sh: health checker could not complete" >&2
  failed=1
  failures="health checker could not complete"
fi
drift_record check-plex.sh "$SCRIPT_VERSION" "$passed" "$failed" \
  --mode check --stack plex --warned "$warned" --failures "$failures"
((status == 0 && failed == 0))
