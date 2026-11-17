#!/usr/bin/env bash
# The one-command setup for the runner's VM (FG-FR-05, FG-FR-15, MVP 2), built on the golden image
# (docs/REF-golden-image.md): Docker, mise, the runner's service user and data folder, and the two
# firewall blocks, so that `sudo docker compose -f compose/runner-vm/docker-compose.yml up -d` starts
# the runner and it all survives a reboot. Run as your normal user, from the checkout's root:
# ./compose/runner-vm/setup.sh. It calls sudo itself for each step that needs it.
#
# - Refuses root. Stops if not Ubuntu, or if the image lacks curl, gpg, sudo, ufw or ca-certificates
#   (named; nothing is installed for them). Installs only Docker, mise, the service user and the data
#   folder, each only when missing.
# - Settles the values in compose/runner-vm/.env before any other change (ST95): each is asked for with its
#   default (Enter accepts); an environment variable of the same name skips its prompt; --yes takes every
#   default; when every value is already in .env and valid, none is asked (ST106); no answer and no default
#   stops naming the value. Addresses must be IPv4 (iptables would refuse
#   the block). The registration token is typed hidden, or is a file's first line; it is never printed.
# - Firewall (FG-FR-05, ufw): SSH allowed in if a rule covers it; default deny in, allow out; host
#   traffic to TRUENAS_ADDR and PROXMOX_ADDR denied on every port; job containers' traffic dropped to
#   the same addresses in DOCKER-USER, through a marked block in /etc/ufw/after.rules. ufw is enabled
#   last. Where iptables cannot be read, nothing is set and the commands are printed.
# - systemctl enable docker and ufw; without systemd it prints the command instead.
# - --check changes nothing and never prompts for sudo (firewall state is read with sudo -n).
#   --dry-run prints every step and changes nothing. The last line is changes: n.
# - Last, it says the runner "shows online once started" and asks "Start the runner now? [Y/n]" (yes by
#   default). It starts the runner only on a yes at a terminal; --yes, no terminal and --dry-run never do.
# change() runs the step functions indirectly through "$@", which shellcheck cannot see.
# shellcheck disable=SC2329
set -euo pipefail

# Copied from workbench/bootstrap/mise.version (the workbench repo). This repo has no bootstrap/
# folder, so the value lives here; when the workbench's file changes, change this too.
MISE_VERSION=v2026.11.8

usage() {
	echo "usage: ./compose/runner-vm/setup.sh [--yes | --dry-run | --check]"
	echo "  --yes       take every default without asking"
	echo "  --check     say whether the VM is ready; changes nothing, no sudo prompt"
	echo "  --dry-run   print every step, change nothing"
}

halt() {
	echo "setup.sh: $*" >&2
	exit 1
}

DRY_RUN=0
CHECK=0
ASSUME_YES=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--check) CHECK=1 ;;
		--yes) ASSUME_YES=1 ;;
		*)
			usage >&2
			exit 2
			;;
	esac
done
if [ "$DRY_RUN" -eq 1 ] && [ "$CHECK" -eq 1 ]; then
	usage >&2
	exit 2
fi
if [ "$(id -u)" -eq 0 ]; then
	halt "run as your normal user, not root: this script calls sudo itself for each step that needs it"
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ENV_DIR="$REPO_DIR/compose/runner-vm"
ENV_FILE="$ENV_DIR/.env"
ENV_EXAMPLE="$ENV_DIR/.env.example"
COMPOSE_FILE=compose/runner-vm/docker-compose.yml
MISE_BIN=/usr/local/bin/mise
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
UFW_AFTER_RULES=/etc/ufw/after.rules
BLOCK_BEGIN="# BEGIN runner-vm blocks (stacks setup.sh, FG-FR-05): managed by setup.sh, do not edit"
BLOCK_END="# END runner-vm blocks"
IMAGE_TOOLS=(curl gpg sudo ufw)
# The values the script asks for (ST95). DOCKER_GID is not asked: this script fills it in once Docker is installed.
ENV_KEYS=(RUNNER_USER RUNNER_UID RUNNER_GID RUNNER_DATA RUNNER_NAME FORGE_URL RUNNER_REGISTRATION_TOKEN TRUENAS_ADDR PROXMOX_ADDR)

CHANGES=0
ALL_STORED=0
MISSING=()
FW_UNREAD=0
SSH_PORT=22
declare -A ENV_VAL=()
declare -A STORED=()
DOCKER_GID=""
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step() { echo "[step] $*"; }

# A stop while settling values: a real run exits 1; --dry-run says what it would stop on and returns 1.
stop_or_note() {
	[ "$DRY_RUN" -eq 1 ] || { echo "setup.sh: $*" >&2; exit 1; }
	echo "[dry-run] a real run would stop: $*"
	return 1
}

# The only place a machine change happens. --dry-run prints it and skips it.
change() {
	local description=$1
	shift
	CHANGES=$((CHANGES + 1))
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[dry-run] would: $description"
		return 0
	fi
	echo "[change] $description"
	"$@"
}

# One --check line: "label: ok (detail)" or "label: missing (detail)". Missing ones are listed last.
report() {
	local state=$1 label=$2 detail=$3
	if [ "$state" = ok ]; then
		echo "$label: ok ($detail)"
	else
		echo "$label: missing ($detail)"
		MISSING+=("$label")
	fi
}

# verdict LABEL OK-DETAIL MISSING-DETAIL COMMAND...: ok when COMMAND succeeds, else missing.
verdict() {
	local label=$1 ok=$2 bad=$3
	shift 3
	if "$@" >/dev/null 2>&1; then
		report ok "$label" "$ok"
	else
		report missing "$label" "$bad"
	fi
}

# A privileged read. Run mode may prompt for sudo; --check and --dry-run never do.
priv_read() {
	if [ "$CHECK" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
		sudo -n "$@" 2>/dev/null
	else
		sudo "$@"
	fi
}

# --- the env file ----------------------------------------------------------

# Reads the values from the env file, if there is one, with a plain loop. Never sourced.
read_env() {
	local line key value want
	[ -f "$ENV_FILE" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		case "$line" in
			'' | \#*) continue ;;
		esac
		key="${line%%=*}"
		value="${line#*=}"
		if [[ " ${ENV_KEYS[*]} DOCKER_GID " == *" $key "* ]]; then ENV_VAL[$key]="$value"; fi
	done < "$ENV_FILE"
	for want in "${ENV_KEYS[@]}" DOCKER_GID; do
		STORED[$want]="${ENV_VAL[$want]:-}"
	done
}

# Copies the values into the script's names (RUNNER_USER and the rest), once settled.
set_globals() {
	local name
	for name in "${ENV_KEYS[@]}" DOCKER_GID; do printf -v "$name" '%s' "${ENV_VAL[$name]:-}"; done
}

# The default of a value: a fixed one, one cheap attempt (RUNNER_NAME: the host name), or none
# (FORGE_URL, the addresses and the token are the owner's).
default_for() {
	case "$1" in
		RUNNER_USER) echo runner ;;
		RUNNER_UID | RUNNER_GID) echo 1200 ;;
		RUNNER_DATA) echo /srv/runner ;;
		RUNNER_NAME) hostname -s 2>/dev/null || true ;;
	esac
}

# One word with no spaces; ids are digits; addresses are IPv4 (iptables would refuse the block);
# FORGE_URL is http(s)://host:port with no trailing slash.
valid_answer() {
	case "$1" in
		RUNNER_UID | RUNNER_GID) [[ $2 =~ ^[0-9]+$ ]] ;;
		*_ADDR) [[ $2 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] ;;
		FORGE_URL) [[ $2 =~ ^https?://[^[:space:]]*[^/[:space:]]$ ]] ;;
		*) [[ $2 =~ ^[^[:space:]]+$ ]] ;;
	esac
}

# Settles one value into ENV_VAL. An environment variable of the same name wins, with no prompt.
# Otherwise asks, with the stored or default value as the default; no answer (or no terminal) takes
# it. The token is typed hidden: it is a file's first line when the answer names a file.
settle() {
	local name=$1 def="" answer=""
	if [ -n "${!name:-}" ]; then
		ENV_VAL[$name]="${!name}"
	else
		def="${ENV_VAL[$name]:-}"
		[ -n "$def" ] || def="$(default_for "$name")"
		if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ "$CHECK" -eq 0 ] && [ "$ALL_STORED" -eq 0 ]; then
			if [ "$name" = RUNNER_REGISTRATION_TOKEN ]; then
				printf '%s (typed, not shown, or a file holding it; Enter keeps the stored one): ' "$name" >&2
				read -rs answer || answer=""
				echo >&2
				if [ -f "$answer" ]; then answer="$(head -n 1 "$answer" | tr -d '\r')"; fi
			else
				printf '%s [%s]: ' "$name" "${def:-no default}" >&2
				read -r answer || answer=""
			fi
		fi
		[ -n "$answer" ] || answer="$def"
		if [ -z "$answer" ]; then
			stop_or_note "$name has no default here: set it in the environment or in $ENV_FILE" || return 1
		fi
		ENV_VAL[$name]="$answer"
	fi
	if ! valid_answer "$name" "${ENV_VAL[$name]}"; then
		stop_or_note "$name is not valid (one word; ids are digits; addresses are IPv4; FORGE_URL is http://host:port with no trailing slash)" || return 1
	fi
}

# The env file's text: the template with the settled values filled in, comments kept.
render_env() {
	local line key
	while IFS= read -r line || [ -n "$line" ]; do
		key="${line%%=*}"
		if [[ $line == *=* && $key =~ ^[A-Z_]+$ ]]; then echo "$key=${ENV_VAL[$key]:-}"; else echo "$line"; fi
	done < "$ENV_EXAMPLE"
}

# Settles every value, then writes the env file (mode 600, from a temp file) only when one differs from
# the stored one. A stop (no answer and no default, a bad value) exits before anything is written.
write_env_file() {
	local tmp name same=1
	# ST106: a .env that already holds every value, each valid, is settled without any prompt.
	ALL_STORED=1
	for name in "${ENV_KEYS[@]}"; do valid_answer "$name" "${STORED[$name]:-}" || ALL_STORED=0; done
	for name in "${ENV_KEYS[@]}"; do
		settle "$name" || { echo "changes: $CHANGES"; exit 0; }
		[ "${STORED[$name]:-}" = "${ENV_VAL[$name]}" ] || same=0
	done
	if [ -f "$ENV_FILE" ] && [ "$same" -eq 1 ]; then
		step "$ENV_FILE already has these values"
		return 0
	fi
	tmp="$(mktemp)"
	render_env > "$tmp"
	change "write $ENV_FILE (mode 600; the registration token is not shown)" install -m 600 "$tmp" "$ENV_FILE"
	rm -f "$tmp"
}

# The names of the values that are empty or not valid, comma separated; empty when all are. Names only,
# never a value: the token is a secret.
env_problem_list() {
	local name out=""
	for name in "${ENV_KEYS[@]}"; do
		if ! valid_answer "$name" "${ENV_VAL[$name]:-}"; then out+="$name, "; fi
	done
	out="${out%, }"
	echo "$out"
}

# --- preflight and steps ---------------------------------------------------

preflight() {
	local tool missing=()
	if ! grep -qx 'ID=ubuntu' /etc/os-release 2>/dev/null || ! command -v apt-get >/dev/null 2>&1; then
		halt "not Ubuntu (apt-get not found, or /etc/os-release is not ID=ubuntu)"
	fi
	for tool in "${IMAGE_TOOLS[@]}"; do
		command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
	done
	dpkg -s ca-certificates >/dev/null 2>&1 || missing+=(ca-certificates)
	if [ "${#missing[@]}" -gt 0 ]; then
		halt "the golden image should provide these and they are missing: ${missing[*]}. Install them from the image, not from this script"
	fi
}

docker_ready() {
	command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

# Docker's own apt repository. Its signing key is checked against the fingerprint before apt is told
# to trust it. Nothing is generated.
docker_install() {
	local codename fingerprints
	codename="$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release)"
	mkdir -m 700 "$WORK/gnupg"
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$WORK/docker.asc"
	fingerprints="$(gpg --homedir "$WORK/gnupg" --show-keys --with-colons "$WORK/docker.asc")"
	if ! grep -qxF "fpr:::::::::${DOCKER_KEY_FPR}:" <<< "$fingerprints"; then
		echo "setup.sh: Docker's key does not have fingerprint $DOCKER_KEY_FPR; nothing installed" >&2
		return 1
	fi
	cat > "$WORK/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Signed-By: $DOCKER_KEY
EOF
	sudo install -d -m 0755 /etc/apt/keyrings
	sudo install -m 0644 "$WORK/docker.asc" "$DOCKER_KEY"
	sudo install -m 0644 "$WORK/docker.sources" "$DOCKER_SOURCES"
	sudo apt-get update -qq
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-compose-plugin
}

# The version mise prints, or empty when it is not installed.
mise_installed_version() {
	if [ -x "$MISE_BIN" ]; then
		"$MISE_BIN" --version 2>/dev/null | awk '{print $1}' || true
	fi
}

install_mise() {
	curl -fsSL https://mise.run | sudo env MISE_VERSION="$MISE_VERSION" MISE_INSTALL_PATH="$MISE_BIN" sh
}

mise_run() {
	local dir=$1
	shift
	env MISE_YES=1 "$MISE_BIN" -C "$dir" "$@"
}

mise_setup() {
	mise_run "$REPO_DIR" trust && mise_run "$REPO_DIR" install
}

# True when the checkout's mise config is trusted and every tool in it is installed.
mise_tools_ready() {
	local trust_out
	trust_out="$(mise_run "$REPO_DIR" trust --show 2>/dev/null || true)"
	grep -q ': trusted$' <<< "$trust_out" && [ -z "$(mise_run "$REPO_DIR" ls --missing 2>/dev/null || true)" ]
}

# The service user: uid and primary gid as set in .env, and a member of docker.
user_ready() {
	local groups
	id -u "$RUNNER_USER" >/dev/null 2>&1 || return 1
	[ "$(id -u "$RUNNER_USER")" = "$RUNNER_UID" ] || return 1
	[ "$(id -g "$RUNNER_USER")" = "$RUNNER_GID" ] || return 1
	groups=" $(id -nG "$RUNNER_USER") "
	[[ $groups == *" docker "* ]]
}

user_make() {
	if ! getent group docker >/dev/null; then
		sudo groupadd --system docker
	fi
	if ! getent group "$RUNNER_USER" >/dev/null; then
		sudo groupadd --system --gid "$RUNNER_GID" "$RUNNER_USER"
	fi
	if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
		sudo useradd --system --uid "$RUNNER_UID" --gid "$RUNNER_GID" --no-create-home \
			--shell /usr/sbin/nologin "$RUNNER_USER"
	fi
	sudo usermod -aG docker "$RUNNER_USER"
}

data_ready() {
	[ -d "$RUNNER_DATA" ] && [ "$(stat -c %U "$RUNNER_DATA")" = "$RUNNER_USER" ]
}

data_make() {
	sudo install -d -o "$RUNNER_USER" -g "$RUNNER_GID" "$RUNNER_DATA"
}

# Writes the docker group id into the one DOCKER_GID line, through a temp file and mv. Every other
# line is copied as it is; the file keeps its owner and mode 600.
env_fill_docker_gid() {
	local gid=$1 tmp
	tmp="$(mktemp "$ENV_DIR/.env.XXXXXX")"
	awk -v v="$gid" '
		/^DOCKER_GID=/ { print "DOCKER_GID=" v; seen = 1; next }
		{ print }
		END { if (!seen) print "DOCKER_GID=" v }
	' "$ENV_FILE" > "$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$ENV_FILE"
}

docker_gid_step() {
	local gid
	if [ -n "$DOCKER_GID" ]; then
		step "DOCKER_GID already set in $ENV_FILE"
		return 0
	fi
	gid="$(getent group docker | cut -d: -f3 || true)"
	if [ -z "$gid" ]; then
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "[dry-run] would: write DOCKER_GID into $ENV_FILE once the docker group exists"
			CHANGES=$((CHANGES + 1))
			return 0
		fi
		halt "no docker group on this VM after the Docker install; DOCKER_GID stays empty"
	fi
	change "write DOCKER_GID=$gid into $ENV_FILE (the only edit to .env)" env_fill_docker_gid "$gid"
}

# --- firewall (FG-FR-05) ---------------------------------------------------

# True when iptables can read the kernel's rules, which ufw needs in order to change them.
firewall_works() {
	sudo iptables -S >/dev/null 2>&1
}

# The rules `ufw show added` lists. A rule added with `ufw insert` is listed the same way.
ufw_has() {
	grep -qxF -- "ufw $1" <<< "$(priv_read ufw show added)"
}

# True when an allow or limit rule covers SSH by port or profile, so nothing is added on top of it.
ufw_has_ssh_allow() {
	grep -Eiq "^ufw (allow|limit) (.* )?(${SSH_PORT}(/tcp)?|ssh|openssh)( |\$)" <<< "$(priv_read ufw show added)"
}

# The defaults are in /etc/default/ufw, so they can be read whether or not ufw is active.
ufw_defaults_ok() {
	grep -qx 'DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw &&
		grep -qx 'DEFAULT_OUTPUT_POLICY="ACCEPT"' /etc/default/ufw
}

ufw_defaults() {
	sudo ufw default deny incoming
	sudo ufw default allow outgoing
}

ufw_active() {
	grep -q '^Status: active' <<< "$(priv_read ufw status)"
}

# The SSH port the server listens on (sshd -T), or 22 when it cannot be read.
ssh_port() {
	local port
	port="$(priv_read sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
	echo "${port:-22}"
}

# The container block. ufw loads after.rules with iptables-restore -n, so declaring the chain is safe
# whether or not Docker has created DOCKER-USER yet; -I puts each drop ahead of Docker's accepts.
block_text() {
	echo "$BLOCK_BEGIN"
	echo "*filter"
	echo ":DOCKER-USER - [0:0]"
	echo "-I DOCKER-USER 1 -d $TRUENAS_ADDR -j DROP"
	echo "-I DOCKER-USER 1 -d $PROXMOX_ADDR -j DROP"
	echo "COMMIT"
	echo "$BLOCK_END"
}

# Writes into $2 the after.rules that should exist, given the current file $1: any earlier block is
# removed and the current one appended.
after_rules_next() {
	awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
		$0 == b { skip = 1; next }
		skip && $0 == e { skip = 0; next }
		!skip { print }
	' "$1" > "$2"
	block_text >> "$2"
}

# True when after.rules already holds the block exactly as it should be.
after_rules_ok() {
	local current="$WORK/after.check" next="$WORK/after.check.next"
	priv_read cat "$UFW_AFTER_RULES" > "$current" || return 1
	after_rules_next "$current" "$next"
	cmp -s "$current" "$next"
}

install_after_rules() {
	sudo install -m 0640 -o root -g root "$1" "$UFW_AFTER_RULES"
	sudo ufw reload
}

# The file is written, and ufw reloaded, only when its text would change.
after_rules_step() {
	local current="$WORK/after.current" next="$WORK/after.next"
	if ! priv_read cat "$UFW_AFTER_RULES" > "$current"; then
		if [ "$DRY_RUN" -eq 0 ]; then
			halt "cannot read $UFW_AFTER_RULES with sudo"
		fi
		echo "[dry-run] cannot read $UFW_AFTER_RULES without a sudo prompt; assuming the block is needed"
		: > "$current"
	fi
	after_rules_next "$current" "$next"
	if cmp -s "$current" "$next"; then
		step "$UFW_AFTER_RULES already holds the container block"
	else
		change "write the container block (DOCKER-USER drops to $TRUENAS_ADDR and $PROXMOX_ADDR) into $UFW_AFTER_RULES, then ufw reload (sudo)" \
			install_after_rules "$next"
	fi
}

# One host block: ufw denies outbound to the address on every port, inserted first so an earlier
# allow cannot shadow it.
host_block() {
	local addr=$1 label=$2
	if ufw_has "deny out to $addr"; then
		step "ufw already denies outbound to $label ($addr)"
	else
		change "ufw insert 1 deny out to $addr: host traffic to $label, every port (sudo)" \
			sudo ufw insert 1 deny out to "$addr"
	fi
}

# The commands to run by hand, when iptables cannot be changed on this machine.
firewall_commands() {
	echo "sudo ufw allow ${SSH_PORT}/tcp        # SSH in, first (skip if sudo ufw show added lists an SSH allow)"
	echo "sudo ufw default deny incoming && sudo ufw default allow outgoing"
	echo "sudo ufw insert 1 deny out to $TRUENAS_ADDR      # host traffic to TrueNAS"
	echo "sudo ufw insert 1 deny out to $PROXMOX_ADDR      # host traffic to Proxmox"
	echo "# append this block to $UFW_AFTER_RULES, then: sudo ufw reload"
	block_text
	echo "sudo ufw --force enable"
}

firewall_step() {
	if [ "$DRY_RUN" -eq 0 ] && ! firewall_works; then
		echo "firewall: iptables cannot be read here (no NET_ADMIN, or no kernel firewall), so ufw is not"
		echo "  set up and no change is counted. Run these on the VM:"
		firewall_commands | sed 's/^/  /'
		return 0
	fi
	SSH_PORT="$(ssh_port)"
	if ufw_has_ssh_allow; then
		step "ufw already allows SSH in"
	else
		change "ufw allow ${SSH_PORT}/tcp (SSH in, before anything is enabled) (sudo)" sudo ufw allow "${SSH_PORT}/tcp"
	fi
	if ufw_defaults_ok; then
		step "ufw defaults already: deny incoming, allow outgoing"
	else
		change "ufw defaults: deny incoming, allow outgoing (sudo)" ufw_defaults
	fi
	host_block "$TRUENAS_ADDR" TrueNAS
	host_block "$PROXMOX_ADDR" Proxmox
	after_rules_step
	if ufw_active; then
		step "ufw already enabled"
	else
		change "ufw enable (SSH is allowed first) (sudo)" sudo ufw --force enable
	fi
}

# --- boot ------------------------------------------------------------------

# Enables one unit at boot. Without systemd, nothing is changed and the command is printed.
boot_enable() {
	local unit=$1
	if [ ! -d /run/systemd/system ]; then
		echo "restart on boot: no systemd here, so $unit is not enabled. Run this by hand: sudo systemctl enable $unit"
	elif systemctl is-enabled --quiet "$unit"; then
		step "$unit already enabled at boot"
	else
		change "systemctl enable $unit (sudo)" sudo systemctl enable "$unit"
	fi
}

# --- --check ---------------------------------------------------------------

run_check() {
	local ver problems addr unit
	ver="$(mise_installed_version)"
	verdict mise "$ver, pinned" "found ${ver:-nothing}; pinned ${MISE_VERSION#v}" test "$ver" = "${MISE_VERSION#v}"
	verdict "docker and compose plugin" "$(command -v docker || true)" "not found" docker_ready
	verdict ufw "installed" "not installed" command -v ufw

	if [ ! -f "$ENV_FILE" ]; then
		report missing "compose/runner-vm/.env" "not there; setup.sh copies .env.example to it"
		problems="file"
	else
		read_env
		set_globals
		problems="$(env_problem_list)"
		verdict "compose/runner-vm/.env" "every value set and valid" "empty or not valid: $problems" test -z "$problems"
		verdict "DOCKER_GID" "set" "empty; setup.sh writes the docker group id into it" test -n "$DOCKER_GID"
	fi

	if [ -z "$problems" ]; then
		verdict "service user $RUNNER_USER" "uid $RUNNER_UID, gid $RUNNER_GID, in docker" \
			"missing, wrong ids, or not in docker" user_ready
		verdict "runner data folder" "$RUNNER_DATA owned by $RUNNER_USER" \
			"$RUNNER_DATA missing or not owned by $RUNNER_USER" data_ready
	else
		report missing "service user and runner data folder" "need a complete env file first"
	fi
	verdict "mise tools in the checkout" "trusted, installed" "not trusted, or a tool is not installed" mise_tools_ready

	if [ -n "$problems" ]; then
		report missing "firewall" "needs a complete env file first"
	elif ! command -v ufw >/dev/null 2>&1; then
		report missing "firewall" "ufw not installed"
	elif ! sudo -n true 2>/dev/null; then
		FW_UNREAD=1
		echo "firewall: not read without a sudo prompt; ./compose/runner-vm/setup.sh (run mode) checks it"
	else
		SSH_PORT="$(ssh_port)"
		verdict "firewall: SSH allowed in" "port $SSH_PORT or its profile" "no allow for port $SSH_PORT" ufw_has_ssh_allow
		verdict "firewall: defaults" "deny incoming, allow outgoing" "not deny incoming, allow outgoing" ufw_defaults_ok
		for addr in "$TRUENAS_ADDR" "$PROXMOX_ADDR"; do
			verdict "firewall: host block $addr" "ufw deny out" "ufw deny out not in place" ufw_has "deny out to $addr"
		done
		verdict "firewall: container block" "$UFW_AFTER_RULES" "not in $UFW_AFTER_RULES, or out of date" after_rules_ok
		verdict "firewall: enabled" "ufw active" "ufw not active" ufw_active
	fi

	if [ ! -d /run/systemd/system ]; then
		echo "restart on boot: not applicable (no systemd)"
	else
		for unit in docker ufw; do
			verdict "$unit at boot" "enabled" "not enabled" systemctl is-enabled --quiet "$unit"
		done
	fi

	if [ "${#MISSING[@]}" -gt 0 ]; then
		echo "not ready: missing $(IFS=', '; echo "${MISSING[*]}")"
		echo "changes: 0"
		exit 1
	fi
	if [ "$FW_UNREAD" -eq 1 ]; then
		echo "ready as far as it was read; the firewall was not read (needs sudo)"
	else
		echo "ready: every item is in place"
	fi
	echo "changes: 0"
	exit 0
}

if [ "$CHECK" -eq 1 ]; then
	run_check
fi

# --- run -------------------------------------------------------------------

preflight
step "checkout: $REPO_DIR"
step "mise version (from workbench/bootstrap/mise.version): $MISE_VERSION"

# 1. The values: settled before any other change (ST95), then written to the env file only when one differs.
[ -f "$ENV_EXAMPLE" ] || halt "missing $ENV_EXAMPLE, the template for the env file"
read_env
write_env_file
set_globals

# 2. Docker's engine and compose plugin, when missing.
if docker_ready; then
	step "docker and compose plugin already installed"
else
	change "install the Docker engine and compose plugin from Docker's apt repository (sudo)" docker_install
fi

# 3. mise itself, at the pinned version.
installed_mise="$(mise_installed_version)"
if [ "$installed_mise" = "${MISE_VERSION#v}" ]; then
	step "mise $MISE_VERSION already at $MISE_BIN"
else
	change "install mise $MISE_VERSION to $MISE_BIN from https://mise.run (was: ${installed_mise:-none}) (sudo)" install_mise
fi

# 4. The service user (this also creates the docker group when it is missing).
if user_ready; then
	step "service user $RUNNER_USER already uid $RUNNER_UID, gid $RUNNER_GID, in docker"
else
	change "create service user $RUNNER_USER (uid $RUNNER_UID, gid $RUNNER_GID, system, no login, in docker) (sudo)" user_make
fi

# 5. DOCKER_GID: the docker group id, written into .env only when that line is empty.
docker_gid_step

# 6. The runner's data folder, owned by the service user.
if data_ready; then
	step "$RUNNER_DATA already owned by $RUNNER_USER"
else
	change "create $RUNNER_DATA owned by $RUNNER_USER (sudo)" data_make
fi

# 7. The checkout's tools through mise, as this user; counted only when something is missing.
if mise_tools_ready; then
	step "checkout's mise tools already trusted and installed"
else
	change "mise trust and mise install in $REPO_DIR" mise_setup
fi

# 8. The two blocks (FG-FR-05).
firewall_step

# 9. Restart on boot.
boot_enable docker
boot_enable ufw

# 10. Start the runner (ST96): asks "Start the runner now? [Y/n]" (yes by default). It starts only on an
# explicit yes (Enter counts) at a real terminal. --yes, no terminal and --dry-run never start; they print the command.
start_offer() {
	local answer="" cmd="sudo docker compose -f $COMPOSE_FILE up -d"
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[dry-run] would ask: Start the runner now? [Y/n]; on yes, run from $REPO_DIR: $cmd"
		return 0
	fi
	if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
		echo "Not started (--yes or no terminal). To start it, run from $REPO_DIR: $cmd"
		return 0
	fi
	printf 'Start the runner now? [Y/n] ' >&2
	read -r answer || answer=""
	case "$answer" in
		'' | y | Y | yes | Yes | YES) ;;
		*)
			echo "Not started. To start it later, run from $REPO_DIR: $cmd"
			return 0
			;;
	esac
	CHANGES=$((CHANGES + 1))
	echo "[change] starting the runner: $cmd"
	if (cd "$REPO_DIR" && sudo docker compose -f "$COMPOSE_FILE" up -d); then
		echo "runner started: it shows online on the forge's page"
	else
		echo "setup.sh: the runner did not start (docker printed why above)" >&2
		return 1
	fi
}

# The runner shows online on the forge's page only once started; then offer to start it.
echo "runner $RUNNER_NAME, for the forge at $FORGE_URL: shows online on the forge's page (once started)"
start_status=0
start_offer || start_status=$?
echo "changes: $CHANGES"
exit "$start_status"
