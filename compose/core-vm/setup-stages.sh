# shellcheck shell=bash
# The stages of compose/core-vm/setup.sh (CORE-FR-10, ST218), sourced by it. setup.sh owns MODE,
# CHANGES, VAL (the node's values), REPO_DIR and SCRIPT_DIR. Each stage checks first and changes only
# what differs. Read-only checks run in every mode; a change goes through change(), which --dry-run
# prints and skips. CORE_ROOT (default /) is the root the /etc paths hang from; a test sets it.
# shellcheck disable=SC2034
ETC="${CORE_ROOT:-}/etc"
ZONE_DIR=/var/lib/core/zone
ZONE_NAME=core.andrusonline.com
CORE_CONTAINERS=(core-bind core-unbound core-chrony)
# The deploy key git-access makes for the prod role (ST252). setup.sh runs as the owner, so this is the owner's home.
ZONE_KEY="$HOME/.ssh/id_ed25519_github"

# A missing requirement: a real run exits 2; --dry-run says what a real run would stop on and goes on.
stop() {
	if [ "$MODE" = dry ]; then
		echo "[dry-run] a real run would stop: $*"
		return 0
	fi
	echo "setup.sh: $*" >&2
	exit 2
}

hint() {
	case "$1" in
		CORE_BIND) echo "this VM's IPv4 address" ;;
		CORE_LAN) echo "the LAN as an IPv4 CIDR, for example 192.168.1.0/24" ;;
		CORE_ADMIN) echo "the IPv4 address or CIDR allowed to SSH in" ;;
		CORE_ZONE_URL) echo "an http(s) URL with an address, not a name, for example http://192.168.1.20/zone.git; or an absolute path to a clone or bare repository, for example /nas/projects/andrusone/zone; or a file:// URL of one; or git@github.com:owner/repo.git with a deploy key" ;;
		CORE_ROLE) echo "primary or secondary" ;;
		CORE_PEER) echo "the other node's IPv4 address; empty until it exists" ;;
	esac
}

# The defaults: this VM's default-route address, its /24, the SSH client's address, primary.
default_for() {
	local src
	case "$1" in
		CORE_BIND | CORE_LAN)
			src="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')" || true
			if [ "$1" = CORE_BIND ]; then echo "$src"; elif [ -n "$src" ]; then echo "${src%.*}.0/24"; fi
			;;
		CORE_ADMIN) echo "${SSH_CLIENT:-}" | awk '{print $1}' ;;
		CORE_ROLE) echo primary ;;
	esac
}

valid_value() {
	local v=$2 ip='([0-9]{1,3}\.){3}[0-9]{1,3}'
	case "$1" in
		CORE_BIND) [[ $v =~ ^$ip$ ]] ;;
		CORE_LAN) [[ $v =~ ^$ip/[0-9]{1,2}$ ]] ;;
		CORE_ADMIN) [[ $v =~ ^$ip(/[0-9]{1,2})?$ ]] ;;
		CORE_ZONE_URL) [[ $v =~ ^https?://$ip(:[0-9]+)?(/[^[:space:]]*)?$ ]] || [[ $v == /* && -d $v ]] || [[ $v == file:///* && -d ${v#file://} ]] || [[ $v =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] ;;
		CORE_ROLE) [ "$v" = primary ] || [ "$v" = secondary ] ;;
		CORE_PEER) [ -z "$v" ] || [[ $v =~ ^$ip$ ]] ;;
	esac
}

# One value: the environment, then .env, then the question (Enter takes the default). --yes, no
# terminal and --dry-run take the default without asking; no default there stops, naming the value.
settle() {
	local name=$1 answer def
	if [ -n "${!name:-}" ]; then
		answer=${!name}
	elif [ -n "${STORED[$name]+x}" ]; then
		answer=${STORED[$name]}
	else
		def="$(default_for "$name")"
		if [ "$MODE" = dry ] || [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
			answer=$def
		else
			while :; do
				printf '%s (%s) [%s]: ' "$name" "$(hint "$name")" "$def" >&2
				read -r answer || answer=""
				answer=${answer:-$def}
				valid_value "$name" "$answer" && break
				echo "$name: not valid, expected $(hint "$name"); asking again" >&2
			done
			VAL["$name"]=$answer
			return 0
		fi
	fi
	VAL["$name"]=$answer
	if valid_value "$name" "$answer"; then return 0; fi
	if [ -z "$answer" ]; then
		stop "$name has no default here: set it in the environment or in $ENV_FILE ($(hint "$name"))"
	else
		stop "$name '$answer' is not valid: expected $(hint "$name")"
	fi
}

# Writes a file under /etc through sudo. The content is built inside the function, so --dry-run builds nothing.
write_root() {
	local tmp
	tmp="$(mktemp)"
	printf '%s\n' "$2" > "$tmp"
	sudo install -D -m 0644 "$tmp" "$1"
	rm -f "$tmp"
}

# The env file (mode 600): the template with the settled values filled in, comments kept.
write_env_file() {
	local tmp line key
	tmp="$(mktemp)"
	while IFS= read -r line || [ -n "$line" ]; do
		key="${line%%=*}"
		if [[ $line == *=* && -n "${VAL[$key]+x}" ]]; then echo "$key=${VAL[$key]}"; else echo "$line"; fi
	done < "$ENV_EXAMPLE" > "$tmp"
	install -m 600 "$tmp" "$ENV_FILE"
	rm -f "$tmp"
}

# Preflight: apt, systemd, Docker and mise. Nothing is changed here.
preflight() {
	step "preflight: apt, systemd, Docker and mise"
	command -v apt-get >/dev/null 2>&1 || stop "no apt-get: this needs an Ubuntu machine"
	[ -d "${CORE_ROOT:-}/run/systemd/system" ] || stop "systemd is not running: a core node is a VM with systemd, not a container or a WSL shell"
	command -v docker >/dev/null 2>&1 || stop "Docker is missing: install the engine first (docs/RUNBOOK-host.md)"
	command -v mise >/dev/null 2>&1 || stop "mise is missing: install it first (docs/RUNBOOK-host.md)"
	zone_key_check
}

# host.sh with the node's LAN, admin and peer values. It checks first itself; its "changes: n" is added here.
run_host() {
	local host="$REPO_DIR/compose/core-vm/host.sh" out n
	local -a cmd=(env "CORE_LAN=${VAL[CORE_LAN]}" "CORE_ADMIN=${VAL[CORE_ADMIN]}" "CORE_PEER=${VAL[CORE_PEER]}" "$host")
	step "host.sh: chrony, ufw and DOCKER-USER"
	if [ "$MODE" = dry ]; then cmd+=(--dry-run); else cmd=(sudo "${cmd[@]}"); fi
	out="$(mktemp)"
	if ! "${cmd[@]}" > "$out" 2>&1; then
		cat "$out" >&2
		rm -f "$out"
		stop "host.sh failed, see its message above"
		return 0
	fi
	cat "$out"
	n="$(sed -n 's/^changes: //p' "$out")"
	CHANGES=$((CHANGES + ${n:-0}))
	rm -f "$out"
}

# The SSH form of CORE_ZONE_URL needs the deploy key on this machine. Checked before anything is written:
# a missing key stops with the one command to run. The key is checked for existence only, never read.
zone_key_check() {
	[[ ${VAL[CORE_ZONE_URL]} == git@* ]] || return 0
	if [ ! -f "$ZONE_KEY" ]; then
		stop "no deploy key at $ZONE_KEY. In a clone of machine (as the runbook says), run ./tools/git-access/git-access.sh --role prod --deploy-repo andrusone/zone, then register the public key it prints as a read-only deploy key on andrusone/zone by hand"
	fi
}

# The zone-sync units and /etc/core/zone-sync.env, then the timer. The service's ExecStart is this
# checkout's zone-sync.sh, whatever the path of the checkout is.
zone_units() {
	local unit want units_changed=0 env_want
	step "zone-sync: units, /etc/core/zone-sync.env and the timer"
	for unit in zone-sync.service zone-sync.timer; do
		want="$(cat "$SCRIPT_DIR/$unit")"
		if [ "$unit" = zone-sync.service ]; then
			# shellcheck disable=SC2001
			want="$(sed "s|^ExecStart=.*|ExecStart=$REPO_DIR/compose/core-vm/zone-sync.sh|" <<< "$want")"
		fi
		if [ "$(cat "$ETC/systemd/system/$unit" 2>/dev/null || true)" != "$want" ]; then
			change "install $ETC/systemd/system/$unit" write_root "$ETC/systemd/system/$unit" "$want"
			units_changed=1
		fi
	done
	env_want="CORE_ZONE_URL=${VAL[CORE_ZONE_URL]}
CORE_ZONE_DIR=$ZONE_DIR
CORE_ZONE_OUT=$REPO_DIR/compose/core/bind/zone
CORE_ZONE_NAME=$ZONE_NAME"
	if [[ ${VAL[CORE_ZONE_URL]} == git@* ]]; then env_want+="
CORE_ZONE_KEY=$ZONE_KEY"; fi
	if [ "$(cat "$ETC/core/zone-sync.env" 2>/dev/null || true)" != "$env_want" ]; then
		change "install $ETC/core/zone-sync.env" write_root "$ETC/core/zone-sync.env" "$env_want"
	fi
	if [ "$units_changed" -eq 1 ]; then change "systemctl daemon-reload" sudo systemctl daemon-reload; fi
	if systemctl is-enabled --quiet zone-sync.timer 2>/dev/null && systemctl is-active --quiet zone-sync.timer; then
		step "zone-sync.timer is enabled and running"
	else
		change "systemctl enable --now zone-sync.timer" sudo systemctl enable --now zone-sync.timer
	fi
}

# The first zone sync, through the service (it runs as root, as the timer does), when BIND has no copy yet.
first_zone_sync() {
	local copy="$REPO_DIR/compose/core/bind/zone/db.$ZONE_NAME"
	if [ -f "$copy" ]; then
		step "BIND's copy of the zone is in place"
		return 0
	fi
	change "first zone sync: systemctl start zone-sync.service" sudo systemctl start zone-sync.service
	if [ "$MODE" != dry ] && [ ! -f "$copy" ]; then
		echo "zone-sync: no copy yet. The origin must be reachable: journalctl -u zone-sync.service"
	fi
}

# The values mise run core-up gets: this VM's address and LAN, the node's ports (BIND on 5300, where the
# peer reaches it; Unbound answers the LAN on 53; chrony on 123), the role and the peer.
core_values() {
	echo "CORE_LISTEN=${VAL[CORE_BIND]} CORE_LAN=${VAL[CORE_LAN]} CORE_DNS_PORT=53 CORE_NTP_PORT=123 CORE_BIND_PORT=5300 CORE_ROLE=${VAL[CORE_ROLE]} CORE_PEER=${VAL[CORE_PEER]}"
}

start_core() {
	local -a vars
	read -ra vars <<< "$(core_values)"
	(cd "$REPO_DIR" && env "${vars[@]}" mise run core-up)
}

# mise run core-up with core_values.
core_up() {
	local running name
	running="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
	for name in "${CORE_CONTAINERS[@]}"; do
		if ! grep -qx "$name" <<< "$running"; then
			change "mise run core-up ($(core_values))" start_core
			return 0
		fi
	done
	step "core containers are running"
}

# The core backup's units (CORE-FR-06, ST266): backup.service and backup.timer in /etc/systemd/system, the
# service run as the checkout's user (the .env is theirs, mode 600). Nothing is installed until the NAS folder
# exists (host/nas-layout.sh makes it); then the timer is enabled and started. A rerun changes nothing.
CORE_NAS_BACKUP=/nas/cloud-backup/services/core/backup
backup_units() {
	local unit want units_changed=0 user
	step "backup: units and the timer"
	if [ ! -d "$CORE_NAS_BACKUP" ]; then
		echo "backup: not installed, the backup folder $CORE_NAS_BACKUP is missing; run host/nas-layout.sh"
		return 0
	fi
	user="$(id -un)"
	for unit in backup.service backup.timer; do
		want="$(cat "$SCRIPT_DIR/$unit")"
		if [ "$unit" = backup.service ]; then
			# shellcheck disable=SC2001
			want="$(sed -e "s|^ExecStart=.*|ExecStart=$REPO_DIR/compose/core-vm/backup.sh|" -e "s|^Type=oneshot|Type=oneshot\nUser=$user|" <<< "$want")"
		fi
		if [ "$(cat "$ETC/systemd/system/$unit" 2>/dev/null || true)" != "$want" ]; then
			change "install $ETC/systemd/system/$unit (ExecStart and User= for this checkout)" write_root "$ETC/systemd/system/$unit" "$want"
			units_changed=1
		fi
	done
	if [ "$units_changed" -eq 1 ]; then change "systemctl daemon-reload" sudo systemctl daemon-reload; fi
	if systemctl is-enabled --quiet backup.timer 2>/dev/null && systemctl is-active --quiet backup.timer; then
		step "backup.timer is enabled and running"
	else
		change "systemctl enable --now backup.timer" sudo systemctl enable --now backup.timer
	fi
}
