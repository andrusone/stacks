#!/usr/bin/env bash
# Host firewall for the monitor's VM (ST264, HL-FR-19 MVP 3). ufw is default-deny: SSH from MONITOR_ADMIN
# (default MONITOR_LAN), and GATUS_PORT, NTFY_PORT, BESZEL_PORT (tcp) from MONITOR_LAN. Docker publishes
# around ufw, so the same ports are filtered in DOCKER-USER (/etc/ufw/after.rules), matched on the
# original port (--ctorigdstport). Run as root, values in the environment (setup.sh passes them):
#   sudo compose/monitor/host.sh [--dry-run]
# Each step checks first and changes only what differs. Ends "changes: n"; a rerun ends "changes: 0".
# MONITOR_ROOT (default /) is where /etc/ufw lives; a test sets it and runs without root.
set -euo pipefail

root="${MONITOR_ROOT:-/}"
lan="${MONITOR_LAN:-}"
admin="${MONITOR_ADMIN:-$lan}"
ports=("${GATUS_PORT:-}" "${BESZEL_PORT:-8091}" "${NTFY_PORT:-}")
dry=0
changes=0
after_rules="$root/etc/ufw/after.rules"
begin='# BEGIN monitor-host DOCKER-USER (ST264)'
end='# END monitor-host DOCKER-USER (ST264)'

die() { echo "host.sh: $*" >&2; exit 2; }
[ "${1:-}" != --dry-run ] || { dry=1; shift; }
[ $# -eq 0 ] || die "unknown argument '$1' (only --dry-run)"
[ -n "$lan" ] || die "MONITOR_LAN is not set (a CIDR, for example 192.168.1.0/24)"
[[ $lan =~ ^[0-9.]+(/[0-9]{1,2})?$ ]] || die "MONITOR_LAN '$lan' is not an IPv4 CIDR"
[[ $admin =~ ^[0-9.]+(/[0-9]{1,2})?$ ]] || die "MONITOR_ADMIN '$admin' is not an IPv4 address or CIDR"
names=(GATUS_PORT BESZEL_PORT NTFY_PORT)
for i in 0 1 2; do
  [[ ${ports[i]} =~ ^[0-9]{1,5}$ ]] && [ "${ports[i]}" -le 65535 ] || die "${names[i]} '${ports[i]}' is not a port number"
done
if [ "$root" = / ] && [ "$dry" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then die "run as root (sudo), or add --dry-run"; fi
command -v ufw >/dev/null 2>&1 || die "ufw is missing: the golden image provides it (sudo apt-get install -y ufw)"

# Every machine change goes through here: run it, or print it in a dry run. Both count.
change() {
  local what=$1
  shift
  changes=$((changes + 1))
  echo "[change] $what"
  if [ "$dry" -eq 1 ]; then echo "+ $*"; else "$@"; fi
}

# 1. ufw rules: SSH from the admin address; the three monitor ports from the LAN; default deny in.
ufw_added=$(ufw show added 2>/dev/null || true)
ufw_rule() { grep -qF -- "$*" <<<"$ufw_added" || change "ufw $*" ufw "$@"; }
ufw_rule allow from "$admin" to any port 22 proto tcp
for port in "${ports[@]}"; do ufw_rule allow from "$lan" to any port "$port" proto tcp; done
grep -qs '^DEFAULT_INPUT_POLICY="DROP"' "$root/etc/default/ufw" \
  || change "ufw default deny incoming" ufw default deny incoming

# 2. The same ports in DOCKER-USER: the LAN returns, everyone else is dropped. Established traffic returns.
rules=()
for port in "${ports[@]}"; do rules+=("-A DOCKER-USER -s $lan -p tcp -m conntrack --ctorigdstport $port -j RETURN"); done
for port in "${ports[@]}"; do rules+=("-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $port -j DROP"); done
block=$({
  echo "$begin"
  echo "*filter"
  echo ":DOCKER-USER - [0:0]"
  echo "-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
  printf '%s\n' "${rules[@]}"
  echo "COMMIT"
  echo "$end"
})
existing=$(awk -v b="$begin" -v e="$end" '$0==b{p=1} p{print} $0==e{p=0}' "$after_rules" 2>/dev/null || true)
rules_changed=0
if [ "$existing" != "$block" ]; then
  rewrite_block() {
    local tmp
    tmp=$(mktemp)
    awk -v b="$begin" -v e="$end" '$0==b{p=1} !p{print} $0==e{p=0}' "$after_rules" 2>/dev/null > "$tmp" || true
    printf '%s\n' "$block" >> "$tmp"
    mkdir -p "$(dirname "$after_rules")"
    install -m 0644 "$tmp" "$after_rules"
    rm -f "$tmp"
  }
  change "write the DOCKER-USER block into $after_rules" rewrite_block
  rules_changed=1
fi

# 3. ufw on. Enabling loads the block; a changed block on a running ufw is loaded by a reload.
if grep -qx 'ENABLED=yes' "$root/etc/ufw/ufw.conf" 2>/dev/null; then
  if [ "$rules_changed" -eq 1 ]; then change "reload ufw to load the DOCKER-USER block" ufw reload; fi
else
  change "enable ufw" ufw --force enable
fi

if [ "$dry" -eq 1 ]; then echo "dry run: nothing was changed"; fi
echo "changes: $changes"
