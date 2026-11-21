#!/usr/bin/env bash
# The one-command setup for the monitor's VM (HL-FR-19, MVP 2), built on the golden image
# (docs/REF-golden-image.md): Docker, mise, the monitor's service user and folders, the Gatus config
# and the ufw ports, so that
#   sudo docker compose -f compose/monitor/docker-compose.yml up -d
# brings the monitor up, and it comes back after a reboot. Run as your normal user, at the root of
# the stacks checkout: ./setup.sh. It calls sudo itself for each step that needs it.
#
# - Refuses a bare root login, and stops with a plain message if not Ubuntu (apt). The golden image
#   provides curl, gpg, sudo and ca-certificates; if one is missing it stops and names it. It
#   installs none of the baseline's packages (ssh, ufw, cifs-utils, git).
# - Settles six values before anything changes: an environment variable of the same name skips its
#   prompt; else each is asked for with a default (Enter accepts). Defaults: MONITOR_BIND the default
#   route's source address (never a Docker bridge), NTFY_TOPIC a generated word, the rest fixed. A
#   value already in the env file is kept with no prompt (ST104), so a rerun asks only for a value
#   the file lacks; --yes takes every default; no answer and no default stops naming the value.
#   Answers go to compose/monitor/.env (mode 600) when they differ from it. The topic is never printed.
# - Installs what mise cannot, each only when missing: the Docker engine and compose plugin from
#   Docker's apt repository (the signing key must have Docker's published fingerprint), mise at
#   MISE_VERSION, the service user (system, no login, in the docker group), and $MONITOR_DIR with
#   gatus and ntfy inside, owned by that user.
# - In this checkout: mise trust and mise install, so mise.toml is the tool list.
# - Writes $MONITOR_DIR/gatus/config.yaml from `go run ./cmd/health generate health` (the stacks'
#   health files; the starter stays in the compose file), through a temp file and mv, only when its text differs.
# - The health sync's timer (ST247, HL-FR-13): health-sync.service and health-sync.timer in
#   /etc/systemd/system, run as this checkout's user, who joins the docker and monitor groups.
#   compose/monitor/health-sync-install.sh does it; without systemd it prints the command.
# - systemctl enable docker, so the containers restart on boot. Without systemd it counts no change
#   and prints the command to run.
# - ufw (ST264): compose/monitor/host.sh makes it default-deny and turns it on: SSH from MONITOR_ADMIN,
#   GATUS_PORT, NTFY_PORT and BESZEL_PORT from MONITOR_LAN, the same in DOCKER-USER. MONITOR_LAN defaults to
#   the default route's subnet; MONITOR_ADMIN to MONITOR_LAN; both may be set in the env file or the env.
# - --check changes nothing and needs no sudo prompt: it lists each item as ok or missing (the Docker
#   daemon too) and exits non-zero if anything is missing. --dry-run prints every step and changes nothing.
# - Last, it prints the two addresses as "once started" and asks "Start the monitor now? [Y/n]" (yes by
#   default), or says "monitor already running" and asks nothing. It starts the monitor only on a yes at
#   a terminal; --yes, no terminal and --dry-run never do.
# - Every machine change goes through change(), which --dry-run skips. The last line is changes: n.
# change() runs the step functions indirectly through "$@", which shellcheck cannot see.
# shellcheck disable=SC2329
set -euo pipefail

# The mise version, copied from workbench/bootstrap/mise.version (the workbench repo). This repo has
# no bootstrap/ folder, so the value lives here; when the workbench's file changes, change this too.
MISE_VERSION=v2026.11.8

usage() {
	echo "usage: ./setup.sh [--yes | --dry-run | --check]"
	echo "  --yes       take every default without asking"
	echo "  --check     say whether the machine is ready; changes nothing, no sudo prompt"
	echo "  --dry-run   print every step with the defaults, change nothing"
}

usage_error() {
	echo "setup.sh: $*" >&2
	usage >&2
	exit 2
}

DRY_RUN=0
CHECK=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY_RUN=1 ;;
		--check) CHECK=1 ;;
		--yes) ASSUME_YES=1 ;;
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

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="$REPO_DIR/compose/monitor/.env"
ENV_EXAMPLE="$REPO_DIR/compose/monitor/.env.example"
COMPOSE_FILE=compose/monitor/docker-compose.yml
MISE_BIN=/usr/local/bin/mise
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
IMAGE_TOOLS=(curl gpg sudo)
ENV_KEYS=(MONITOR_USER MONITOR_DIR MONITOR_BIND GATUS_PORT NTFY_PORT NTFY_TOPIC)
SYSTEMD_RUN_DIR=/run/systemd/system

# The checkout's user: whoever runs this script. Root is refused in preflight.
RUN_USER="$(id -un)"
CHANGES=0
MISSING=()
declare -A ENV_VAL=()
declare -A STORED=()
GATUS_DIR=""
GATUS_CONFIG=""

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

# Reads the wanted values from the env file, if there is one, with a plain loop. Never sourced.
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
		for want in "${ENV_KEYS[@]}"; do
			if [ "$key" = "$want" ]; then
				ENV_VAL[$want]="$value"
			fi
		done
	done < "$ENV_FILE"
	for want in "${ENV_KEYS[@]}"; do
		STORED[$want]="${ENV_VAL[$want]:-}"
	done
}

# Sets the script's variables from the six values in ENV_VAL.
set_globals() {
	MONITOR_USER="${ENV_VAL[MONITOR_USER]:-}"
	MONITOR_DIR="${ENV_VAL[MONITOR_DIR]:-}"
	MONITOR_BIND="${ENV_VAL[MONITOR_BIND]:-}"
	GATUS_PORT="${ENV_VAL[GATUS_PORT]:-}"
	NTFY_PORT="${ENV_VAL[NTFY_PORT]:-}"
	GATUS_DIR="$MONITOR_DIR/gatus"
	GATUS_CONFIG="$GATUS_DIR/config.yaml"
}

# The fixed default of a value, or the cheap attempt for MONITOR_BIND (empty when there is none).
# One default-route lookup. Never an address on a Docker bridge: the default bridge's 172.17.0.0/16,
# or any address on a docker or br- interface.
default_for() {
	local src bridges
	case "$1" in
		MONITOR_BIND)
			src="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
			bridges="$(ip -o -4 addr show 2>/dev/null | awk '$2 ~ /^(docker|br-)/ {print $4}' || true)"
			if [[ -n $src && $src != 172.17.* ]] && ! grep -qF "${src}/" <<< "$bridges"; then
				echo "$src"
			fi
			;;
		NTFY_TOPIC) openssl rand -hex 8 ;;
		MONITOR_USER) echo monitor ;;
		MONITOR_DIR) echo /srv/monitor ;;
		GATUS_PORT) echo 8081 ;;
		NTFY_PORT) echo 8090 ;;
	esac
}

# Why a value has no default, on one line. MONITOR_BIND has no default when there is no route tool
# (ip, from iproute2) or no default route to read the address from.
no_default_reason() {
	local why="no usable default-route address (none, or only a Docker bridge such as 172.17.x.x)"
	if [ "$1" != MONITOR_BIND ]; then
		echo "$1 has no default here: set it in the environment or in $ENV_FILE"
		return 0
	fi
	command -v ip >/dev/null 2>&1 || why="the route tool ip is missing (package iproute2: sudo apt-get install -y iproute2)"
	echo "MONITOR_BIND has no default: $why. Run ./setup.sh again and type this machine's address at the prompt (hostname -I prints them; pick the one that is not a Docker bridge), or set MONITOR_BIND in the environment or in $ENV_FILE"
}

# Settles one value into ENV_VAL. An environment variable of the same name wins, with no prompt.
# Otherwise asks, with the stored or default value as the default; no answer (or no terminal) takes
# it. The topic is never shown.
settle() {
	local name=$1 def answer=""
	if [ -n "${!name:-}" ]; then
		ENV_VAL[$name]="${!name}"
		return 0
	fi
	def="${ENV_VAL[$name]:-}"
	[ -n "$def" ] || def="$(default_for "$name")"
	if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ -z "${ENV_VAL[$name]:-}" ]; then
		printf '%s [%s]: ' "$name" "$([ "$name" = NTFY_TOPIC ] && echo hidden || echo "$def")" >&2
		read -r answer || answer=""
	fi
	[ -n "$answer" ] || answer="$def"
	if [ -z "$answer" ]; then
		stop_or_note "$(no_default_reason "$name")"
		return 1
	fi
	if ! [[ $answer =~ ^[A-Za-z0-9._/:-]+$ ]] || [[ $name == *_PORT && ! $answer =~ ^[0-9]+$ ]]; then
		stop_or_note "$name: use letters, digits and . _ / : - only (a port: digits only)"
		return 1
	fi
	ENV_VAL[$name]="$answer"
}

# The env file's text: the template with the settled values filled in, comments kept.
render_env() {
	local line key
	while IFS= read -r line || [ -n "$line" ]; do
		key="${line%%=*}"
		if [[ $line == *=* && $key =~ ^[A-Z_]+$ ]]; then
			echo "$key=${ENV_VAL[$key]}"
		else
			echo "$line"
		fi
	done < "$ENV_EXAMPLE"
}

# Writes the env file (mode 600, from mktemp) only when a value differs from the stored one.
write_env_file() {
	local tmp name same=1
	read_env
	# BESZEL_PORT is in the template but not asked: its stored value (or 8091) is written back, not the template's.
	ENV_VAL[BESZEL_PORT]="$(env_optional BESZEL_PORT 8091)"
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
	change "write $ENV_FILE (mode 600; the topic is not shown)" install -m 600 "$tmp" "$ENV_FILE"
	rm -f "$tmp"
}

# Prints the names of values that are empty or unset, and of ports that are not numbers. Never
# prints a value: the topic is a secret (HL-NFR-02).
env_problems() {
	local name
	for name in "${ENV_KEYS[@]}"; do
		if [ -z "${ENV_VAL[$name]:-}" ]; then
			echo "$name"
		fi
	done
	for name in GATUS_PORT NTFY_PORT; do
		if [ -n "${ENV_VAL[$name]:-}" ] && ! [[ ${ENV_VAL[$name]} =~ ^[0-9]+$ ]]; then
			echo "$name (not a number)"
		fi
	done
}

# The problems on one line, comma separated; empty when every value is set.
env_problem_list() {
	env_problems | paste -sd, - | sed 's/,/, /g'
}

# --- preflight and steps ---------------------------------------------------

# The golden image's tools that this script uses. Named when missing; never installed here.
image_tools_missing() {
	local tool missing=()
	for tool in "${IMAGE_TOOLS[@]}"; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing+=("$tool")
		fi
	done
	if ! dpkg -s ca-certificates >/dev/null 2>&1; then
		missing+=(ca-certificates)
	fi
	echo "${missing[*]}"
}

# The apt package that provides a golden-image tool, when its name differs.
apt_package() {
	case "$1" in
		gpg) echo gnupg ;;
		ip) echo iproute2 ;;
		*) echo "$1" ;;
	esac
}

preflight() {
	local image_missing tool named="" pkgs=""
	if [ "$(id -u)" -eq 0 ]; then
		stop_or_note "run as your normal user, not root: setup.sh calls sudo itself for each step that needs it"
	fi
	if ! grep -qx 'ID=ubuntu' /etc/os-release 2>/dev/null || ! command -v apt-get >/dev/null 2>&1; then
		stop_or_note "not Ubuntu (apt-get not found, or /etc/os-release is not ID=ubuntu)"
	fi
	image_missing="$(image_tools_missing)"
	if [ -n "$image_missing" ]; then
		for tool in $image_missing; do
			named="${named:+$named, }$tool (package $(apt_package "$tool"))"
			pkgs="${pkgs:+$pkgs }$(apt_package "$tool")"
		done
		stop_or_note "the golden image should provide these and they are missing: $named. On any Ubuntu, install them with: sudo apt-get install -y $pkgs. This script installs none of them"
	fi
}

docker_ready() {
	command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

# Docker daemon answers: docker info, or sudo -n when not in the docker group. Read only.
docker_daemon_ready() {
	if [[ " $(id -nG) " == *" docker "* ]]; then
		docker info >/dev/null 2>&1
	else
		sudo -n docker info >/dev/null 2>&1
	fi
}

# Monitor containers running? Read only; sudo -n in --check and --dry-run (no prompt).
compose_running() {
	local sudo_cmd=(sudo) ids
	if [ "$CHECK" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
		sudo_cmd=(sudo -n)
	fi
	ids="$(cd "$REPO_DIR" && "${sudo_cmd[@]}" docker compose -f "$COMPOSE_FILE" ps --status running -q 2>/dev/null || true)"
	[ -n "$ids" ]
}

# Docker's own apt repository, the official route. Its published signing key is read and checked
# against the fingerprint above before apt trusts it. Nothing is generated.
docker_install() {
	local codename tmp_dir fingerprints
	codename="$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release)"
	if [ -z "$codename" ]; then
		codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
	fi
	tmp_dir="$(mktemp -d)"
	mkdir -m 700 "$tmp_dir/gnupg"
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp_dir/docker.asc"
	fingerprints="$(gpg --homedir "$tmp_dir/gnupg" --show-keys --with-colons "$tmp_dir/docker.asc")"
	if ! grep -qxF "fpr:::::::::${DOCKER_KEY_FPR}:" <<< "$fingerprints"; then
		rm -rf "$tmp_dir"
		echo "setup.sh: Docker's key does not have fingerprint $DOCKER_KEY_FPR; nothing installed" >&2
		return 1
	fi
	cat > "$tmp_dir/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Signed-By: $DOCKER_KEY
EOF
	sudo install -d -m 0755 /etc/apt/keyrings
	sudo install -m 0644 "$tmp_dir/docker.asc" "$DOCKER_KEY"
	sudo install -m 0644 "$tmp_dir/docker.sources" "$DOCKER_SOURCES"
	rm -rf "$tmp_dir"
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

# Runs mise in the folder given, as this user.
mise_run() {
	local dir=$1
	shift
	env MISE_YES=1 "$MISE_BIN" -C "$dir" "$@"
}

user_ready() {
	local groups
	id -u "$MONITOR_USER" >/dev/null 2>&1 || return 1
	groups=" $(id -nG "$MONITOR_USER") "
	[[ $groups == *" docker "* ]]
}

user_make() {
	if ! getent group docker >/dev/null; then
		sudo groupadd --system docker
	fi
	if ! id -u "$MONITOR_USER" >/dev/null 2>&1; then
		sudo useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$MONITOR_USER"
	fi
	sudo usermod -aG docker "$MONITOR_USER"
}

dirs_ready() {
	local dir
	for dir in "$MONITOR_DIR" "$MONITOR_DIR/gatus" "$MONITOR_DIR/ntfy"; do
		if [ ! -d "$dir" ] || [ "$(stat -c %U "$dir")" != "$MONITOR_USER" ]; then
			return 1
		fi
	done
}

dirs_make() {
	sudo install -d -o "$MONITOR_USER" -g "$(id -gn "$MONITOR_USER")" \
		"$MONITOR_DIR" "$MONITOR_DIR/gatus" "$MONITOR_DIR/ntfy"
}

# Moves a generated config into place as the service user's file: staged beside the target, then
# mv, so the file is replaced in one step.
write_gatus_config() {
	local tmp=$1 staged="$GATUS_DIR/.config.yaml.new"
	sudo install -m 0644 -o "$MONITOR_USER" -g "$(id -gn "$MONITOR_USER")" "$tmp" "$staged"
	sudo mv -f "$staged" "$GATUS_CONFIG"
}

# Generates the Gatus config into a temp file, and writes it only when its text differs.
gatus_config_step() {
	local tmp
	if [ "$DRY_RUN" -eq 1 ]; then
		CHANGES=$((CHANGES + 1))
		echo "[dry-run] would: write $GATUS_CONFIG from health, if its text differs"
		return 0
	fi
	tmp="$(mktemp)"
	if ! mise_run "$REPO_DIR" exec -- go run ./cmd/health generate health > "$tmp"; then
		rm -f "$tmp"
		echo "setup.sh: the health generator failed; $GATUS_CONFIG is unchanged" >&2
		exit 1
	fi
	if [ -f "$GATUS_CONFIG" ] && cmp -s "$tmp" "$GATUS_CONFIG"; then
		rm -f "$tmp"
		step "$GATUS_CONFIG already current"
		return 0
	fi
	change "write $GATUS_CONFIG (generated from health)" write_gatus_config "$tmp"
	rm -f "$tmp"
}

systemd_present() {
	[ -d "$SYSTEMD_RUN_DIR" ]
}

# The ufw rules listing. ufw needs root to list rules: run mode uses sudo (it may prompt); --check
# uses sudo -n and returns non-zero when that would need a password. Prints nothing when ufw is
# not installed.
ufw_listing() {
	command -v ufw >/dev/null 2>&1 || return 0
	if [ "$CHECK" -eq 1 ]; then
		sudo -n ufw status 2>/dev/null
	else
		sudo ufw status
	fi
}

# The LAN's CIDR: the subnet of the default route's interface. Empty when there is no default route.
lan_default() {
	local dev
	dev="$(ip -o -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
	[ -n "$dev" ] || return 0
	ip -o -4 route show dev "$dev" proto kernel scope link 2>/dev/null | awk '{ print $1; exit }'
}

# A value from the env file (MONITOR_LAN, MONITOR_ADMIN, BESZEL_PORT: not asked, so not in ENV_KEYS),
# else the default given. Read with sed, never sourced.
env_optional() {
	local v=""
	[ -f "$ENV_FILE" ] && v="$(sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1)"
	echo "${v:-$2}"
}

# --- start the monitor -----------------------------------------------------

# Asks "Start the monitor now? [Y/n]" (yes by default). Starts only on an explicit yes (Enter counts)
# at a real terminal. --yes, no terminal and --dry-run never start; they print the command instead.
start_offer() {
	local answer="" cmd="sudo docker compose -f $COMPOSE_FILE up -d"
	if compose_running; then
		echo "monitor already running: its containers are up, so nothing is started and no change is counted"
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		echo "[dry-run] would ask: Start the monitor now? [Y/n]; on yes, run from $REPO_DIR: $cmd"
		return 0
	fi
	if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
		echo "Not started (--yes or no terminal). To start it, run from $REPO_DIR: $cmd"
		return 0
	fi
	printf 'Start the monitor now? [Y/n] ' >&2
	read -r answer || answer=""
	case "$answer" in
		'' | y | Y | yes | Yes | YES) ;;
		*)
			echo "Not started. To start it later, run from $REPO_DIR: $cmd"
			return 0
			;;
	esac
	CHANGES=$((CHANGES + 1))
	echo "[change] starting the monitor: $cmd"
	if (cd "$REPO_DIR" && sudo docker compose -f "$COMPOSE_FILE" up -d); then
		echo "monitor started: the addresses above now answer"
	else
		echo "setup.sh: the monitor did not start (docker printed why above)" >&2
		return 1
	fi
}

# The health sync's units (ST247), sourced for --check and the run.
# The installer is linted by its own test task (mise run monitor-test), not followed from here.
# shellcheck source=/dev/null
source "$REPO_DIR/compose/monitor/health-sync-install.sh"

# --- --check ---------------------------------------------------------------

run_check() {
	local ver problems listing port
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
	if docker_daemon_ready; then
		report ok "docker daemon" "answers"
	else
		echo "docker daemon: not running"
		MISSING+=("docker daemon")
	fi

	if [ ! -f "$ENV_FILE" ]; then
		report missing "compose/monitor/.env" "not there; ./setup.sh asks for the values and writes it"
		problems="file"
	else
		read_env
		set_globals
		problems="$(env_problem_list)"
		if [ -z "$problems" ]; then
			report ok "compose/monitor/.env" "every value set"
		else
			report missing "compose/monitor/.env" "not set: $problems"
		fi
	fi

	if [ -z "$problems" ]; then
		if user_ready; then
			report ok "service user $MONITOR_USER" "in the docker group"
		else
			report missing "service user $MONITOR_USER" "missing, or not in the docker group"
		fi
		if dirs_ready; then
			report ok "monitor folders" "$MONITOR_DIR with gatus and ntfy, owned by $MONITOR_USER"
		else
			report missing "monitor folders" "$MONITOR_DIR with gatus and ntfy owned by $MONITOR_USER"
		fi
		if [ -f "$GATUS_CONFIG" ]; then
			report ok "gatus config" "$GATUS_CONFIG"
		else
			report missing "gatus config" "$GATUS_CONFIG not written"
		fi
	else
		report missing "service user, monitor folders and gatus config" "they need the env file first"
	fi

	local trust_out
	trust_out="$(mise_run "$REPO_DIR" trust --show 2>/dev/null || true)"
	if grep -q ': trusted$' <<< "$trust_out" &&
		[ -z "$(mise_run "$REPO_DIR" ls --missing 2>/dev/null || true)" ]; then
		report ok "mise tools in the checkout" "trusted, installed"
	else
		report missing "mise tools in the checkout" "not trusted, or a tool is not installed"
	fi

	if ! systemd_present; then
		echo "docker at boot: not applicable (no systemd)"
	elif systemctl is-enabled --quiet docker; then
		report ok "docker at boot" "enabled"
	else
		report missing "docker at boot" "not enabled"
	fi

	if [ -z "$problems" ]; then
		hs_check
	else
		report missing "health-sync timer and user" "they need the env file first"
	fi

	if ! command -v ufw >/dev/null 2>&1; then
		report missing "ufw" "not installed: sudo apt-get install -y ufw (the golden image provides it)"
	elif [ -n "$problems" ]; then
		echo "ufw: not checked until the env file is complete"
	elif ! listing="$(ufw_listing)"; then
		echo "ufw: not read without a sudo prompt; ./setup.sh (run mode) checks it"
	elif ! grep -q '^Status: active' <<< "$listing"; then
		report missing "ufw active" "ufw is off: ./setup.sh (run mode) sets the monitor's rules and turns it on"
	else
		for port in "$GATUS_PORT" "$NTFY_PORT"; do
			if grep -Eq "^${port}/tcp[[:space:]]+ALLOW" <<< "$listing"; then
				report ok "ufw allows ${port}/tcp" "active"
			else
				report missing "ufw allows ${port}/tcp" "ufw is active and the port is not open"
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

if [ "$CHECK" -eq 1 ]; then
	run_check
fi

# --- run -------------------------------------------------------------------

preflight
step "checkout: $REPO_DIR"
step "user: $RUN_USER"
step "mise version (pinned here from workbench/bootstrap/mise.version): $MISE_VERSION"

# 1. The values: asked for with defaults, then written to the env file if they differ from it.
if [ ! -f "$ENV_EXAMPLE" ]; then
	stop_or_note "missing $ENV_EXAMPLE, the template for the env file"
	echo "changes: $CHANGES"
	exit 0
fi
write_env_file
set_globals
problems="$(env_problem_list)"
if [ -n "$problems" ]; then
	stop_or_note "set these in $ENV_FILE: $problems"
	echo "changes: $CHANGES"
	exit 0
fi

# 2. Install what mise cannot: Docker, from its own apt repository.
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

# 4. The service user and the monitor's folders.
if user_ready; then
	step "service user $MONITOR_USER already in the docker group"
else
	change "create service user $MONITOR_USER (system, no login, in the docker group) (sudo)" user_make
fi

if dirs_ready; then
	step "$MONITOR_DIR, gatus and ntfy already owned by $MONITOR_USER"
else
	change "create $MONITOR_DIR with gatus and ntfy, owned by $MONITOR_USER (sudo)" dirs_make
fi

# 5. The checkout's tools through mise. Each step counts only when it would change something: the
# trust check is read only.
trust_needed=0
trust_out="$(mise_run "$REPO_DIR" trust --show 2>/dev/null || true)"
if ! grep -q ': trusted$' <<< "$trust_out"; then
	trust_needed=1
fi
install_needed=$trust_needed
if [ -n "$(mise_run "$REPO_DIR" ls --missing 2>/dev/null || true)" ]; then
	install_needed=1
fi

if [ "$trust_needed" -eq 1 ]; then
	change "$RUN_USER in $REPO_DIR: mise trust" mise_run "$REPO_DIR" trust
else
	step "checkout's mise config already trusted"
fi
if [ "$install_needed" -eq 1 ]; then
	change "$RUN_USER in $REPO_DIR: mise install" mise_run "$REPO_DIR" install
else
	step "mise tools already installed"
fi

# 6. The Gatus config from the health files.
gatus_config_step

# 7. Restart on boot. Without systemd, nothing is changed and the command is printed.
if ! systemd_present; then
	echo "restart on boot: no systemd here, so docker is not enabled. Run this by hand: sudo systemctl enable docker"
elif systemctl is-enabled --quiet docker; then
	step "docker already enabled at boot"
else
	change "systemctl enable docker (sudo)" sudo systemctl enable docker
fi

# 7b. The health sync's timer (ST247): see compose/monitor/health-sync-install.sh.
hs_run

# 8. ufw (ST264): compose/monitor/host.sh sets the rules and turns ufw on. Its "changes: n" joins ours. A
# dry run runs it with --dry-run (no sudo, nothing changed) and prints what it would do.
ufw_step() {
	local runner=(sudo) flag=() out="" status=0 n
	if [ "$DRY_RUN" -eq 1 ]; then runner=(); flag=(--dry-run); fi
	out="$("${runner[@]}" env MONITOR_LAN="$MONITOR_LAN" MONITOR_ADMIN="$MONITOR_ADMIN" \
		GATUS_PORT="$GATUS_PORT" NTFY_PORT="$NTFY_PORT" BESZEL_PORT="$BESZEL_PORT" \
		bash "$REPO_DIR/compose/monitor/host.sh" "${flag[@]}" 2>&1)" || status=$?
	grep -v '^changes: ' <<< "$out" || true
	n="$(sed -n 's/^changes: //p' <<< "$out" | tail -n 1)"
	CHANGES=$((CHANGES + ${n:-0}))
	if [ "$status" -ne 0 ]; then
		stop_or_note "ufw was not set (host.sh said why above)"
		return 0
	fi
	if [ "$DRY_RUN" -eq 0 ]; then
		echo "ufw: active, ports 22/tcp from $MONITOR_ADMIN, $GATUS_PORT/tcp, $NTFY_PORT/tcp, $BESZEL_PORT/tcp from $MONITOR_LAN"
	fi
}
MONITOR_LAN="${MONITOR_LAN:-$(env_optional MONITOR_LAN "$(lan_default)")}"
MONITOR_ADMIN="${MONITOR_ADMIN:-$(env_optional MONITOR_ADMIN "$MONITOR_LAN")}"
BESZEL_PORT="${BESZEL_PORT:-$(env_optional BESZEL_PORT 8091)}"
if [ -z "$MONITOR_LAN" ]; then
	stop_or_note "MONITOR_LAN has no default (no default route): set it in $ENV_FILE to the LAN's CIDR, for example 192.168.1.0/24"
else
	ufw_step
fi

# 9. The addresses apply only once the monitor is started; then offer to start it.
echo ""
echo "Gatus: http://$MONITOR_BIND:$GATUS_PORT (once started)   ntfy: http://$MONITOR_BIND:$NTFY_PORT (once started)"
start_status=0
start_offer || start_status=$?
echo "changes: $CHANGES"
exit "$start_status"
