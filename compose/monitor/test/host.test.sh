#!/usr/bin/env bash
# Test for compose/monitor/host.sh (ST264, HL-FR-19 MVP 3). Runs the script with a stub ufw on PATH and a
# temporary MONITOR_ROOT for the files, so no root and no firewall are touched. Checks: the dry run, the first
# run (rules added, DOCKER-USER markers present), the idempotent rerun, a changed LAN, and the exits 2.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host="$here/../host.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/bin"
state="$tmp/state"
log="$tmp/log"
root="$tmp/root"
mkdir -p "$stub" "$state" "$root/etc/ufw" "$root/etc/default"
: > "$log"
printf 'ENABLED=no\n' > "$root/etc/ufw/ufw.conf"
printf 'DEFAULT_INPUT_POLICY="ACCEPT"\n' > "$root/etc/default/ufw"
printf '*filter\n:ufw-before-input - [0:0]\nCOMMIT\n' > "$root/etc/ufw/after.rules"

cat > "$stub/ufw" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  show) cat "$STUB_STATE/ufw-added" 2>/dev/null ;;
  --force) echo "ufw $*" >> "$STUB_LOG"; sed -i 's/^ENABLED=.*/ENABLED=yes/' "$MONITOR_ROOT/etc/ufw/ufw.conf" ;;
  default) echo "ufw $*" >> "$STUB_LOG"; sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' "$MONITOR_ROOT/etc/default/ufw" ;;
  allow) echo "ufw $*" >> "$STUB_LOG"; echo "ufw $*" >> "$STUB_STATE/ufw-added" ;;
  reload) echo "ufw $*" >> "$STUB_LOG" ;;
  *) echo "ufw stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$stub"/*

pass=0
fails=0
check() {
  local name=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    fails=$((fails + 1))
    echo "FAIL: $name"
  fi
}

mutations() { wc -l < "$log"; }

# run_host [args...]: output in $out, exit code in $code. Values come from the variables below.
run_host() {
  set +e
  out=$(env PATH="$stub:/usr/bin:/bin" MONITOR_ROOT="$root" MONITOR_LAN="$lan" MONITOR_ADMIN="$admin" \
    GATUS_PORT=8081 NTFY_PORT=8090 BESZEL_PORT=8091 STUB_STATE="$state" STUB_LOG="$log" bash "$host" "$@" 2>&1)
  code=$?
  set -e
}
lan=192.168.1.0/24
admin=192.168.1.10
after="$root/etc/ufw/after.rules"

# 1. Dry run prints the commands and changes nothing
run_host --dry-run
check "dry run exits 0" [ "$code" -eq 0 ]
check "dry run prints the SSH allow from the admin" grep -qF "+ ufw allow from $admin to any port 22 proto tcp" <<<"$out"
check "dry run prints the Gatus allow from the LAN" grep -qF "+ ufw allow from $lan to any port 8081 proto tcp" <<<"$out"
check "dry run ends with changes" grep -qE '^changes: [1-9][0-9]*$' <<<"$out"
check "dry run left after.rules alone" [ "$(cat "$after")" = "$(printf '*filter\n:ufw-before-input - [0:0]\nCOMMIT')" ]
check "dry run ran no mutating command" [ "$(mutations)" -eq 0 ]

# 2. First run makes the changes
run_host
check "first run exits 0" [ "$code" -eq 0 ]
check "first run ends with changes" grep -qE '^changes: [1-9][0-9]*$' <<<"$out"
check "ufw allows SSH from the admin only" grep -qxF "ufw allow from $admin to any port 22 proto tcp" "$log"
check "ufw allows Gatus from the LAN" grep -qxF "ufw allow from $lan to any port 8081 proto tcp" "$log"
check "ufw allows ntfy from the LAN" grep -qxF "ufw allow from $lan to any port 8090 proto tcp" "$log"
check "ufw allows Beszel from the LAN" grep -qxF "ufw allow from $lan to any port 8091 proto tcp" "$log"
check "ufw default is deny incoming" grep -qxF 'DEFAULT_INPUT_POLICY="DROP"' "$root/etc/default/ufw"
check "ufw is enabled" grep -qx 'ENABLED=yes' "$root/etc/ufw/ufw.conf"
check "after.rules keeps its own section" grep -qxF ':ufw-before-input - [0:0]' "$after"
check "DOCKER-USER block has its markers" [ "$(grep -c '^# BEGIN monitor-host DOCKER-USER (ST264)$' "$after")" -eq 1 ]
check "DOCKER-USER block end marker" grep -qxF '# END monitor-host DOCKER-USER (ST264)' "$after"
check "DOCKER-USER keeps the established return" grep -qxF -- "-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" "$after"
check "DOCKER-USER accepts Gatus from the LAN" grep -qxF -- "-A DOCKER-USER -s $lan -p tcp -m conntrack --ctorigdstport 8081 -j RETURN" "$after"
check "DOCKER-USER accepts ntfy from the LAN" grep -qxF -- "-A DOCKER-USER -s $lan -p tcp -m conntrack --ctorigdstport 8090 -j RETURN" "$after"
check "DOCKER-USER accepts Beszel from the LAN" grep -qxF -- "-A DOCKER-USER -s $lan -p tcp -m conntrack --ctorigdstport 8091 -j RETURN" "$after"
check "DOCKER-USER drops Gatus from everyone else" grep -qxF -- "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 8081 -j DROP" "$after"
check "DOCKER-USER drops Beszel from everyone else" grep -qxF -- "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport 8091 -j DROP" "$after"
check "first run enables ufw, which loads the block" grep -qxF "ufw --force enable" "$log"

# 3. Second run changes nothing
before=$(mutations)
run_host
check "rerun exits 0" [ "$code" -eq 0 ]
check "rerun ends with changes: 0" grep -qx 'changes: 0' <<<"$out"
check "rerun ran no mutating command" [ "$(mutations)" -eq "$before" ]
check "DOCKER-USER block is not duplicated" [ "$(grep -c '^# BEGIN monitor-host DOCKER-USER' "$after")" -eq 1 ]

# 4. A changed LAN replaces the block, and the old LAN is gone from it
lan=10.9.0.0/24
run_host
check "changed LAN exits 0" [ "$code" -eq 0 ]
check "changed LAN rewrites the block" grep -qxF -- "-A DOCKER-USER -s 10.9.0.0/24 -p tcp -m conntrack --ctorigdstport 8081 -j RETURN" "$after"
check "changed LAN leaves no old LAN in the block" [ "$(grep -c -- '-s 192.168.1.0/24' "$after")" -eq 0 ]
check "changed LAN keeps the file's own section" grep -qxF ':ufw-before-input - [0:0]' "$after"
check "changed LAN reloads ufw" grep -qxF 'ufw reload' "$log"
lan=192.168.1.0/24

# 5. Missing and bad values exit 2
set +e
out=$(env -u MONITOR_LAN PATH="$stub:/usr/bin:/bin" MONITOR_ROOT="$root" GATUS_PORT=8081 NTFY_PORT=8090 bash "$host" 2>&1)
code=$?
set -e
check "missing MONITOR_LAN exits 2" [ "$code" -eq 2 ]
check "missing MONITOR_LAN says so" grep -qF 'MONITOR_LAN is not set' <<<"$out"

set +e
out=$(env PATH="$stub:/usr/bin:/bin" MONITOR_ROOT="$root" MONITOR_LAN="$lan" GATUS_PORT=80x NTFY_PORT=8090 bash "$host" 2>&1)
code=$?
set -e
check "a bad GATUS_PORT exits 2" [ "$code" -eq 2 ]
check "a bad GATUS_PORT is named" grep -qF "GATUS_PORT '80x' is not a port number" <<<"$out"

echo "host.test: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
