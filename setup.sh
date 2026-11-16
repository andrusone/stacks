#!/usr/bin/env bash
# The one-command setup for a plain Ubuntu Server VM (HL-FR-19, MVP 2): Docker, mise, the monitor's
# service user and folders, and the Gatus config, so that
#   docker compose -f compose/monitor/docker-compose.yml up -d
# brings the monitor up, and it comes back after a reboot. Run as: sudo ./setup.sh, at the root of
# the stacks checkout, from the login of the user who owns the checkout.
#
# - Stops with a plain message if not root, not Ubuntu (apt), or run without SUDO_USER.
# - Reads six values from compose/monitor/.env with a plain loop; the file is never sourced. If the
#   file is missing, copies .env.example to it (mode 600, owned by SUDO_USER), lists the variables
#   and exits 1 before anything else. A value that is empty or unset is named and stops the run.
#   The topic value is never printed.
# - Installs what mise cannot, each only when missing: the Docker engine and compose plugin from
#   Docker's apt repository (the signing key must have Docker's published fingerprint), mise at
#   MISE_VERSION, the service user (system, no login, in the docker group), and $MONITOR_DIR with
#   gatus and ntfy inside, owned by that user.
# - As SUDO_USER in this checkout: mise trust and mise install, so mise.toml is the tool list.
# - Writes $MONITOR_DIR/gatus/config.yaml from `go run ./cmd/health generate health-starter`,
#   through a temp file and mv, only when its text differs.
# - systemctl enable docker, so the containers restart on boot. Without systemd it counts no change
#   and prints the command to run.
# - --check changes nothing and needs no root: it lists each item as ok or missing and exits
#   non-zero if anything is missing. --dry-run prints every step and changes nothing.
# - Every machine change goes through change(), which --dry-run skips. The last line is changes: n.
# change() runs the step functions indirectly through "$@", which shellcheck cannot see.
# shellcheck disable=SC2329
set -euo pipefail

# The mise version, copied from workbench/bootstrap/mise.version (the workbench repo). This repo has
# no bootstrap/ folder, so the value lives here; when the workbench's file changes, change this too.
MISE_VERSION=v2026.11.8

usage() {
	echo "usage: sudo ./setup.sh [--dry-run | --check]"
	echo "  --check     say whether the machine is ready; changes nothing, needs no root"
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

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENV_FILE="$REPO_DIR/compose/monitor/.env"
ENV_EXAMPLE="$REPO_DIR/compose/monitor/.env.example"
COMPOSE_FILE=compose/monitor/docker-compose.yml
MISE_BIN=/usr/local/bin/mise
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
BASE_PACKAGES=(ca-certificates curl gnupg sudo)
ENV_KEYS=(MONITOR_USER MONITOR_DIR MONITOR_BIND GATUS_PORT NTFY_PORT NTFY_TOPIC)
SYSTEMD_RUN_DIR=/run/systemd/system

# The checkout's owner: the sudo caller. A --check run as the user itself uses that user's name.
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "$RUN_USER" 2>/dev/null || echo "$RUN_USER")"
CHANGES=0
MISSING=()
declare -A ENV_VAL=()
MONITOR_USER=""
MONITOR_DIR=""
MONITOR_BIND=""
GATUS_PORT=""
NTFY_PORT=""
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
	MONITOR_USER="${ENV_VAL[MONITOR_USER]:-}"
	MONITOR_DIR="${ENV_VAL[MONITOR_DIR]:-}"
	MONITOR_BIND="${ENV_VAL[MONITOR_BIND]:-}"
	GATUS_PORT="${ENV_VAL[GATUS_PORT]:-}"
	NTFY_PORT="${ENV_VAL[NTFY_PORT]:-}"
	GATUS_DIR="$MONITOR_DIR/gatus"
	GATUS_CONFIG="$GATUS_DIR/config.yaml"
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

preflight() {
	if [ "$(id -u)" -ne 0 ]; then
		stop_or_note "not root. Run it as: sudo ./setup.sh (from the login of the user who owns this checkout)"
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

user_ready() {
	local groups
	id -u "$MONITOR_USER" >/dev/null 2>&1 || return 1
	groups=" $(id -nG "$MONITOR_USER") "
	[[ $groups == *" docker "* ]]
}

user_make() {
	if ! getent group docker >/dev/null; then
		groupadd --system docker
	fi
	if ! id -u "$MONITOR_USER" >/dev/null 2>&1; then
		useradd --system --user-group --no-create-home --shell /usr/sbin/nologin "$MONITOR_USER"
	fi
	usermod -aG docker "$MONITOR_USER"
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
	install -d -o "$MONITOR_USER" -g "$(id -gn "$MONITOR_USER")" \
		"$MONITOR_DIR" "$MONITOR_DIR/gatus" "$MONITOR_DIR/ntfy"
}

# Generates the Gatus config into a temp file beside it, and moves it in only when its text differs.
gatus_config_step() {
	local tmp
	if [ "$DRY_RUN" -eq 1 ]; then
		CHANGES=$((CHANGES + 1))
		echo "[dry-run] would: write $GATUS_CONFIG from health-starter, if its text differs"
		return 0
	fi
	tmp="$(mktemp "$GATUS_DIR/config.yaml.XXXXXX")"
	if ! mise_as_user "$REPO_DIR" exec -- go run ./cmd/health generate health-starter > "$tmp"; then
		rm -f "$tmp"
		echo "setup.sh: the health generator failed; $GATUS_CONFIG is unchanged" >&2
		exit 1
	fi
	chown "$MONITOR_USER:$(id -gn "$MONITOR_USER")" "$tmp"
	chmod 644 "$tmp"
	if [ -f "$GATUS_CONFIG" ] && cmp -s "$tmp" "$GATUS_CONFIG"; then
		rm -f "$tmp"
		step "$GATUS_CONFIG already current"
		return 0
	fi
	change "write $GATUS_CONFIG (generated from health-starter)" mv -f "$tmp" "$GATUS_CONFIG"
}

systemd_present() {
	[ -d "$SYSTEMD_RUN_DIR" ]
}

# --- --check ---------------------------------------------------------------

run_check() {
	local ver problems
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

	if [ ! -f "$ENV_FILE" ]; then
		report missing "compose/monitor/.env" "not there; setup.sh copies .env.example to it"
		problems="file"
	else
		read_env
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
	trust_out="$(mise_as_user "$REPO_DIR" trust --show 2>/dev/null || true)"
	if grep -q ': trusted$' <<< "$trust_out" &&
		[ -z "$(mise_as_user "$REPO_DIR" ls --missing 2>/dev/null || true)" ]; then
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
	echo "Fill in these variables in $ENV_FILE, then run sudo ./setup.sh again:"
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

# 4. The service user and the monitor's folders.
if user_ready; then
	step "service user $MONITOR_USER already in the docker group"
else
	change "create service user $MONITOR_USER (system, no login, in the docker group)" user_make
fi

if dirs_ready; then
	step "$MONITOR_DIR, gatus and ntfy already owned by $MONITOR_USER"
else
	change "create $MONITOR_DIR with gatus and ntfy, owned by $MONITOR_USER" dirs_make
fi

# 5. The checkout's tools through mise, as the user who ran sudo. Each step counts only when it
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

# 6. The Gatus config from the health files.
gatus_config_step

# 7. Restart on boot. Without systemd, nothing is changed and the command is printed.
if ! systemd_present; then
	echo "restart on boot: no systemd here, so docker is not enabled. Run this by hand: sudo systemctl enable docker"
elif systemctl is-enabled --quiet docker; then
	step "docker already enabled at boot"
else
	change "systemctl enable docker" systemctl enable docker
fi

# 8. What to run next.
echo ""
echo "Start the monitor from $REPO_DIR:"
echo "  docker compose -f $COMPOSE_FILE up -d"
echo "Gatus: http://$MONITOR_BIND:$GATUS_PORT   ntfy: http://$MONITOR_BIND:$NTFY_PORT"
echo "changes: $CHANGES"
exit 0
