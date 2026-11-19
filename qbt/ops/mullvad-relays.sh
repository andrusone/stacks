#!/usr/bin/env bash

set -u
set -o pipefail

# shellcheck disable=SC2034
SCRIPT_VERSION="1.0.0"

# WARNING: this manual benchmark disconnects Mullvad when it finishes.
QBT_MULLVAD_INTERFACE="${QBT_MULLVAD_INTERFACE:-wg0-mullvad}"

RELAYS=(
  # Chicago - DataPacket
  "us-chi-wg-201"
  "us-chi-wg-202"
  "us-chi-wg-203"

  # Chicago - Tzulo
  "us-chi-wg-309"
  "us-chi-wg-310"
  "us-chi-wg-311"
  "us-chi-wg-312"

  # Ashburn - DataPacket
  "us-qas-wg-101"
  "us-qas-wg-102"
  "us-qas-wg-103"

  # Ashburn - Tzulo
  "us-qas-wg-301"
  "us-qas-wg-302"

  # Kansas City - Tzulo
  "us-mkc-wg-001"
  "us-mkc-wg-002"

  # Kansas City - HostUniversal
  "us-mkc-wg-101"

  # Boston - HostRoyale
  "us-bos-wg-001"

  # Boston - DataPacket
  "us-bos-wg-101"
  "us-bos-wg-102"

  # Raleigh - Tzulo
  "us-rag-wg-201"
  "us-rag-wg-202"
  "us-rag-wg-203"

  # Atlanta - DataPacket
  "us-atl-wg-001"

  # Atlanta - Tzulo
  "us-atl-wg-401"
  "us-atl-wg-402"
)

PING_TARGET="1.1.1.1"
PING_COUNT=10
CONNECT_TIMEOUT=25

RESULT_FILE="$HOME/mullvad-relay-test-$(date '+%Y%m%d-%H%M%S').txt"

log() {
  echo "$*" | tee -a "$RESULT_FILE"
}

get_actual_relay() {
  mullvad status -v 2>/dev/null |
    awk '/^[[:space:]]*Relay:/ {print $2; exit}'
}

wait_connected() {
  local requested="$1"

  for ((i = 1; i <= CONNECT_TIMEOUT; i++)); do
    status="$(mullvad status -v 2>/dev/null)"

    if grep -q '^Connected' <<<"$status"; then
      actual="$(
        awk '/^[[:space:]]*Relay:/ {print $2; exit}' <<<"$status"
      )"

      if [[ "$actual" == "$requested" ]]; then
        return 0
      fi
    fi

    sleep 1
  done

  return 1
}

check_mullvad() {
  local result

  result="$(
    curl \
      --interface "$QBT_MULLVAD_INTERFACE" \
      --silent \
      --show-error \
      --max-time 10 \
      https://am.i.mullvad.net/connected \
      2>/dev/null
  )" || return 1

  grep -qi 'connected to Mullvad' <<<"$result"
}

get_mullvad_json() {
  curl \
    --interface "$QBT_MULLVAD_INTERFACE" \
    --silent \
    --max-time 10 \
    https://am.i.mullvad.net/json \
    2>/dev/null
}

do_ping_test() {
  ping \
    -I "$QBT_MULLVAD_INTERFACE" \
    -c "$PING_COUNT" \
    -W 2 \
    "$PING_TARGET" \
    2>/dev/null
}

extract_packet_loss() {
  awk -F', ' '/packet loss/ {
        for (i=1; i<=NF; i++) {
            if ($i ~ /packet loss/) {
                print $i
                exit
            }
        }
    }'
}

extract_rtt() {
  awk -F'=' '/min\/avg\/max/ {
        gsub(/ ms/, "", $2)
        gsub(/^ /, "", $2)
        split($2, a, "/")
        printf "%.2f", a[2]
        exit
    }'
}

log "============================================================"
log "Mullvad Relay Test"
log "Started: $(date)"
log "Host: $(hostname)"
log "============================================================"
log ""

printf "%-18s %-8s %-9s %-8s %-10s %-16s\n" \
  "RELAY" "CONNECT" "VERIFIED" "LOSS" "AVG-RTT" "EXIT-IP" |
  tee -a "$RESULT_FILE"

printf "%-18s %-8s %-9s %-8s %-10s %-16s\n" \
  "------------------" "--------" "---------" "--------" "----------" "----------------" |
  tee -a "$RESULT_FILE"

for relay in "${RELAYS[@]}"; do

  CONNECT_RESULT="FAIL"
  VERIFY_RESULT="FAIL"
  LOSS="N/A"
  RTT="N/A"
  EXIT_IP="N/A"

  log ""
  log "------------------------------------------------------------"
  log "Testing: $relay"
  log "------------------------------------------------------------"

  #
  # Disconnect cleanly before selecting another relay.
  #
  mullvad disconnect >/dev/null 2>&1 || true
  sleep 2

  #
  # Select exact endpoint.
  #
  if ! mullvad relay set location "$relay" >>"$RESULT_FILE" 2>&1; then
    log "ERROR: Unable to select relay $relay"

    printf "%-18s %-8s %-9s %-8s %-10s %-16s\n" \
      "$relay" "$CONNECT_RESULT" "$VERIFY_RESULT" "$LOSS" "$RTT" "$EXIT_IP" |
      tee -a "$RESULT_FILE"

    continue
  fi

  #
  # Connect.
  #
  mullvad connect >>"$RESULT_FILE" 2>&1 || true

  if wait_connected "$relay"; then
    CONNECT_RESULT="PASS"
  else
    log "ERROR: Failed to connect to requested relay."
    mullvad status -v >>"$RESULT_FILE" 2>&1

    printf "%-18s %-8s %-9s %-8s %-10s %-16s\n" \
      "$relay" "$CONNECT_RESULT" "$VERIFY_RESULT" "$LOSS" "$RTT" "$EXIT_IP" |
      tee -a "$RESULT_FILE"

    continue
  fi

  sleep 2

  log ""
  log "Mullvad status:"
  mullvad status -v | tee -a "$RESULT_FILE"

  ACTUAL_RELAY="$(get_actual_relay)"

  if [[ "$ACTUAL_RELAY" == "$relay" ]]; then
    log "Requested relay verification: PASS ($ACTUAL_RELAY)"
  else
    log "Requested relay verification: FAIL"
    log "Requested: $relay"
    log "Actual:    $ACTUAL_RELAY"
  fi

  #
  # Mullvad Internet verification.
  #
  if check_mullvad; then
    VERIFY_RESULT="PASS"
    log "Mullvad Internet verification: PASS"
  else
    log "Mullvad Internet verification: FAIL"
  fi

  #
  # Get exit-IP information.
  #
  JSON="$(get_mullvad_json)"

  if [[ -n "$JSON" ]]; then
    log ""
    log "Mullvad API:"
    log "$JSON"

    EXIT_IP="$(
      grep -oE '"ip"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$JSON" |
        head -1 |
        cut -d'"' -f4
    )"

    [[ -z "$EXIT_IP" ]] && EXIT_IP="N/A"
  fi

  #
  # Ping test.
  #
  log ""
  log "Ping test:"

  PING_OUTPUT="$(do_ping_test || true)"

  log "$PING_OUTPUT"

  LOSS="$(
    extract_packet_loss <<<"$PING_OUTPUT"
  )"

  RTT="$(
    extract_rtt <<<"$PING_OUTPUT"
  )"

  [[ -z "$LOSS" ]] && LOSS="N/A"
  [[ -z "$RTT" ]] && RTT="N/A"

  #
  # Summary row.
  #
  printf "%-18s %-8s %-9s %-8s %-10s %-16s\n" \
    "$relay" \
    "$CONNECT_RESULT" \
    "$VERIFY_RESULT" \
    "$LOSS" \
    "$RTT" \
    "$EXIT_IP" |
    tee -a "$RESULT_FILE"

done

log ""
log "============================================================"
log "Test complete: $(date)"
log "Results: $RESULT_FILE"
log "============================================================"

#
# Leave Mullvad disconnected after benchmarking.
#
mullvad disconnect >/dev/null 2>&1 || true

echo
echo "Results written to:"
echo "$RESULT_FILE"
