#!/usr/bin/env bash
# Host setup for the core VM (ST214, CORE-FR-05 MVP 2). chrony serves time to CORE_LAN only.
# ufw is default-deny: DNS (53 tcp/udp) and NTP (123/udp) from CORE_LAN, SSH from CORE_ADMIN.
# The same allows go into DOCKER-USER (/etc/ufw/after.rules), so Docker-published ports obey them.
# Run as root: sudo compose/core-vm/host.sh [--dry-run]. Each step checks first and changes only
# what differs. Ends "changes: n"; a second run ends "changes: 0". A missing value or no apt exits 2.
# CORE_ROOT (default /) is where the two files live; a test sets it and runs without root.
set -euo pipefail

root="${CORE_ROOT:-/}"
lan="${CORE_LAN:-}"
admin="${CORE_ADMIN:-}"
dry=0
changes=0
chrony_conf="$root/etc/chrony/conf.d/core-lan.conf"
after_rules="$root/etc/ufw/after.rules"
begin='# BEGIN core-host DOCKER-USER (ST214)'
end='# END core-host DOCKER-USER (ST214)'

die() { echo "host.sh: $*" >&2; exit 2; }
fail() { echo "host.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    *) die "unknown argument '$1' (only --dry-run)" ;;
  esac
  shift
done

valid_net() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; }
[ -n "$lan" ] || die "CORE_LAN is not set (a CIDR, for example 192.168.1.0/24)"
[ -n "$admin" ] || die "CORE_ADMIN is not set (a CIDR or address)"
valid_net "$lan" || die "CORE_LAN '$lan' is not an IPv4 CIDR"
valid_net "$admin" || die "CORE_ADMIN '$admin' is not an IPv4 address or CIDR"
if [ "$root" = / ] && [ "$dry" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  die "run as root (sudo), or add --dry-run"
fi
command -v apt-get >/dev/null 2>&1 || die "no apt-get: this script needs an Ubuntu machine with apt"

# Every machine change goes through here: run it, or print it in a dry run. Both count.
change() {
  local what=$1
  shift
  changes=$((changes + 1))
  echo "[change] $what"
  if [ "$dry" -eq 1 ]; then echo "+ $*"; else "$@"; fi
}

write_file() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1"; }
differs() { [ "$(cat "$1" 2>/dev/null || true)" != "$2" ]; }

# 1. Packages
missing=()
for pkg in chrony ufw; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
  change "install ${missing[*]}" sh -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${missing[*]}"
fi

# 2. chrony serves the LAN only (bindcmdaddress and the rest stay default)
grep -qs '^confdir /etc/chrony/conf.d' "$root/etc/chrony/chrony.conf" \
  || fail "$root/etc/chrony/chrony.conf has no 'confdir /etc/chrony/conf.d' line; core-lan.conf would be ignored"
chrony_want="# Written by compose/core-vm/host.sh (ST214). Serve time to the LAN only.
allow $lan"
chrony_changed=0
if differs "$chrony_conf" "$chrony_want"; then
  change "write $chrony_conf (allow $lan)" write_file "$chrony_conf" "$chrony_want"
  chrony_changed=1
fi

# 3. ufw rules and default policy
ufw_added=$(ufw show added 2>/dev/null || true)
ufw_rule() {
  grep -qF -- "$*" <<<"$ufw_added" || change "ufw $*" ufw "$@"
}
ufw_rule allow from "$lan" to any port 53 proto tcp
ufw_rule allow from "$lan" to any port 53 proto udp
ufw_rule allow from "$lan" to any port 123 proto udp
ufw_rule allow from "$admin" to any port 22 proto tcp
grep -qs '^DEFAULT_INPUT_POLICY="DROP"' "$root/etc/default/ufw" \
  || change "ufw default deny incoming" ufw default deny incoming

# 4. The same allows in DOCKER-USER, so a published port is filtered as well
block="$begin
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -s $lan -p tcp --dport 53 -j RETURN
-A DOCKER-USER -s $lan -p udp -m multiport --dports 53,123 -j RETURN
-A DOCKER-USER -p tcp --dport 53 -j DROP
-A DOCKER-USER -p udp -m multiport --dports 53,123 -j DROP
COMMIT
$end"
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

# 5. ufw on, chrony running and restarted when its config changed
if grep -qx 'ENABLED=yes' "$root/etc/ufw/ufw.conf" 2>/dev/null; then
  if [ "$rules_changed" -eq 1 ]; then change "reload ufw to load the DOCKER-USER block" ufw reload; fi
else
  change "enable ufw" ufw --force enable
fi
systemctl is-active --quiet chrony || change "start chrony" systemctl enable --now chrony
if [ "$chrony_changed" -eq 1 ]; then change "restart chrony" systemctl restart chrony; fi

if [ "$dry" -eq 1 ]; then echo "dry run: nothing was changed"; fi
echo "changes: $changes"
