#!/usr/bin/env bash
# The one-command setup for a plain Ubuntu Server VM that hosts the Forgejo Actions runner (FG-FR-05,
# FG-FR-15, MVP 2): Docker, mise, the two firewall blocks, the runner's service user and data folder,
# so that
#   docker compose -f compose/runner-vm/docker-compose.yml up -d
# starts the runner, and the blocks and the runner come back after a reboot. Run as:
#   sudo ./compose/runner-vm/setup.sh
# from a clone of the stacks repo, as the login of the user who owns that clone.
#
# - Stops with a plain message if not root, not Ubuntu (apt), or run without SUDO_USER.
# - Reads ten values from compose/runner-vm/.env with a plain loop; the file is never sourced. If the
#   file is missing, copies .env.example to it (mode 600, owned by SUDO_USER), lists the variables and
#   exits 1 before anything else. Every value except DOCKER_GID must be set; an empty or unset one is
#   named and stops the run. The registration token is never printed or written anywhere.
# - Installs what mise cannot, each only when missing: ufw, the Docker engine and compose plugin from
#   Docker's apt repository (the signing key must have Docker's published fingerprint), mise at
#   MISE_VERSION, the service user (system, no login, in the docker group, with RUNNER_UID and
#   RUNNER_GID), and RUNNER_DATA owned by that user.
# - When DOCKER_GID is empty, writes the VM's docker group id into that one line of .env. That is the
#   only edit the script makes to .env.
# - As SUDO_USER in this checkout: mise trust and mise install, so mise.toml is the tool list.
# - Firewall (FG-FR-05), with ufw: allow SSH in, default deny incoming and allow outgoing, then deny
#   outbound to TRUENAS_ADDR and PROXMOX_ADDR on every port, and deny the same addresses on the
#   forwarded path (ufw route), which is where job containers' traffic goes. Each rule is added only
#   when missing; ufw is enabled last, after the SSH rule. Where ufw cannot change the firewall (no
#   iptables access, as in a container without NET_ADMIN), nothing is set, nothing is counted, and the
#   commands are printed to run by hand.
# - Restart on boot: systemctl enable docker and ufw. Without systemd it counts no change and prints
#   the command to run.
# - --check changes nothing and needs no root for the rest; the firewall rules need root to read, and
#   are reported missing without it. It lists each item as ok or missing and exits non-zero if any is
#   missing. --dry-run prints every step and changes nothing.
# - Every machine change goes through change(), which --dry-run skips. The last line is changes: n.
# change() runs the step functions indirectly through "$@", which shellcheck cannot see.
# shellcheck disable=SC2329
set -euo pipefail

# The mise version, copied from workbench/bootstrap/mise.version (the workbench repo). This repo has
# no bootstrap/ folder, so the value lives here; when the workbench's file changes, change this too.
MISE_VERSION=v2026.11.8

usage() {
	echo "usage: sudo ./compose/runner-vm/setup.sh [--dry-run | --check]"
	echo "  --check     say whether the VM is ready; changes nothing (firewall needs root to read)"
	echo "  --dry-run   print every step, change nothing"
}

usage_error() {
	echo "setup.sh: $*" >&2
	usage >&2
	exit 2
}

DRY_RUN=0
CHECK=0
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--check) CHECK=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		*) usage_error "unknown argument: $1" ;;
	esac
	shift
done
if [ "$DRY_RUN" -eq 1 ] && [ "$CHECK" -eq 1 ]; then
	usage_error "--check and --dry-run cannot be combined"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
COMPOSE_FILE=compose/runner-vm/docker-compose.yml
MISE_BIN=/usr/local/bin/mise
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
BASE_PACKAGES=(ca-certificates curl gnupg sudo ufw)
ENV_KEYS=(RUNNER_USER RUNNER_UID RUNNER_GID DOCKER_GID RUNNER_DATA RUNNER_NAME FORGE_URL RUNNER_REGISTRATION_TOKEN TRUENAS_ADDR PROXMOX_ADDR)
# Every value except DOCKER_GID, which this script fills in.
REQUIRED_KEYS=(RUNNER_USER RUNNER_UID RUNNER_GID RUNNER_DATA RUNNER_NAME FORGE_URL RUNNER_REGISTRATION_TOKEN TRUENAS_ADDR PROXMOX_ADDR)
SYSTEMD_RUN_DIR=/run/systemd/system

# The checkout's owner: the sudo caller. A --check run as the user itself uses that user's name.
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"
CHANGES=0
MISSING=()
declare -A ENV_VAL=()
RUNNER_USER=""
RUNNER_UID=""
RUNNER_GID=""
DOCKER_GID=""
RUNNER_DATA=""
TRUENAS_ADDR=""
PROXMOX_ADDR=""
SSH_PORT=22

step() { echo "[step] $*"; }

# A preflight failure: a real run stops; --dry-run says what it would have done and goes on.
stop_or_note() {
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[dry-run] a real run would stop: $*"
	else
		echo "setup.sh: $*" >&2
		exit 1
	fi
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

# --- the env file ----------------------------------------------------------

# Reads the wanted values with a plain loop. Never sourced, so nothing in it runs.
read_env() {
	local line key value want
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%$'\r'}"
		case "$line" in
			'' | \#*) continue ;;
		esac
		key="${line%%=*}"
		value="${line#*=}"
		for want in "${ENV_KEYS[@]}"; do
			if [ "$key" = "$want" ]; then
				ENV_VAL[$want]="$value"
			fi
		done
	done < "$ENV_FILE"
	RUNNER_USER="${ENV_VAL[RUNNER_USER]:-}"
	RUNNER_UID="${ENV_VAL[RUNNER_UID]:-}"
	RUNNER_GID="${ENV_VAL[RUNNER_GID]:-}"
	DOCKER_GID="${ENV_VAL[DOCKER_GID]:-}"
	RUNNER_DATA="${ENV_VAL[RUNNER_DATA]:-}"
	TRUENAS_ADDR="${ENV_VAL[TRUENAS_ADDR]:-}"
	PROXMOX_ADDR="${ENV_VAL[PROXMOX_ADDR]:-}"
}

# Prints the names of values that are empty or unset, and of values that are malformed. Never prints
# a value: the registration token is a secret.
env_problems() {
	local name
	for name in "${REQUIRED_KEYS[@]}"; do
		if [ -z "${ENV_VAL[$name]:-}" ]; then
			echo "$name"
		fi
	done
	for name in RUNNER_UID RUNNER_GID DOCKER_GID; do
		if [ -n "${ENV_VAL[$name]:-}" ] && ! [[ ${ENV_VAL[$name]} =~ ^[0-9]+$ ]]; then
			echo "$name (not a number)"
		fi
	done
	if [ -n "${ENV_VAL[RUNNER_DATA]:-}" ] && [[ ${ENV_VAL[RUNNER_DATA]} != /* ]]; then
		echo "RUNNER_DATA (not an absolute path)"
	fi
}

# The problems on one line, comma separated; empty when every value is set.
env_problem_list() {
	env_problems | paste -sd, - | sed 's/,/, /g'
}

# --- preflight and steps ---------------------------------------------------

preflight() {
	if [ "$(id -u)" -ne 0 ]; then
		stop_or_note "not root. Run it as: sudo ./compose/runner-vm/setup.sh (from the login of the user who owns this checkout)"
	fi
	if ! grep -qx 'ID=ubuntu' /etc/os-release 2>/dev/null || ! command -v apt-get >/dev/null 2>&1; then
		stop_or_note "not Ubuntu (apt-get not found, or /etc/os-release is not ID=ubuntu)"
	fi
	if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then
		stop_or_note "no user to run mise for: run sudo from your own login (SUDO_USER is not set)"
	fi
}

apt_install() {
	apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

docker_ready() {
	command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

# Docker's own apt repository, the official route. Its published signing key is read and checked
# against the fingerprint above before apt trusts it. Nothing is generated.
docker_install() {
	local codename tmp_home
	codename="$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release)"
	if [ -z "$codename" ]; then
		codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
	fi
	tmp_home="$(mktemp -d)"
	install -d -m 0755 /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_KEY.part"
	if ! gpg --homedir "$tmp_home" --show-keys --with-colons "$DOCKER_KEY.part" |
		grep -qxF "fpr:::::::::${DOCKER_KEY_FPR}:"; then
		rm -rf "$tmp_home" "$DOCKER_KEY.part"
		echo "setup.sh: Docker's key does not have fingerprint $DOCKER_KEY_FPR; nothing installed" >&2
		return 1
	fi
	rm -rf "$tmp_home"
	mv "$DOCKER_KEY.part" "$DOCKER_KEY"
	chmod a+r "$DOCKER_KEY"
	cat > "$DOCKER_SOURCES" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Signed-By: $DOCKER_KEY
EOF
	apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-compose-plugin
}

# The version mise prints, or empty when it is not installed.
mise_installed_version() {
	if [ -x "$MISE_BIN" ]; then
		"$MISE_BIN" --version 2>/dev/null | awk '{print $1}' || true
	fi
}

install_mise() {
	curl -fsSL https://mise.run | MISE_VERSION="$MISE_VERSION" MISE_INSTALL_PATH="$MISE_BIN" sh
}

# Runs mise in the folder given, as the checkout's user. Runs it directly when that is the current
# user (--check, run as the user), so no sudo prompt.
mise_as_user() {
	local dir=$1
	shift
	if [ "$(id -un)" = "$RUN_USER" ]; then
		env MISE_YES=1 "$MISE_BIN" -C "$dir" "$@"
	else
		sudo -H -u "$RUN_USER" env MISE_YES=1 "$MISE_BIN" -C "$dir" "$@"
	fi
}

# The SSH port the server listens on (sshd -T), or 22 when sshd is not there to ask.
ssh_port() {
	local port
	port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
	echo "${port:-22}"
}

# The runner's service user: uid and primary gid as set in .env, and a member of docker.
user_ready() {
	local groups
	id -u "$RUNNER_USER" >/dev/null 2>&1 || return 1
	[ "$(id -u "$RUNNER_USER")" = "$RUNNER_UID" ] || return 1
	[ "$(id -g "$RUNNER_USER")" = "$RUNNER_GID" ] || return 1
	groups=" $(id -nG "$RUNNER_USER") "
	[[ $groups == *" docker "* ]]
}

# Stops (or notes, under --dry-run) when the name already belongs to a user or group with other ids.
user_conflict() {
	if id -u "$RUNNER_USER" >/dev/null 2>&1; then
		if [ "$(id -u "$RUNNER_USER")" != "$RUNNER_UID" ]; then
			stop_or_note "$RUNNER_USER already exists with uid $(id -u "$RUNNER_USER"), not RUNNER_UID=$RUNNER_UID"
			return 1
		fi
		if [ "$(id -g "$RUNNER_USER")" != "$RUNNER_GID" ]; then
			stop_or_note "$RUNNER_USER already exists with gid $(id -g "$RUNNER_USER"), not RUNNER_GID=$RUNNER_GID"
			return 1
		fi
	fi
	return 0
}

user_make() {
	if ! getent group docker >/dev/null; then
		groupadd --system docker
	fi
	if ! getent group "$RUNNER_USER" >/dev/null; then
		groupadd --system --gid "$RUNNER_GID" "$RUNNER_USER"
	fi
	if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
		useradd --system --uid "$RUNNER_UID" --gid "$RUNNER_GID" --no-create-home \
			--shell /usr/sbin/nologin "$RUNNER_USER"
	fi
	usermod -aG docker "$RUNNER_USER"
}

data_ready() {
	[ -d "$RUNNER_DATA" ] && [ "$(stat -c %U "$RUNNER_DATA")" = "$RUNNER_USER" ]
}

data_make() {
	install -d -o "$RUNNER_USER" -g "$RUNNER_GID" "$RUNNER_DATA"
}

# Writes the docker group id into the one DOCKER_GID line, through a temp file and mv. Every other
# line is copied as it is, and the file keeps its owner and mode 600.
env_fill_docker_gid() {
	local gid tmp
	gid="$(getent group docker | cut -d: -f3)"
	tmp="$(mktemp "$SCRIPT_DIR/.env.XXXXXX")"
	awk -v v="$gid" '
		BEGIN { done = 0 }
		/^DOCKER_GID=/ { print "DOCKER_GID=" v; done = 1; next }
		{ print }
		END { if (!done) print "DOCKER_GID=" v }
	' "$ENV_FILE" > "$tmp"
	chown "$RUN_USER:$RUN_GROUP" "$tmp"
	chmod 600 "$tmp"
	mv -f "$tmp" "$ENV_FILE"
}

# --- firewall (FG-FR-05) ---------------------------------------------------

# True when ufw is installed and iptables can read the kernel's rules (root, and the kernel allows it).
firewall_works() {
	command -v ufw >/dev/null 2>&1 && iptables -S >/dev/null 2>&1
}

# The rule as `ufw show added` prints it, found exactly. Empty output when ufw is missing or unreadable.
ufw_shown() {
	ufw show added 2>/dev/null | grep -qxF -- "$1"
}

ufw_defaults_ok() {
	ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming), allow (outgoing)'
}

ufw_active() {
	ufw status 2>/dev/null | grep -q '^Status: active'
}

ufw_defaults() {
	ufw default deny incoming
	ufw default allow outgoing
}

ufw_enable() {
	ufw --force enable
}

# The rules in the order they must be added: SSH first (so enabling never cuts the session in
# progress), then the defaults, then the two blocks on the host and on the forwarded path.
firewall_commands() {
	echo "sudo ufw allow ${SSH_PORT}/tcp"
	echo "sudo ufw default deny incoming && sudo ufw default allow outgoing"
	echo "sudo ufw deny out to $TRUENAS_ADDR    # host traffic to TrueNAS, all ports"
	echo "sudo ufw route deny to $TRUENAS_ADDR  # job containers' traffic to TrueNAS, all ports"
	echo "sudo ufw deny out to $PROXMOX_ADDR    # host traffic to Proxmox, all ports"
	echo "sudo ufw route deny to $PROXMOX_ADDR  # job containers' traffic to Proxmox, all ports"
	echo "sudo ufw --force enable"
}

firewall_rule() {
	local shown=$1
	shift
	if ufw_shown "$shown"; then
		step "$shown already in place"
	else
		change "$shown" ufw "$@"
	fi
}

firewall_step() {
	if [ "$DRY_RUN" -eq 0 ] && ! firewall_works; then
		echo "firewall: ufw cannot change this machine's firewall here (no ufw or no iptables access), so"
		echo "  nothing is set and no change is counted. Run these on the VM, as root:"
		firewall_commands | sed 's/^/  /'
		return 0
	fi
	firewall_rule "ufw allow ${SSH_PORT}/tcp" allow "${SSH_PORT}/tcp"
	if ufw_defaults_ok; then
		step "ufw defaults already: deny incoming, allow outgoing"
	else
		change "ufw default: deny incoming, allow outgoing" ufw_defaults
	fi
	firewall_rule "ufw deny out to $TRUENAS_ADDR" deny out to "$TRUENAS_ADDR"
	firewall_rule "ufw route deny to $TRUENAS_ADDR" route deny to "$TRUENAS_ADDR"
	firewall_rule "ufw deny out to $PROXMOX_ADDR" deny out to "$PROXMOX_ADDR"
	firewall_rule "ufw route deny to $PROXMOX_ADDR" route deny to "$PROXMOX_ADDR"
	if ufw_active; then
		step "ufw already enabled"
	else
		change "ufw enable (SSH is allowed first)" ufw_enable
	fi
}

# --- boot ------------------------------------------------------------------

systemd_present() {
	[ -d "$SYSTEMD_RUN_DIR" ]
}

# Enables one unit at boot. Without systemd, nothing is changed and the command is printed.
boot_enable() {
	local unit=$1
	if ! systemd_present; then
		echo "restart on boot: no systemd here, so $unit is not enabled. Run this by hand: sudo systemctl enable $unit"
	elif systemctl is-enabled --quiet "$unit"; then
		step "$unit already enabled at boot"
	else
		change "systemctl enable $unit" systemctl enable "$unit"
	fi
}

# --- --check ---------------------------------------------------------------

check_rule() {
	local label=$1 shown=$2
	if ufw_shown "$shown"; then
		report ok "firewall: $label" "$shown"
	else
		report missing "firewall: $label" "$shown not in place"
	fi
}

run_check() {
	local ver problems addr
	ver="$(mise_installed_version)"
	if [ "$ver" = "${MISE_VERSION#v}" ]; then
		report ok "mise" "$ver, pinned"
	else
		report missing "mise" "found ${ver:-nothing}; pinned ${MISE_VERSION#v}"
	fi
	if docker_ready; then
		report ok "docker and compose plugin" "$(command -v docker)"
	else
		report missing "docker and compose plugin" "not found"
	fi
	if command -v ufw >/dev/null 2>&1; then
		report ok "ufw" "$(command -v ufw)"
	else
		report missing "ufw" "not installed"
	fi

	if [ ! -f "$ENV_FILE" ]; then
		report missing "compose/runner-vm/.env" "not there; setup.sh copies .env.example to it"
		problems="file"
	else
		read_env
		problems="$(env_problem_list)"
		if [ -z "$problems" ]; then
			report ok "compose/runner-vm/.env" "every value set"
		else
			report missing "compose/runner-vm/.env" "not set: $problems"
		fi
		if [ -z "$DOCKER_GID" ]; then
			report missing "DOCKER_GID" "empty; setup.sh writes the docker group id into it"
		fi
	fi

	if [ -z "$problems" ]; then
		if user_ready; then
			report ok "service user $RUNNER_USER" "uid $RUNNER_UID, gid $RUNNER_GID, in docker"
		else
			report missing "service user $RUNNER_USER" "missing, wrong ids, or not in docker"
		fi
		if data_ready; then
			report ok "runner data folder" "$RUNNER_DATA owned by $RUNNER_USER"
		else
			report missing "runner data folder" "$RUNNER_DATA not there, or not owned by $RUNNER_USER"
		fi
	else
		report missing "service user and runner data folder" "they need the env file first"
	fi

	local trust_out
	trust_out="$(mise_as_user "$REPO_DIR" trust --show 2>/dev/null || true)"
	if grep -q ': trusted$' <<< "$trust_out" &&
		[ -z "$(mise_as_user "$REPO_DIR" ls --missing 2>/dev/null || true)" ]; then
		report ok "mise tools in the checkout" "trusted, installed"
	else
		report missing "mise tools in the checkout" "not trusted, or a tool is not installed"
	fi

	if [ "$(id -u)" -ne 0 ]; then
		report missing "firewall rules" "not read: ufw needs root; run sudo ./compose/runner-vm/setup.sh --check"
	elif [ -z "$problems" ]; then
		check_rule "ssh in" "ufw allow ${SSH_PORT}/tcp"
		if ufw_defaults_ok; then
			report ok "firewall: defaults" "deny incoming, allow outgoing"
		else
			report missing "firewall: defaults" "not deny incoming, allow outgoing"
		fi
		for addr in "$TRUENAS_ADDR" "$PROXMOX_ADDR"; do
			check_rule "host block $addr" "ufw deny out to $addr"
			check_rule "container block $addr" "ufw route deny to $addr"
		done
		if ufw_active; then
			report ok "firewall: enabled" "ufw active"
		else
			report missing "firewall: enabled" "ufw not active"
		fi
	else
		report missing "firewall rules" "they need the env file first"
	fi

	if ! systemd_present; then
		echo "restart on boot: not applicable (no systemd)"
	else
		for unit in docker ufw; do
			if systemctl is-enabled --quiet "$unit"; then
				report ok "$unit at boot" "enabled"
			else
				report missing "$unit at boot" "not enabled"
			fi
		done
	fi

	if [ "${#MISSING[@]}" -gt 0 ]; then
		echo "not ready: missing $(IFS=', '; echo "${MISSING[*]}")"
		echo "changes: 0"
		exit 1
	fi
	echo "ready: every item is in place"
	echo "changes: 0"
	exit 0
}

SSH_PORT="$(ssh_port)"

if [ "$CHECK" -eq 1 ]; then
	run_check
fi

# --- run -------------------------------------------------------------------

preflight
step "checkout: $REPO_DIR"
step "user for mise: $RUN_USER"
step "mise version (from workbench/bootstrap/mise.version): $MISE_VERSION"

# 1. The env file. Without it, copy the template and stop before anything else.
if [ ! -f "$ENV_FILE" ]; then
	if [ ! -f "$ENV_EXAMPLE" ]; then
		stop_or_note "missing $ENV_EXAMPLE, the template for the env file"
		echo "changes: $CHANGES"
		exit 0
	fi
	change "copy $ENV_EXAMPLE to $ENV_FILE (mode 600, owned by $RUN_USER)" \
		install -m 600 -o "$RUN_USER" -g "$RUN_GROUP" "$ENV_EXAMPLE" "$ENV_FILE"
	echo "Fill in these variables in $ENV_FILE, then run sudo ./compose/runner-vm/setup.sh again:"
	grep -E '^[A-Z_]+=' "$ENV_EXAMPLE" | cut -d= -f1 | sed 's/^/  /'
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[dry-run] stops here: $ENV_FILE has no values yet"
		echo "changes: $CHANGES"
		exit 0
	fi
	echo "changes: $CHANGES"
	exit 1
fi

read_env
problems="$(env_problem_list)"
if [ -n "$problems" ]; then
	stop_or_note "set these in $ENV_FILE: $problems"
	echo "changes: $CHANGES"
	exit 0
fi

# 2. Install what mise cannot: apt packages, then Docker.
apt_missing=()
for pkg in "${BASE_PACKAGES[@]}"; do
	if ! dpkg -s "$pkg" >/dev/null 2>&1; then
		apt_missing+=("$pkg")
	fi
done
if [ "${#apt_missing[@]}" -gt 0 ]; then
	change "apt-get install ${apt_missing[*]}" apt_install "${apt_missing[@]}"
else
	step "apt packages already installed: ${BASE_PACKAGES[*]}"
fi

if docker_ready; then
	step "docker and compose plugin already installed"
else
	change "install the Docker engine and compose plugin from Docker's apt repository" docker_install
fi

# 3. mise itself, at the pinned version.
installed_mise="$(mise_installed_version)"
if [ "$installed_mise" = "${MISE_VERSION#v}" ]; then
	step "mise $MISE_VERSION already at $MISE_BIN"
else
	change "install mise $MISE_VERSION to $MISE_BIN from https://mise.run (was: ${installed_mise:-none})" install_mise
fi

# 4. The service user (this also creates the docker group when it is missing).
user_conflict || true
if user_ready; then
	step "service user $RUNNER_USER already uid $RUNNER_UID, gid $RUNNER_GID, in docker"
else
	change "create service user $RUNNER_USER (uid $RUNNER_UID, gid $RUNNER_GID, system, no login, in docker)" user_make
fi

# 5. DOCKER_GID: the VM's docker group id, written into .env only when the line is empty.
if [ -n "$DOCKER_GID" ]; then
	step "DOCKER_GID already set in $ENV_FILE"
elif [ "$DRY_RUN" -eq 1 ] && ! getent group docker >/dev/null; then
	echo "[dry-run] would: write DOCKER_GID into $ENV_FILE once the docker group exists"
	CHANGES=$((CHANGES + 1))
else
	gid="$(getent group docker | cut -d: -f3)"
	if [ -z "$gid" ]; then
		stop_or_note "no docker group on this VM after the Docker install; DOCKER_GID stays empty"
	else
		change "write DOCKER_GID=$gid into $ENV_FILE (the only edit to .env)" env_fill_docker_gid
		DOCKER_GID="$gid"
	fi
fi

# 6. The runner's data folder, owned by the service user.
if data_ready; then
	step "$RUNNER_DATA already owned by $RUNNER_USER"
else
	change "create $RUNNER_DATA owned by $RUNNER_USER" data_make
fi

# 7. The checkout's tools through mise, as the user who ran sudo. Each step counts only when it
# would change something: the trust check is read only.
trust_needed=0
trust_out="$(mise_as_user "$REPO_DIR" trust --show 2>/dev/null || true)"
if ! grep -q ': trusted$' <<< "$trust_out"; then
	trust_needed=1
fi
install_needed=$trust_needed
if [ -n "$(mise_as_user "$REPO_DIR" ls --missing 2>/dev/null || true)" ]; then
	install_needed=1
fi

if [ "$trust_needed" -eq 1 ]; then
	change "as $RUN_USER in $REPO_DIR: mise trust" mise_as_user "$REPO_DIR" trust
else
	step "checkout's mise config already trusted by $RUN_USER"
fi
if [ "$install_needed" -eq 1 ]; then
	change "as $RUN_USER in $REPO_DIR: mise install" mise_as_user "$REPO_DIR" install
else
	step "mise tools already installed for $RUN_USER"
fi

# 8. The two blocks (FG-FR-05).
firewall_step

# 9. Restart on boot.
boot_enable docker
boot_enable ufw

# 10. What to run next.
echo ""
echo "Start the runner from $REPO_DIR:"
echo "  docker compose -f $COMPOSE_FILE up -d"
echo "changes: $CHANGES"
exit 0
