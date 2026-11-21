#!/usr/bin/env bash
# Test for compose/core-vm/host.sh (ST214, CORE-FR-05 MVP 2). Runs the script with stubbed
# dpkg-query, apt-get, ufw and systemctl on PATH, and a temporary CORE_ROOT for the files.
# Checks the dry run, the first run, the idempotent rerun, a changed CORE_LAN, a CORE_PEER (ST223), and the exits 2.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
host="$here/../host.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/bin"
state="$tmp/state"
log="$tmp/log"
root="$tmp/root"
mkdir -p "$stub" "$state" "$root/etc/chrony" "$root/etc/ufw" "$root/etc/default"
: > "$log"
printf 'confdir /etc/chrony/conf.d\npool ntp.ubuntu.com iburst\n' > "$root/etc/chrony/chrony.conf"
printf 'ENABLED=no\n' > "$root/etc/ufw/ufw.conf"
printf 'DEFAULT_INPUT_POLICY="ACCEPT"\n' > "$root/etc/default/ufw"
printf '*filter\n:ufw-before-input - [0:0]\nCOMMIT\n' > "$root/etc/ufw/after.rules"

cat > "$stub/dpkg-query" <<'EOF'
#!/usr/bin/env bash
grep -qx "$3" "$STUB_STATE/installed" 2>/dev/null && echo "install ok installed" || exit 1
EOF
cat > "$stub/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_LOG"
if [ "$1" = install ]; then shift; for p in "$@"; do [ "$p" = -y ] || [ "$p" = -qq ] || echo "$p" >> "$STUB_STATE/installed"; done; fi
EOF
cat > "$stub/ufw" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  show) cat "$STUB_STATE/ufw-added" 2>/dev/null ;;
  --force) echo "ufw $*" >> "$STUB_LOG"; sed -i 's/^ENABLED=.*/ENABLED=yes/' "$CORE_ROOT/etc/ufw/ufw.conf" ;;
  default) echo "ufw $*" >> "$STUB_LOG"; sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/' "$CORE_ROOT/etc/default/ufw" ;;
  allow) echo "ufw $*" >> "$STUB_LOG"; echo "ufw $*" >> "$STUB_STATE/ufw-added" ;;
  reload) echo "ufw $*" >> "$STUB_LOG" ;;
  *) echo "ufw stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$stub/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-active) [ -e "$STUB_STATE/chrony-active" ] ;;
  enable) echo "systemctl $*" >> "$STUB_LOG"; touch "$STUB_STATE/chrony-active" ;;
  restart) echo "systemctl $*" >> "$STUB_LOG" ;;
  *) echo "systemctl stub: unexpected $*" >&2; exit 1 ;;
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

# run_host <CORE_LAN> [args...]: output in $out, exit code in $code
run_host() {
  local lan=$1
  shift
  set +e
  out=$(env PATH="$stub:/usr/bin:/bin" CORE_ROOT="$root" CORE_LAN="$lan" CORE_ADMIN=192.168.1.10 \
    CORE_PEER="$peer" STUB_STATE="$state" STUB_LOG="$log" bash "$host" "$@" 2>&1)
  code=$?
  set -e
}
mutations() { wc -l < "$log"; }
lan=192.168.1.0/24
peer=

# 1. Dry run prints the commands and changes nothing
run_host "$lan" --dry-run
check "dry run exits 0" [ "$code" -eq 0 ]
check "dry run prints the ufw allow for DNS" grep -qF "+ ufw allow from $lan to any port 53 proto tcp" <<<"$out"
check "dry run prints the chrony file" grep -qF "+ write_file $root/etc/chrony/conf.d/core-lan.conf" <<<"$out"
check "dry run ends with changes" grep -qE '^changes: [1-9][0-9]*$' <<<"$out"
check "dry run wrote no chrony file" [ ! -e "$root/etc/chrony/conf.d/core-lan.conf" ]
check "dry run left after.rules alone" [ "$(cat "$root/etc/ufw/after.rules")" = "$(printf '*filter\n:ufw-before-input - [0:0]\nCOMMIT')" ]
check "dry run ran no mutating command" [ "$(mutations)" -eq 0 ]

# 2. First real run makes the changes
run_host "$lan"
check "first run exits 0" [ "$code" -eq 0 ]
check "first run ends with changes" grep -qE '^changes: [1-9][0-9]*$' <<<"$out"
check "chrony allows the LAN" grep -qx "allow $lan" "$root/etc/chrony/conf.d/core-lan.conf"
check "chrony opens nothing else" [ "$(grep -c '^allow\|^bind\|^deny' "$root/etc/chrony/conf.d/core-lan.conf")" -eq 1 ]
check "chrony and ufw were installed" grep -qx 'apt-get install -y -qq chrony ufw' "$log"
check "ufw allows DNS tcp from the LAN" grep -qxF "ufw allow from $lan to any port 53 proto tcp" "$log"
check "ufw allows DNS udp from the LAN" grep -qxF "ufw allow from $lan to any port 53 proto udp" "$log"
check "ufw allows NTP from the LAN" grep -qxF "ufw allow from $lan to any port 123 proto udp" "$log"
check "ufw allows SSH from the admin address" grep -qxF "ufw allow from 192.168.1.10 to any port 22 proto tcp" "$log"
check "ufw default is deny incoming" grep -qxF 'DEFAULT_INPUT_POLICY="DROP"' "$root/etc/default/ufw"
check "DOCKER-USER accepts DNS and NTP from the LAN" grep -qxF -- "-A DOCKER-USER -s $lan -p udp -m multiport --dports 53,123 -j RETURN" "$root/etc/ufw/after.rules"
check "DOCKER-USER keeps the established return" grep -qxF -- "-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" "$root/etc/ufw/after.rules"
check "DOCKER-USER drops other DNS and NTP" grep -qxF -- "-A DOCKER-USER -p tcp --dport 53 -j DROP" "$root/etc/ufw/after.rules"
check "after.rules keeps the file's own section" grep -qxF ':ufw-before-input - [0:0]' "$root/etc/ufw/after.rules"
check "ufw is enabled" grep -qx 'ENABLED=yes' "$root/etc/ufw/ufw.conf"
check "chrony is restarted after its config changed" grep -qx 'systemctl restart chrony' "$log"

# 3. Second run changes nothing
before=$(mutations)
run_host "$lan"
check "rerun exits 0" [ "$code" -eq 0 ]
check "rerun ends with changes: 0" grep -qx 'changes: 0' <<<"$out"
check "rerun ran no mutating command" [ "$(mutations)" -eq "$before" ]
check "DOCKER-USER block is not duplicated" [ "$(grep -c '^# BEGIN core-host DOCKER-USER' "$root/etc/ufw/after.rules")" -eq 1 ]

# 4. A changed CORE_LAN replaces the DOCKER-USER block, not adds a second one
run_host 10.9.0.0/24
check "changed LAN exits 0" [ "$code" -eq 0 ]
check "changed LAN rewrites the block" grep -qxF -- "-A DOCKER-USER -s 10.9.0.0/24 -p tcp --dport 53 -j RETURN" "$root/etc/ufw/after.rules"
check "changed LAN leaves no old LAN in the block" [ "$(grep -c -- "-s $lan" "$root/etc/ufw/after.rules")" -eq 0 ]
check "changed LAN reloads ufw" grep -qx 'ufw reload' "$log"

# 5. CORE_PEER opens BIND's 5300 to that peer only, on ufw and in DOCKER-USER; a rerun changes nothing
peer=10.9.0.60
run_host "$lan"
check "peer run exits 0" [ "$code" -eq 0 ]
check "ufw allows 5300/tcp from the peer" grep -qxF "ufw allow from 10.9.0.60 to any port 5300 proto tcp" "$log"
check "ufw allows 5300/udp from the peer" grep -qxF "ufw allow from 10.9.0.60 to any port 5300 proto udp" "$log"
check "no other 5300 allow was added" [ "$(grep -c 'port 5300' "$log")" -eq 2 ]
check "DOCKER-USER accepts 5300/tcp from the peer" grep -qxF -- "-A DOCKER-USER -s 10.9.0.60 -p tcp --dport 5300 -j RETURN" "$root/etc/ufw/after.rules"
check "DOCKER-USER accepts 5300/udp from the peer" grep -qxF -- "-A DOCKER-USER -s 10.9.0.60 -p udp --dport 5300 -j RETURN" "$root/etc/ufw/after.rules"
check "DOCKER-USER drops 5300 from everyone else" grep -qxF -- "-A DOCKER-USER -p udp --dport 5300 -j DROP" "$root/etc/ufw/after.rules"
before=$(mutations)
run_host "$lan"
check "peer rerun ends with changes: 0" grep -qx 'changes: 0' <<<"$out"
check "peer rerun ran no mutating command" [ "$(mutations)" -eq "$before" ]
peer=10.9.0.0/24
run_host "$lan"
check "a peer CIDR exits 2" [ "$code" -eq 2 ]
check "a peer CIDR is named" grep -qF "CORE_PEER '10.9.0.0/24' is not an IPv4 address" <<<"$out"
peer=

# 6. Missing values and no apt exit 2
set +e
out=$(env -u CORE_LAN PATH="$stub:/usr/bin:/bin" CORE_ROOT="$root" CORE_ADMIN=192.168.1.10 bash "$host" 2>&1)
code=$?
set -e
check "missing CORE_LAN exits 2" [ "$code" -eq 2 ]
check "missing CORE_LAN says so" grep -qF 'CORE_LAN is not set' <<<"$out"

nobin="$tmp/nobin"
mkdir -p "$nobin"
ln -s "$(command -v bash)" "$nobin/bash"
set +e
out=$(env PATH="$nobin" CORE_ROOT="$root" CORE_LAN="$lan" CORE_ADMIN=192.168.1.10 "$nobin/bash" "$host" 2>&1)
code=$?
set -e
check "no apt exits 2" [ "$code" -eq 2 ]
check "no apt says so" grep -qF 'no apt-get' <<<"$out"

echo "host.test: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
