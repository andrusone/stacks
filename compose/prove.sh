#!/usr/bin/env bash
# Prove the local monitor's alert path (ST59, HL-FR-07 MVP 1). Run after
# mise run monitor-up. For each fault it breaks an answer of probe-a, waits for
# the alert on the local ntfy topic, checks that no answer the fault should not
# touch alerted, undoes the fault and waits for the recovery. Faults are undone
# on exit, Ctrl-C included. Exits 1 if any step fails.
#
# Alert shape (read from a real run): title "Gatus: <group>/<name>", message
# "An alert has been triggered ... description: <name>" (the name is `<stack>: <answer>`, ST90) or
# "An alert has been resolved ...".
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

COMPOSE=(docker compose -f compose/docker-compose.yml)
GATUS_API="http://127.0.0.1:8081/api/v1/endpoints/statuses"
NTFY_TOPIC="${NTFY_TOPIC:-oc8-local}"
NTFY_URL="http://127.0.0.1:8090/${NTFY_TOPIC}/json"
ALERT_WAIT="${ALERT_WAIT:-90}" # seconds to wait for an expected alert or recovery
SETTLE=35                      # Gatus alerts after two failures, checked every 10 s

CID_A=""
NET=""
HOST_DOWN=0
NGINX_DOWN=0
RIGHT_BAD=0
PASSED=0
FAILED=0
ROWS=()
BASELINE_NOTE=""
DEP="probe-b/probe-b: dependencies (probe-a)"

now() { date +%s; }

record() { # step, 1 for pass / 0 for fail, detail, seconds
  local word=FAIL
  if [ "$2" = 1 ]; then
    word=PASS
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  ROWS+=("| $1 | $word | $3 | $4 |")
  echo "$word $1: $3"
}

# alerts_since <unix time>: one "<triggered|resolved> <group>/<name>" per Gatus message on the topic.
alerts_since() {
  curl -fsS --max-time 10 "${NTFY_URL}?poll=1&since=$1" | python3 -c '
import json, sys
for line in sys.stdin:
    if not line.strip():
        continue
    m = json.loads(line)
    title = m.get("title", "")
    if not title.startswith("Gatus: "):
        continue
    body = m.get("message", "")
    if "has been triggered" in body:
        kind = "triggered"
    elif "has been resolved" in body:
        kind = "resolved"
    else:
        kind = "other"
    print(kind, title[len("Gatus: "):])
'
}

# wait_for "<kind> <group>/<name>" <since>: 0 once that message has arrived, 1 after ALERT_WAIT seconds.
wait_for() {
  local deadline=$(( $(now) + ALERT_WAIT )) all
  while [ "$(now)" -lt "$deadline" ]; do
    all=$(alerts_since "$2" 2>/dev/null)
    if grep -qxF "$1" <<<"$all"; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# seen <since> "<line>"...: prints the lines that arrived since then.
seen() {
  local since=$1 all line out=""
  all=$(alerts_since "$since" 2>/dev/null)
  shift
  for line in "$@"; do
    if grep -qxF "$line" <<<"$all"; then
      out="$out $line;"
    fi
  done
  printf '%s' "$out"
}

# count "<line>" <since>: how many times that message arrived.
count() {
  local n
  n=$(alerts_since "$2" 2>/dev/null | grep -cxF "$1") || true
  printf '%s' "${n:-0}"
}

wait_until() {
  while [ "$(now)" -lt "$1" ]; do
    sleep 1
  done
}

# all_up: 0 when every endpoint's last result is a success; prints the ones that are not.
all_up() {
  curl -fsS --max-time 10 "$GATUS_API" | python3 -c '
import json, sys
bad = [e["group"] + "/" + e["name"] for e in json.load(sys.stdin)
       if not (e.get("results") and e["results"][-1]["success"])]
print("; ".join(bad))
sys.exit(1 if bad else 0)
'
}

wait_all_up() {
  local deadline=$(( $(now) + ALERT_WAIT ))
  while [ "$(now)" -lt "$deadline" ]; do
    if BASELINE_NOTE=$(all_up 2>/dev/null); then
      return 0
    fi
    sleep 3
  done
  BASELINE_NOTE=$(all_up 2>/dev/null) || true
  return 1
}

# Faults. Each sets a flag so the trap undoes it if the script stops early.

host_break() {
  docker network disconnect "$NET" "$CID_A" && HOST_DOWN=1
}

host_mend() {
  if [ "$HOST_DOWN" = 1 ]; then
    # The alias matters: without it the compose name probe-a does not resolve again.
    docker network connect --alias probe-a "$NET" "$CID_A" && HOST_DOWN=0
  fi
}

service_break() {
  # nginx is the container's process via sh (compose/docker-compose.yml), so the container stays up.
  docker exec "$CID_A" nginx -s stop && NGINX_DOWN=1
}

service_mend() {
  if [ "$NGINX_DOWN" = 1 ]; then
    docker exec "$CID_A" nginx && NGINX_DOWN=0
  fi
}

right_break() {
  # A default_server that answers 500, written into the container only (conf.d is not a tracked mount).
  docker exec -u root "$CID_A" sh -c "printf '%s\n' 'server { listen 8080 default_server; location / { return 500; } }' > /etc/nginx/conf.d/fault.conf && nginx -s reload" && RIGHT_BAD=1
}

right_mend() {
  if [ "$RIGHT_BAD" = 1 ]; then
    docker exec -u root "$CID_A" sh -c 'rm -f /etc/nginx/conf.d/fault.conf && nginx -s reload' && RIGHT_BAD=0
  fi
}

cleanup() {
  host_mend
  service_mend
  right_mend
  if [ "$HOST_DOWN$NGINX_DOWN$RIGHT_BAD" != "000" ]; then
    echo "WARN: a fault is still in place (host=$HOST_DOWN service=$NGINX_DOWN right=$RIGHT_BAD); undo it by hand" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

precheck() {
  if ! curl -fsS --max-time 10 -o /dev/null "$GATUS_API"; then
    echo "FAIL precheck: Gatus does not answer at $GATUS_API; run mise run monitor-up first"
    return 1
  fi
  if ! curl -fsS --max-time 10 -o /dev/null "${NTFY_URL}?poll=1&since=$(now)"; then
    echo "FAIL precheck: ntfy topic $NTFY_TOPIC does not answer; run mise run monitor-up first"
    return 1
  fi
  CID_A=$("${COMPOSE[@]}" ps -q probe-a)
  if [ -z "$CID_A" ]; then
    echo "FAIL precheck: probe-a is not running; run mise run monitor-up first"
    return 1
  fi
  NET=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CID_A" | awk '{print $1}')
  return 0
}

window_host() {
  local t0 tu a1 a2 r1 r2 bad dups
  if ! wait_all_up; then
    record host 0 "not every answer was up before the fault: $BASELINE_NOTE" 0
    record dependency 0 "not every answer was up before the fault" 0
    return
  fi
  t0=$(now)
  if ! host_break; then
    host_mend
    record host 0 "could not disconnect probe-a from $NET" 0
    record dependency 0 "could not disconnect probe-a from $NET" 0
    return
  fi
  wait_for "triggered probe-a/probe-a: host" "$t0" && a1=$(( $(now) - t0 )) || a1=""
  wait_for "triggered $DEP" "$t0" && a2=$(( $(now) - t0 )) || a2=""
  wait_until $(( t0 + SETTLE ))
  bad=$(seen "$t0" "triggered probe-b/probe-b: host" "triggered probe-b/probe-b: service" "triggered probe-b/probe-b: right answer")
  dups=$(count "triggered probe-a/probe-a: host" "$t0")
  tu=$(now)
  host_mend
  wait_for "resolved probe-a/probe-a: host" "$tu" && r1=$(( $(now) - tu )) || r1=""
  wait_for "resolved $DEP" "$tu" && r2=$(( $(now) - tu )) || r2=""

  if [ -n "$a1" ] && [ -n "$r1" ] && [ -z "$bad" ]; then
    record host 1 "alert for probe-a host after ${a1}s, recovery after ${r1}s, alerts for probe-a host: $dups, no alert for probe-b host/service/right answer" "$a1"
  else
    record host 0 "alert after ${a1:+${a1}s}${a1:-none}, recovery after ${r1:+${r1}s}${r1:-none}, unexpected alerts:${bad:- none}" "${a1:-0}"
  fi
  if [ -n "$a2" ] && [ -n "$r2" ]; then
    record dependency 1 "alert for probe-b dependencies (probe-a) after ${a2}s, recovery after ${r2}s" "$a2"
  else
    record dependency 0 "alert after ${a2:+${a2}s}${a2:-none}, recovery after ${r2:+${r2}s}${r2:-none}" "${a2:-0}"
  fi
}

window_service() {
  local t0 tu a r bad
  if ! wait_all_up; then
    record service 0 "not every answer was up before the fault: $BASELINE_NOTE" 0
    return
  fi
  t0=$(now)
  if ! service_break; then
    service_mend
    record service 0 "could not stop nginx in probe-a" 0
    return
  fi
  wait_for "triggered probe-a/probe-a: service" "$t0" && a=$(( $(now) - t0 )) || a=""
  wait_until $(( t0 + SETTLE ))
  bad=$(seen "$t0" "triggered probe-a/probe-a: host" "triggered probe-b/probe-b: host" "triggered probe-b/probe-b: service" "triggered probe-b/probe-b: right answer")
  tu=$(now)
  service_mend
  wait_for "resolved probe-a/probe-a: service" "$tu" && r=$(( $(now) - tu )) || r=""
  if [ -n "$a" ] && [ -n "$r" ] && [ -z "$bad" ]; then
    record service 1 "alert for probe-a service after ${a}s, recovery after ${r}s, no alert for host answers" "$a"
  else
    record service 0 "alert after ${a:+${a}s}${a:-none}, recovery after ${r:+${r}s}${r:-none}, unexpected alerts:${bad:- none}" "${a:-0}"
  fi
}

window_right() {
  local t0 tu a r bad
  if ! wait_all_up; then
    record right-answer 0 "not every answer was up before the fault: $BASELINE_NOTE" 0
    return
  fi
  t0=$(now)
  if ! right_break; then
    right_mend
    record right-answer 0 "could not make probe-a answer 500" 0
    return
  fi
  wait_for "triggered probe-a/probe-a: right answer" "$t0" && a=$(( $(now) - t0 )) || a=""
  wait_until $(( t0 + SETTLE ))
  bad=$(seen "$t0" "triggered probe-a/probe-a: host" "triggered probe-a/probe-a: service" "triggered probe-b/probe-b: host" "triggered probe-b/probe-b: service" "triggered probe-b/probe-b: right answer" "triggered $DEP")
  tu=$(now)
  right_mend
  wait_for "resolved probe-a/probe-a: right answer" "$tu" && r=$(( $(now) - tu )) || r=""
  if [ -n "$a" ] && [ -n "$r" ] && [ -z "$bad" ]; then
    record right-answer 1 "alert for probe-a right answer after ${a}s, recovery after ${r}s, no other alerts" "$a"
  else
    record right-answer 0 "alert after ${a:+${a}s}${a:-none}, recovery after ${r:+${r}s}${r:-none}, unexpected alerts:${bad:- none}" "${a:-0}"
  fi
}

if ! precheck; then
  exit 1
fi

window_host
window_service
window_right

echo
echo "| step | result | detail | seconds to alert |"
echo "|---|---|---|---|"
printf '%s\n' "${ROWS[@]}"
echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
