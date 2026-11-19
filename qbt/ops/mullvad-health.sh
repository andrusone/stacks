#!/usr/bin/env bash

set -u
set -o pipefail

# shellcheck disable=SC2034
SCRIPT_VERSION="1.0.0"

#
# mullvad-health.sh
#
# Ensures Mullvad is connected and actually passing Internet traffic.
#
# Usage:
#   mullvad-health.sh
#       Normal health check. If unhealthy, fail over to the next relay.
#
#   mullvad-health.sh --next
#       Force a manual move to the next configured relay, even if the
#       current connection is healthy.
#

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RELAYS=(
  # Chicago - DataPacket
  "us-chi-wg-201"
  "us-chi-wg-202"
  "us-chi-wg-203"

  # Ashburn - Tzulo
  "us-qas-wg-302"
  "us-qas-wg-301"

  # Chicago - Tzulo
  "us-chi-wg-312"
  "us-chi-wg-309"
  "us-chi-wg-311"
  "us-chi-wg-310"

  # Ashburn - DataPacket
  "us-qas-wg-102"
  "us-qas-wg-103"
  "us-qas-wg-101"

  # Third-city reserve
  "us-mkc-wg-101"
)

CONNECT_TIMEOUT=20
HEALTH_TIMEOUT=10
CONNECT_SETTLE_SECONDS=3

HEALTH_URL="https://am.i.mullvad.net/connected"
QBT_MULLVAD_INTERFACE="${QBT_MULLVAD_INTERFACE:-wg0-mullvad}"

LOCK_FILE="${MULLVAD_HEALTH_LOCK_FILE:-/run/mullvad-health.lock}"

# ---------------------------------------------------------------------------
# Runtime diagnostic state
# ---------------------------------------------------------------------------

STATUS_ERROR=""
HEALTH_FAILURE_REASON=""
LAST_WAIT_REASON=""
WAIT_SECONDS=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

#
# systemd already captures stdout/stderr into journald.
#
# When run manually, stdout goes to the terminal and logger sends a copy
# to journald so manual operations are still recorded.
#
log() {
  local level="$1"
  shift

  local message="${level} $*"

  if [[ -n "${INVOCATION_ID:-}" ]]; then
    printf '%s\n' "${message}"
  else
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${message}"
    logger -t mullvad-health -- "${message}"
  fi
}

#
# Collapse diagnostic command output to one line and prevent an unexpected
# response from flooding the journal.
#
single_line() {
  local value="${1:-}"

  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"

  printf '%s' "${value:0:300}"
}

# ---------------------------------------------------------------------------
# Prevent overlapping runs
# ---------------------------------------------------------------------------

exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
  log "WARN" "LOCK: another Mullvad health operation is already running; exiting."
  exit 0
fi

# ---------------------------------------------------------------------------
# Mullvad status helpers
# ---------------------------------------------------------------------------

get_status() {
  mullvad status -v 2>&1
}

is_connected() {
  local status
  local rc

  status="$(get_status)"
  rc=$?

  if ((rc != 0)); then
    STATUS_ERROR="$(single_line "${status}")"
    return 2
  fi

  STATUS_ERROR=""

  grep -q '^Connected' <<<"${status}"
}

get_current_relay() {
  local status

  status="$(get_status)" || return 1

  awk '/^[[:space:]]*Relay:/ {print $2; exit}' <<<"${status}"
}

# ---------------------------------------------------------------------------
# Internet health test
# ---------------------------------------------------------------------------

health_check() {
  local output
  local rc

  HEALTH_FAILURE_REASON=""

  output="$(
    curl \
      --interface "${QBT_MULLVAD_INTERFACE}" \
      --silent \
      --show-error \
      --fail \
      --max-time "${HEALTH_TIMEOUT}" \
      "${HEALTH_URL}" \
      2>&1
  )"
  rc=$?

  if ((rc != 0)); then
    HEALTH_FAILURE_REASON="curl rc=${rc}: $(single_line "${output}")"
    return 1
  fi

  if ! grep -qi 'connected to Mullvad' <<<"${output}"; then
    HEALTH_FAILURE_REASON="unexpected Mullvad response: $(single_line "${output}")"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------

wait_for_connection() {
  local started="${SECONDS}"
  local status_rc

  LAST_WAIT_REASON="Mullvad never reported Connected."
  WAIT_SECONDS=0

  while ((SECONDS - started < CONNECT_TIMEOUT)); do

    if is_connected; then
      sleep "${CONNECT_SETTLE_SECONDS}"

      if health_check; then
        WAIT_SECONDS=$((SECONDS - started))
        return 0
      fi

      LAST_WAIT_REASON="Mullvad reported Connected, but tunnel health failed: ${HEALTH_FAILURE_REASON}"

    else
      status_rc=$?

      if ((status_rc == 2)); then
        LAST_WAIT_REASON="unable to query Mullvad status: ${STATUS_ERROR}"
      else
        LAST_WAIT_REASON="Mullvad has not reported Connected yet."
      fi
    fi

    sleep 1
  done

  WAIT_SECONDS=$((SECONDS - started))
  return 1
}

connect_current_selection() {
  local reason="$1"
  local output
  local rc
  local relay

  log "INFO" "CONNECT: requested; reason=${reason}."

  output="$(mullvad connect 2>&1)"
  rc=$?

  if ((rc != 0)); then
    log "WARN" "CONNECT: mullvad connect returned rc=${rc}: $(single_line "${output}")"
  fi

  if wait_for_connection; then
    relay="$(get_current_relay 2>/dev/null || true)"

    log "INFO" \
      "CONNECT: healthy after ${WAIT_SECONDS}s${relay:+ via ${relay}}."

    return 0
  fi

  log "ERROR" \
    "CONNECT: failed after ${WAIT_SECONDS}s; ${LAST_WAIT_REASON}"

  return 1
}

disconnect_mullvad() {
  local reason="$1"
  local output
  local rc

  log "INFO" "DISCONNECT: requested; reason=${reason}."

  output="$(mullvad disconnect 2>&1)"
  rc=$?

  if ((rc != 0)); then
    log "WARN" \
      "DISCONNECT: mullvad disconnect returned rc=${rc}: $(single_line "${output}")"
    return 1
  fi

  return 0
}

set_relay() {
  local relay="$1"
  local output
  local rc

  log "INFO" "RELAY: selecting ${relay}."

  output="$(mullvad relay set location "${relay}" 2>&1)"
  rc=$?

  if ((rc != 0)); then
    log "ERROR" \
      "RELAY: unable to select ${relay}; rc=${rc}: $(single_line "${output}")"
    return 1
  fi

  return 0
}

find_next_relay() {
  local current="$1"
  local i

  for i in "${!RELAYS[@]}"; do
    if [[ "${RELAYS[$i]}" == "${current}" ]]; then
      echo "${RELAYS[$(((i + 1) % ${#RELAYS[@]}))]}"
      return 0
    fi
  done

  echo "${RELAYS[0]}"
}

# ---------------------------------------------------------------------------
# Manual relay rotation
# ---------------------------------------------------------------------------

force_next_relay() {
  local current=""
  local next=""
  local actual=""
  local status_rc

  if is_connected; then
    current="$(get_current_relay 2>/dev/null || true)"
  else
    status_rc=$?

    if ((status_rc == 2)); then
      log "WARN" \
        "MANUAL: unable to determine current Mullvad state: ${STATUS_ERROR}"
    fi
  fi

  next="$(find_next_relay "${current}")"

  if [[ -n "${current}" ]]; then
    log "INFO" "MANUAL: relay rotation requested: ${current} -> ${next}."
  else
    log "INFO" "MANUAL: relay rotation requested; selecting ${next}."
  fi

  disconnect_mullvad "manual relay rotation to ${next}" || true
  sleep 1

  if ! set_relay "${next}"; then
    log "ERROR" "MANUAL: relay rotation aborted; unable to select ${next}."
    return 1
  fi

  if connect_current_selection "manual relay rotation to ${next}"; then
    actual="$(get_current_relay 2>/dev/null || true)"

    if [[ "${actual}" == "${next}" ]]; then
      log "INFO" \
        "MANUAL: relay rotation successful: ${current:-none} -> ${actual}."
      return 0
    fi

    log "ERROR" \
      "MANUAL: requested ${next}, but connected to ${actual:-unknown}."
    return 1
  fi

  log "ERROR" \
    "MANUAL: relay ${next} failed health verification."

  return 1
}

# ---------------------------------------------------------------------------
# Command-line handling
# ---------------------------------------------------------------------------

case "${1:-}" in
"") ;;

--next)
  force_next_relay
  exit $?
  ;;

--help | -h)
  cat <<EOF
Usage:
  $0
      Check Mullvad health and automatically fail over if necessary.

  $0 --next
      Force connection to the next relay in the configured RELAYS list.

  $0 --help
      Show this help.
EOF
  exit 0
  ;;

*)
  echo "Unknown option: $1" >&2
  echo "Use --help for usage." >&2
  exit 2
  ;;
esac

# ---------------------------------------------------------------------------
# Normal health-check mode
# ---------------------------------------------------------------------------

log "INFO" "HEALTH: starting Mullvad health check."

CURRENT_RELAY=""
STATUS_RC=0

#
# Case 1:
# Mullvad reports connected.
#
if is_connected; then
  CURRENT_RELAY="$(get_current_relay 2>/dev/null || true)"

  if health_check; then
    log "INFO" \
      "HEALTH: connection healthy${CURRENT_RELAY:+ via ${CURRENT_RELAY}}."
    exit 0
  fi

  log "WARN" \
    "HEALTH: Mullvad reports connected${CURRENT_RELAY:+ via ${CURRENT_RELAY}}, but tunnel health failed; ${HEALTH_FAILURE_REASON}"

else
  STATUS_RC=$?

  #
  # Case 2:
  # Status query worked and Mullvad reports disconnected.
  #
  if ((STATUS_RC == 1)); then
    log "WARN" "HEALTH: Mullvad reports disconnected."

    if connect_current_selection "health check found Mullvad disconnected"; then
      exit 0
    fi

    CURRENT_RELAY=""

  #
  # Case 3:
  # Unable to query Mullvad at all.
  #
  else
    log "WARN" \
      "HEALTH: unable to query Mullvad status; ${STATUS_ERROR}"

    if connect_current_selection "Mullvad status query failed"; then
      exit 0
    fi

    CURRENT_RELAY=""
  fi
fi

# ---------------------------------------------------------------------------
# Existing connection is unusable.
# Rotate through preferred relays.
# ---------------------------------------------------------------------------

log "WARN" \
  "FAILOVER: beginning relay failover${CURRENT_RELAY:+; current relay=${CURRENT_RELAY}}."

START_INDEX=0

if [[ -n "${CURRENT_RELAY}" ]]; then
  for i in "${!RELAYS[@]}"; do
    if [[ "${RELAYS[$i]}" == "${CURRENT_RELAY}" ]]; then
      START_INDEX=$(((i + 1) % ${#RELAYS[@]}))
      break
    fi
  done
fi

disconnect_mullvad "preparing for automatic relay failover" || true
sleep 1

for ((attempt = 0; attempt < ${#RELAYS[@]}; attempt++)); do

  INDEX=$(((START_INDEX + attempt) % ${#RELAYS[@]}))
  RELAY="${RELAYS[$INDEX]}"
  ATTEMPT_NUMBER=$((attempt + 1))

  log "INFO" \
    "FAILOVER: attempt ${ATTEMPT_NUMBER}/${#RELAYS[@]}; trying ${RELAY}."

  if ! set_relay "${RELAY}"; then
    continue
  fi

  #
  # Make sure any existing tunnel is torn down before connecting to the
  # newly selected relay.
  #
  disconnect_mullvad \
    "switching to failover relay ${RELAY}" ||
    true

  sleep 1

  if connect_current_selection \
    "automatic failover attempt ${ATTEMPT_NUMBER}/${#RELAYS[@]} using ${RELAY}"; then
    ACTUAL_RELAY="$(get_current_relay 2>/dev/null || true)"

    if [[ "${ACTUAL_RELAY}" == "${RELAY}" ]]; then
      log "INFO" \
        "FAILOVER: successful using ${ACTUAL_RELAY}."
    else
      log "WARN" \
        "FAILOVER: connection healthy, but requested ${RELAY} and actual relay is ${ACTUAL_RELAY:-unknown}."
    fi

    exit 0
  fi

  log "WARN" \
    "FAILOVER: relay ${RELAY} failed health verification."
done

log "ERROR" \
  "FAILOVER: no configured Mullvad relay passed the health check."

exit 1
