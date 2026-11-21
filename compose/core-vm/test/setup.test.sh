#!/usr/bin/env bash
# The setup test (ST218, CORE-FR-10 MVP 2). setup.sh finds its stages and its checkout from its own
# path, so the test copies setup.sh, setup-stages.sh, .env.example and the two units into a temporary
# checkout, with stub host.sh and zone-sync.sh beside them. Stubs on PATH: sudo (runs the command and
# logs it), systemctl (logs the changing calls; the start runs the installed unit's ExecStart), mise,
# docker and apt-get. CORE_ROOT is a temporary root for /etc and for the systemd check.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
src="$here/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
cvm="$repo/compose/core-vm"
root="$tmp/root"
stub="$tmp/bin"
state="$tmp/state"
log="$tmp/log"
zone_copy="$repo/compose/core/bind/zone/db.core.andrusonline.com"
mkdir -p "$cvm/test" "$stub" "$state"
cp "$src/setup.sh" "$src/setup-stages.sh" "$src/.env.example" "$src/zone-sync.service" "$src/zone-sync.timer" "$cvm/"

# The stub host.sh: records its call; the first real run reports a change, a rerun reports none.
cat > "$cvm/host.sh" <<'EOF'
#!/usr/bin/env bash
echo "host.sh args=[$*] LAN=$CORE_LAN ADMIN=$CORE_ADMIN" >> "$STUB_LOG"
if [ -e "$STUB_STATE/host-done" ]; then echo "changes: 0"; exit 0; fi
echo "changes: 1"
if [ "$*" != --dry-run ]; then touch "$STUB_STATE/host-done"; fi
EOF
# The stub zone-sync.sh: writes BIND's copy of the zone from the env file the service reads.
cat > "$cvm/zone-sync.sh" <<'EOF'
#!/usr/bin/env bash
echo "zone-sync.sh stub ran" >> "$STUB_LOG"
mkdir -p "$CORE_ZONE_OUT"
echo "zone copy from $CORE_ZONE_URL" > "$CORE_ZONE_OUT/db.$CORE_ZONE_NAME"
EOF
chmod +x "$cvm/host.sh" "$cvm/zone-sync.sh"

cat > "$stub/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$STUB_LOG"
exec "$@"
EOF
cat > "$stub/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-enabled) [ -e "$STUB_STATE/timer-enabled" ] ;;
  is-active) [ -e "$STUB_STATE/timer-active" ] ;;
  daemon-reload) echo "systemctl daemon-reload" >> "$STUB_LOG" ;;
  enable) echo "systemctl $*" >> "$STUB_LOG"; touch "$STUB_STATE/timer-enabled" "$STUB_STATE/timer-active" ;;
  start)
    echo "systemctl start $2" >> "$STUB_LOG"
    exe="$(sed -n 's/^ExecStart=//p' "$CORE_ROOT/etc/systemd/system/zone-sync.service")"
    (set -a; . "$CORE_ROOT/etc/core/zone-sync.env"; set +a; "$exe")
    ;;
  *) echo "systemctl stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$stub/mise" <<'EOF'
#!/usr/bin/env bash
echo "mise $* CORE_ROLE=$CORE_ROLE" >> "$STUB_LOG"
if [ "$1 $2" = "run core-up" ]; then printf '%s\n' core-bind core-unbound core-chrony > "$STUB_STATE/running"; fi
EOF
cat > "$stub/docker" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_STATE/running" 2>/dev/null || true
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/apt-get"
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

# reset_state: no node yet. The root has the systemd folder unless a test removes it.
reset_state() {
	rm -rf "$root" "${state:?}"/* "$repo/compose/core/bind/zone" "$cvm/.env"
	mkdir -p "$root/run/systemd/system" "$root/etc" "$state"
	: > "$log"
}

# run_setup [bare] [VAR=value ...] -- [setup.sh arguments]: output in $out, exit code in $code. Unless
# "bare" comes first, the node's values are in the environment; the VAR=value words come after them, so
# a test can override any of them. "bare" leaves the values to .env and the defaults.
run_setup() {
	local -a envs=() base=()
	if [ "$1" = bare ]; then shift; else
		base=(CORE_BIND=192.168.1.50 CORE_LAN=192.168.1.0/24 CORE_ADMIN=192.168.1.10
			CORE_ZONE_URL=http://192.168.1.20/zone.git CORE_ROLE=primary CORE_PEER=)
	fi
	while [ "$1" != -- ]; do envs+=("$1"); shift; done
	shift
	set +e
	out="$(env PATH="$stub:/usr/bin:/bin" CORE_ROOT="$root" STUB_STATE="$state" STUB_LOG="$log" \
		"${base[@]}" "${envs[@]}" bash "$cvm/setup.sh" "$@" </dev/null 2>&1)"
	code=$?
	set -e
}

line_of() { grep -n -m1 -F -- "$1" "$log" | cut -d: -f1; }
before_in_log() { local a b; a=$(line_of "$1"); b=$(line_of "$2"); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
# The changing calls. host.sh runs under sudo on every run (it checks first itself), so it is not counted.
mutations() { grep -c -E '^(sudo (install|systemctl)|systemctl |mise )' "$log" || true; }
tree() { find "$repo" "$root" "$state" -print | sort; }

# 1. No systemd: a plain message and exit 2, nothing written
reset_state
rm -rf "$root/run/systemd"
run_setup -- --yes
check "no systemd exits 2" [ "$code" -eq 2 ]
check "no systemd says so" grep -qF 'systemd is not running' <<<"$out"
check "no systemd writes no .env" [ ! -e "$cvm/.env" ]

# 2. Dry run: prints every step, asks nothing, writes nothing
reset_state
tree > "$tmp/before"
run_setup -- --dry-run
check "dry run exits 0" [ "$code" -eq 0 ]
check "dry run prints the env write" grep -qF '[dry-run] would: write' <<<"$out"
check "dry run prints the unit install" grep -qF 'install' <<<"$out"
check "dry run ends with changes" grep -qE '^changes: [1-9][0-9]*$' <<<"$out"
tree > "$tmp/after"
check "dry run changes no file" cmp -s "$tmp/before" "$tmp/after"
check "dry run runs no install, systemctl or mise" [ "$(mutations)" -eq 0 ]
check "dry run calls host.sh in dry-run only" [ -z "$(grep -F 'host.sh args=[] ' "$log" || true)" ]

# 3. The first real run: stage order, values, files
reset_state
run_setup -- --yes
check "first run exits 0" [ "$code" -eq 0 ]
check "first run ends with changes" grep -qE '^changes: [1-9][0-9]*$' <<<"$out"
check ".env holds the values" grep -qx 'CORE_ZONE_URL=http://192.168.1.20/zone.git' "$cvm/.env"
check ".env is mode 600" [ "$(stat -c %a "$cvm/.env")" = 600 ]
check ".env has a comment per value" grep -q '^# CORE_ZONE_URL:' "$cvm/.env"
check "host.sh got the LAN and admin values" grep -qF 'host.sh args=[] LAN=192.168.1.0/24 ADMIN=192.168.1.10' "$log"
check "zone-sync unit runs this checkout's script" grep -qx "ExecStart=$cvm/zone-sync.sh" "$root/etc/systemd/system/zone-sync.service"
check "zone-sync env has the zone values" grep -qx "CORE_ZONE_OUT=$repo/compose/core/bind/zone" "$root/etc/core/zone-sync.env"
check "timer is enabled and started" [ -e "$state/timer-enabled" ] && [ -e "$state/timer-active" ]
check "first zone sync wrote BIND's copy" [ -f "$zone_copy" ]
check "core-up ran with the role" grep -qxF 'mise run core-up CORE_ROLE=primary' "$log"
check "stage order: host.sh first" before_in_log 'host.sh args=' 'systemctl daemon-reload'
check "stage order: units before the timer" before_in_log 'systemctl daemon-reload' 'systemctl enable --now zone-sync.timer'
check "stage order: timer before the first sync" before_in_log 'systemctl enable --now zone-sync.timer' 'systemctl start zone-sync.service'
check "stage order: sync before core-up" before_in_log 'systemctl start zone-sync.service' 'mise run core-up'

# 4. A rerun: no value asked, nothing changed
envsum="$(sha256sum "$cvm/.env")"
before=$(mutations)
run_setup bare -- --yes
check "rerun exits 0" [ "$code" -eq 0 ]
check "rerun ends with changes: 0" grep -qx 'changes: 0' <<<"$out"
check "rerun runs no install, systemctl or mise" [ "$(mutations)" -eq "$before" ]
check "rerun leaves .env as it was" [ "$(sha256sum "$cvm/.env")" = "$envsum" ]

# 5. Values are checked: a name in the zone URL, a LAN without a prefix, a missing zone URL
reset_state
run_setup CORE_ZONE_URL=http://zone.core.andrusonline.com/zone.git -- --yes
check "a name in CORE_ZONE_URL exits 2" [ "$code" -eq 2 ]
check "a name in CORE_ZONE_URL is refused by name" grep -qF 'CORE_ZONE_URL' <<<"$out"
check "a refused value writes no .env" [ ! -e "$cvm/.env" ]
run_setup CORE_LAN=192.168.1.0 -- --yes
check "a LAN without a prefix exits 2" [ "$code" -eq 2 ]
check "a LAN without a prefix is named" grep -qF 'CORE_LAN' <<<"$out"
run_setup CORE_ROLE=tertiary -- --yes
check "an unknown role exits 2" [ "$code" -eq 2 ]
run_setup CORE_ZONE_URL= -- --yes
check "a missing zone URL exits 2 with no default" [ "$code" -eq 2 ]
check "a missing zone URL is named" grep -qF 'CORE_ZONE_URL has no default' <<<"$out"
check "a missing zone URL writes no .env" [ ! -e "$cvm/.env" ]
run_setup CORE_ZONE_URL= -- --dry-run
check "a missing zone URL in --dry-run says what would stop" grep -qF 'a real run would stop: CORE_ZONE_URL' <<<"$out"

echo "setup.test: $pass passed, $fails failed"
[ "$fails" -eq 0 ]
