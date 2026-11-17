#!/usr/bin/env bash
# The one-command setup for the forge VM (FG-FR-15, MVP 2, ST77): takes a VM made from the golden
# image (docs/REF-golden-image.md) to a host where the /data disk is checked, Docker runs, and
#   sudo docker compose -f compose/forge-vm/docker-compose.yml up -d
# starts Forgejo, and all of it comes back after a reboot. Run as your normal user, from a checkout
# of the stacks repo: ./compose/forge-vm/setup.sh (it calls sudo itself for each step that needs it).
#
# - Refuses a bare root login, and stops with a plain message if not Ubuntu (apt).
# - Settles the values in compose/forge-vm/.env before any other change (ST93): each is asked for with
#   its default (Enter accepts); an environment variable of the same name skips its prompt; --yes takes
#   every default; a rerun offers the stored values; no answer and no default stops naming the value.
#   The defaults and checks are in default_for and valid_answer. The file is written mode 600, only when
#   a value differs, and no password is ever printed.
# - Preflight, after the values: the image's packages (git, curl, ca-certificates, gnupg, cifs-utils,
#   ufw, openssh-server, sudo; none is installed here), /data a mounted filesystem separate from /, and
#   FORGE_DATA /data or under it. Otherwise it stops and prints the line that fixes it. It never creates
#   a network mount, never formats or partitions a disk.
# - Installs only what the image lacks, each when missing: the Docker engine and compose plugin from
#   Docker's apt repository (the signing key must have Docker's published fingerprint); mise at
#   MISE_VERSION; the service user FORGE_USER with FORGE_UID and FORGE_GID (system user, no login, in
#   the docker group); and FORGE_DATA, owned by that user. Then, as you, in this checkout: mise trust
#   and mise install, so mise.toml is the tool list. The script holds no tool version but mise's.
# - Checks that FORGE_UID can create and delete a file in FORGE_DATA (as that user, through sudo -u).
# - ufw: if active, allows tcp FORGE_PORT (once); if inactive, adds nothing and says so.
# - systemctl enable docker, so Docker comes back on boot. Without systemd it counts no change and
#   prints the command. The /data mount itself is the owner's /etc/fstab line (docs/RUNBOOK-forge.md).
# - --check changes nothing and needs no sudo: it lists each item as ok or missing and exits 1 if any
#   is missing. --dry-run prints every step and changes nothing. Every machine change goes through
#   change(), which --dry-run skips. A real run's last line is changes: n.
# - Health file (FG-FR-09, ST108): writes health/forge.toml with the VM's address (FORGE_BIND, so the
#   monitor needs no DNS), unless the file exists; it says commit health/forge.toml. Nothing is committed here.
# - Last, it prints the forge URL as "once started" and asks "Start the forge now? [Y/n]" (yes by
#   default). It starts the forge only on a yes at a terminal; --yes, no terminal and --dry-run never do.
# change() and ensure() run the step functions indirectly through "$@", which shellcheck cannot see.
# shellcheck disable=SC2329
# The env values are read by name (${!name}) in settle; shellcheck cannot see that, so SC2034 is off.
# shellcheck disable=SC2034
set -euo pipefail

# The mise version, copied from workbench/bootstrap/mise.version (the workbench repo), as the monitor's
# setup.sh does. When that file changes, change this too.
MISE_VERSION=v2026.11.8

usage() {
	echo "usage: ./compose/forge-vm/setup.sh [--yes | --dry-run | --check]"
	echo "  --yes       take every default without asking"
	echo "  --check     say whether the VM is ready; changes nothing, needs no sudo"
	echo "  --dry-run   print every step, change nothing"
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

MODE=run
if [ "$DRY_RUN" -eq 1 ]; then MODE=dry; fi
if [ "$CHECK" -eq 1 ]; then MODE=check; fi

if [ "$(id -u)" -eq 0 ]; then
	echo "setup.sh: run as your normal user, not root: ./compose/forge-vm/setup.sh (it calls sudo itself)" >&2
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
HEALTH_FILE="$REPO_DIR/health/forge.toml"
COMPOSE_FILE=compose/forge-vm/docker-compose.yml
DATA_MOUNT=/data
FIX_DATA="add the second disk to the VM, format it, mount it at /data through /etc/fstab: see docs/RUNBOOK-forge.md"
MISE_BIN=/usr/local/bin/mise
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
IMAGE_PACKAGES=(git curl ca-certificates gnupg cifs-utils ufw openssh-server sudo)
ENV_KEYS=(FORGE_USER FORGE_UID FORGE_GID FORGE_BIND FORGE_PORT FORGE_URL FORGE_DATA FORGE_ADMIN_USER FORGE_ADMIN_EMAIL FORGE_ADMIN_PASSWORD)
SYSTEMD_RUN_DIR=/run/systemd/system

# ENV_VAL holds the values in use, STORED the ones in the file. set_globals copies ENV_VAL to the FORGE_*
# names once settled; those are not set here, so an environment variable of the same name is not shadowed.
declare -A ENV_VAL=()
declare -A STORED=()

CHANGES=0
MISSING=()
ENV_PRESENT=0

step() { echo "[step] $*"; }

# A stop while settling: a real run exits 1; --dry-run says what a real run would stop on and returns 1.
stop_or_note() {
	if [ "$MODE" != dry ]; then echo "setup.sh: $*" >&2; exit 1; fi
	echo "[dry-run] a real run would stop: $*"
	return 1
}

# The only place a machine change happens. --dry-run prints it and skips it.
change() {
	local description=$1
	shift
	CHANGES=$((CHANGES + 1))
	if [ "$MODE" = dry ]; then
		echo "[dry-run] would: $description"
		return 0
	fi
	echo "[change] $description"
	"$@"
}

# A preflight item: passes when the predicate does. A real run stops here, before any change; --dry-run
# says it would stop and goes on; --check lists it as missing and goes on, so every gap shows at once.
need() {
	local label=$1 detail=$2
	shift 2
	if "$@" >/dev/null 2>&1; then
		if [ "$MODE" = check ]; then echo "$label: ok"; fi
		return 0
	fi
	if [ "$MODE" = check ]; then
		echo "$label: missing ($detail)"
		MISSING+=("$label")
	elif [ "$MODE" = dry ]; then
		echo "[dry-run] a real run would stop: $detail"
	else
		echo "setup.sh: $label: $detail" >&2
		exit 1
	fi
}

# A state the script makes. Passes when the predicate does (--check says ok). Otherwise --check says
# missing, and a real run or --dry-run runs the change through change().
ensure() {
	local label=$1 description=$2 predicate=$3 action=$4
	if "$predicate" >/dev/null 2>&1; then
		if [ "$MODE" = check ]; then echo "$label: ok"; fi
		return 0
	fi
	if [ "$MODE" = check ]; then
		echo "$label: missing ($description)"
		MISSING+=("$label")
		return 0
	fi
	change "$description" "$action"
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
		if [[ " ${ENV_KEYS[*]} " == *" $key "* ]]; then ENV_VAL[$key]="$value"; fi
	done < "$ENV_FILE"
	for want in "${ENV_KEYS[@]}"; do
		STORED[$want]="${ENV_VAL[$want]:-}"
	done
}

# Copies the settled values into the FORGE_* names the rest of the script uses.
set_globals() {
	local name
	for name in "${ENV_KEYS[@]}"; do printf -v "$name" '%s' "${ENV_VAL[$name]:-}"; done
}

# The default of a value: a fixed one, one cheap attempt (FORGE_BIND: one default-route lookup, never
# an address on a Docker bridge), a generated secret, or none (FORGE_ADMIN_EMAIL: the owner's).
default_for() {
	local src bridges
	case "$1" in
		FORGE_BIND)
			src="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
			bridges="$(ip -o -4 addr show 2>/dev/null | awk '$2 ~ /^(docker|br-)/ {print $4}')"
			if [[ -n $src && $src != 172.17.* ]] && ! grep -qF "${src}/" <<< "$bridges"; then
				echo "$src"
			fi
			;;
		FORGE_URL)
			if [ -n "${ENV_VAL[FORGE_BIND]:-}" ]; then
				echo "http://${ENV_VAL[FORGE_BIND]}:${ENV_VAL[FORGE_PORT]:-}/"
			fi
			;;
		FORGE_USER) echo forge ;;
		FORGE_UID | FORGE_GID) echo 1100 ;;
		FORGE_PORT) echo 3000 ;;
		FORGE_DATA) echo /data/forgejo ;;
		FORGE_ADMIN_USER) echo forge-admin ;;
		FORGE_ADMIN_PASSWORD) openssl rand -hex 24 ;;
	esac
}

# A value is one word with no spaces; the ids and port are digits; the admin email has one @.
valid_answer() {
	case "$1" in
		*_PORT | *_UID | *_GID) [[ $2 =~ ^[0-9]+$ ]] ;;
		FORGE_ADMIN_EMAIL) [[ $2 =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ;;
		*) [[ $2 =~ ^[^[:space:]]+$ ]] ;;
	esac
}

# Settles one value into ENV_VAL. An environment variable of the same name wins, with no prompt.
# Otherwise asks, with the stored or default value as the default; no answer (or no terminal) takes
# it. The password's prompt says hidden and typing is not echoed.
settle() {
	local name=$1 def answer=""
	if [ -n "${!name:-}" ]; then
		ENV_VAL[$name]="${!name}"
	else
		def="${ENV_VAL[$name]:-}"
		if [ -z "$def" ]; then def="$(default_for "$name")"; fi
		if [ "$MODE" = run ] && [ "$ASSUME_YES" -eq 0 ]; then
			if [ "$name" = FORGE_ADMIN_PASSWORD ]; then
				printf '%s [hidden]: ' "$name" >&2
				read -rs answer || true
				echo >&2
			else
				printf '%s [%s]: ' "$name" "${def:-no default}" >&2
				read -r answer || true
			fi
		fi
		if [ -z "$answer" ]; then answer="$def"; fi
		if [ -z "$answer" ]; then
			stop_or_note "$name has no default here: set it in the environment or in $ENV_FILE" || return 1
		fi
		ENV_VAL[$name]="$answer"
	fi
	if ! valid_answer "$name" "${ENV_VAL[$name]}"; then
		stop_or_note "$name: use one word with no spaces (the email has one @; the ids and port are digits)" || return 1
	fi
}

# The names of the values that are not valid (empty included), comma separated; empty when all are.
# Names only, never a value: the admin password is a secret.
env_problem_list() {
	local name out=""
	for name in "${ENV_KEYS[@]}"; do
		if ! valid_answer "$name" "${ENV_VAL[$name]:-}"; then out+="$name, "; fi
	done
	out="${out%, }"
	echo "$out"
}

env_values_ok() {
	[ -z "$(env_problem_list)" ]
}

# The env file's text: the template with the settled values filled in, comments kept.
render_env() {
	local line key
	while IFS= read -r line || [ -n "$line" ]; do
		key="${line%%=*}"
		if [[ $line == *=* && $key =~ ^[A-Z_]+$ ]]; then echo "$key=${ENV_VAL[$key]}"; else echo "$line"; fi
	done < "$ENV_EXAMPLE"
}

# Settles every value, then writes the env file (mode 600, from a temp file) only when one differs from
# the stored one. A stop (no answer and no default, a bad value) exits before anything is written.
write_env_file() {
	local tmp name same=1
	read_env
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
	change "write $ENV_FILE (mode 600; the password is not shown)" install -m 600 "$tmp" "$ENV_FILE"
	rm -f "$tmp"
}

# --- preflight predicates (read only) ---------------------------------------

os_is_ubuntu() {
	grep -qx 'ID=ubuntu' /etc/os-release 2>/dev/null && command -v apt-get >/dev/null 2>&1
}

package_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# /data is a filesystem of its own: its source differs from /'s and it is the mount point itself.
data_is_mount() {
	local data_src root_src target
	data_src="$(findmnt -n -o SOURCE --target "$DATA_MOUNT" 2>/dev/null || true)"
	root_src="$(findmnt -n -o SOURCE --target / 2>/dev/null || true)"
	target="$(findmnt -n -o TARGET --target "$DATA_MOUNT" 2>/dev/null || true)"
	[ -n "$data_src" ] && [ "$data_src" != "$root_src" ] && [ "$target" = "$DATA_MOUNT" ]
}

# FORGE_DATA is /data or a folder under it, with no .. in it.
data_path_ok() {
	case "$FORGE_DATA" in
		/data | /data/*) ;;
		*) return 1 ;;
	esac
	case "$FORGE_DATA" in
		*/../* | */..) return 1 ;;
	esac
	return 0
}

# The service user is absent, or already has the id FORGE_UID (never a second, different one).
user_id_ok() {
	! id -u "$FORGE_USER" >/dev/null 2>&1 || [ "$(id -u "$FORGE_USER")" = "$FORGE_UID" ]
}

# --- tools and steps (state checks, then the change) ------------------------

docker_ready() {
	command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

# Docker's own apt repository, the official route. Its published signing key is read and checked
# against the fingerprint above before apt trusts it. Nothing is generated.
docker_install() {
	local codename tmp_home key_part
	codename="$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release)"
	if [ -z "$codename" ]; then
		codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
	fi
	tmp_home="$(mktemp -d)"
	key_part="$(mktemp)"
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_part"
	if ! gpg --homedir "$tmp_home" --show-keys --with-colons "$key_part" |
		grep -qxF "fpr:::::::::${DOCKER_KEY_FPR}:"; then
		rm -rf "$tmp_home" "$key_part"
		echo "setup.sh: Docker's key does not have fingerprint $DOCKER_KEY_FPR; nothing installed" >&2
		return 1
	fi
	rm -rf "$tmp_home"
	sudo install -d -m 0755 /etc/apt/keyrings
	sudo install -m 0644 "$key_part" "$DOCKER_KEY"
	rm -f "$key_part"
	printf '%s\n' \
		"Types: deb" \
		"URIs: https://download.docker.com/linux/ubuntu" \
		"Suites: $codename" \
		"Components: stable" \
		"Signed-By: $DOCKER_KEY" | sudo tee "$DOCKER_SOURCES" >/dev/null
	sudo apt-get update -qq
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-compose-plugin
}

mise_ready() {
	[ -x "$MISE_BIN" ] && [ "$("$MISE_BIN" --version 2>/dev/null | awk '{print $1}')" = "${MISE_VERSION#v}" ]
}

mise_install_bin() {
	curl -fsSL https://mise.run | sudo env MISE_VERSION="$MISE_VERSION" MISE_INSTALL_PATH="$MISE_BIN" sh
}

# Runs mise on the checkout as this user (no sudo: the checkout and its tools are the user's).
mise_trusted() {
	"$MISE_BIN" -C "$REPO_DIR" trust --show 2>/dev/null | grep -q ': trusted$'
}

mise_trust() {
	MISE_YES=1 "$MISE_BIN" -C "$REPO_DIR" trust
}

mise_tools_ready() {
	local missing
	mise_ready || return 1
	missing="$("$MISE_BIN" -C "$REPO_DIR" ls --missing 2>/dev/null)" || return 1
	[ -z "$missing" ]
}

mise_install_tools() {
	MISE_YES=1 "$MISE_BIN" -C "$REPO_DIR" install
}

user_ready() {
	local groups
	id -u "$FORGE_USER" >/dev/null 2>&1 || return 1
	[ "$(id -u "$FORGE_USER")" = "$FORGE_UID" ] && [ "$(id -g "$FORGE_USER")" = "$FORGE_GID" ] || return 1
	groups=" $(id -nG "$FORGE_USER") "
	[[ $groups == *" docker "* ]]
}

# A system user, no login, in the docker group, with the ids the compose file expects.
user_make() {
	if ! getent group "$FORGE_USER" >/dev/null; then
		sudo groupadd --system --gid "$FORGE_GID" "$FORGE_USER"
	fi
	if ! id -u "$FORGE_USER" >/dev/null 2>&1; then
		sudo useradd --system --uid "$FORGE_UID" --gid "$FORGE_GID" --no-create-home \
			--shell /usr/sbin/nologin "$FORGE_USER"
	fi
	if ! getent group docker >/dev/null; then
		sudo groupadd --system docker
	fi
	sudo usermod -aG docker "$FORGE_USER"
}

data_dir_ready() {
	[ -d "$FORGE_DATA" ] && [ "$(stat -c '%u:%g' "$FORGE_DATA")" = "$FORGE_UID:$FORGE_GID" ]
}

data_dir_make() {
	sudo install -d -o "$FORGE_UID" -g "$FORGE_GID" -m 0755 "$FORGE_DATA"
}

# The real check of the data path: FORGE_UID creates and deletes a file there. Runs only in a real run.
data_writable() {
	local probe="$FORGE_DATA/.setup-probe-$$"
	if ! sudo -u "#$FORGE_UID" sh -c 'touch "$1" && rm -f "$1"' sh "$probe"; then
		echo "setup.sh: uid $FORGE_UID cannot create a file in $FORGE_DATA; fix its owner or mode, then rerun" >&2
		exit 1
	fi
}

ufw_active() {
	grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null
}

ufw_port_ok() {
	local status
	status="$(sudo ufw status)"
	grep -qE "^${FORGE_PORT}/tcp[[:space:]]+ALLOW" <<< "$status"
}

ufw_allow() {
	sudo ufw allow "${FORGE_PORT}/tcp"
}

docker_enabled() {
	[ "$(systemctl is-enabled docker 2>/dev/null || true)" = enabled ]
}

docker_enable() {
	sudo systemctl enable docker
}

# --- the run ----------------------------------------------------------------

if [ "$MODE" != check ] && ! os_is_ubuntu; then
	echo "setup.sh: not Ubuntu (apt-get not found, or /etc/os-release is not ID=ubuntu)" >&2
	exit 1
fi
if [ "$MODE" = check ] && ! os_is_ubuntu; then
	echo "not Ubuntu: missing (apt-get not found, or /etc/os-release is not ID=ubuntu)"
	MISSING+=("ubuntu")
fi

# The values (ST93): asked for with defaults, then written to the env file when they differ from it.
# --check only reads the file and changes nothing.
if [ "$MODE" = check ]; then
	read_env
	if [ -f "$ENV_FILE" ]; then
		ENV_PRESENT=1
		set_globals
		need "env values" "fill in these values in compose/forge-vm/.env: $(env_problem_list)" env_values_ok
	else
		echo ".env: missing (./compose/forge-vm/setup.sh asks for the values and writes it)"
		MISSING+=(".env")
	fi
else
	write_env_file
	ENV_PRESENT=1
	set_globals
fi

# Preflight (before any further change): the image's packages, the data disk, the data path.
for package in "${IMAGE_PACKAGES[@]}"; do
	need "package $package" "not on the image: the golden image should have it; install it by hand, then rerun" \
		package_installed "$package"
done
if [ "$ENV_PRESENT" -eq 1 ]; then
	need "data disk" "/data is not a separate mounted disk. $FIX_DATA" data_is_mount
	need "FORGE_DATA" "must be /data or a folder under it, without .. : $FORGE_DATA" data_path_ok
	need "service user id" "user $FORGE_USER already exists with another id; fix it by hand, then rerun" user_id_ok
fi

if [ "$MODE" = check ] && [ "$ENV_PRESENT" -eq 0 ]; then
	echo "not all items could be checked: they need compose/forge-vm/.env"
fi

step "tools"
ensure "docker" "install the Docker engine and compose plugin from Docker's apt repository" \
	docker_ready docker_install
ensure "mise" "install mise $MISE_VERSION to $MISE_BIN" mise_ready mise_install_bin
# Each runs only when it would change something: a ready checkout reruns with no change.
ensure "mise trust" "mise trust in $REPO_DIR" mise_trusted mise_trust
ensure "mise tools" "mise install in $REPO_DIR (the tools in mise.toml)" mise_tools_ready mise_install_tools

if [ "$ENV_PRESENT" -eq 1 ]; then
	step "service user and data folder"
	ensure "service user" "create system user $FORGE_USER ($FORGE_UID:$FORGE_GID), no login, in the docker group" \
		user_ready user_make
	ensure "data folder" "create $FORGE_DATA owned by $FORGE_UID:$FORGE_GID" data_dir_ready data_dir_make
	if [ "$MODE" = run ]; then
		data_writable
		echo "data folder: uid $FORGE_UID can create and delete a file in $FORGE_DATA"
	elif [ "$MODE" = dry ]; then
		echo "[dry-run] would: check uid $FORGE_UID can create and delete a file in $FORGE_DATA"
	fi
fi

if [ "$ENV_PRESENT" -eq 1 ]; then
	step "firewall"
	if ! ufw_active; then
		echo "ufw: inactive, no rule added"
	elif [ "$MODE" = check ]; then
		echo "ufw: active (setup allows tcp $FORGE_PORT)"
	else
		ensure "ufw rule" "allow tcp $FORGE_PORT (ufw is active)" ufw_port_ok ufw_allow
	fi
fi

step "boot"
if [ ! -d "$SYSTEMD_RUN_DIR" ]; then
	echo "docker on boot: no systemd here; run by hand: sudo systemctl enable docker"
else
	ensure "docker on boot" "systemctl enable docker" docker_enabled docker_enable
fi

if [ "$MODE" = check ]; then
	if [ "${#MISSING[@]}" -eq 0 ]; then
		echo "ready: the forge VM is set up (run: sudo docker compose -f $COMPOSE_FILE up -d)"
		exit 0
	fi
	echo "not ready: ${#MISSING[@]} missing: $(IFS=,; echo "${MISSING[*]}")"
	exit 1
fi

# --- the health file (FG-FR-09, ST108) --------------------------------------

# The file the monitor reads: the same four parts as health/probe-a.toml. Written once; a rerun leaves it.
health_file_make() {
	printf '%s\n' \
		"# The forge's health file (FG-FR-09, ST108): written by compose/forge-vm/setup.sh from the VM's address." \
		"host = \"$FORGE_BIND\"" \
		"service = \"$FORGE_BIND:$FORGE_PORT\"" \
		"request = \"http://$FORGE_BIND:$FORGE_PORT/\"" \
		"expect_status = 200" \
		"needs = []" > "$HEALTH_FILE"
}

if [ "$ENV_PRESENT" -eq 1 ]; then
	step "health file"
	if [ -f "$HEALTH_FILE" ]; then
		echo "health/forge.toml: already there, left alone"
	else
		change "write health/forge.toml with the address $FORGE_BIND" health_file_make
		echo "commit health/forge.toml: the monitor reads it from git"
	fi
fi

# --- start the forge (ST94) -------------------------------------------------

# Asks "Start the forge now? [Y/n]" (yes by default). Starts only on an explicit yes (Enter counts) at a
# real terminal. --yes, no terminal and --dry-run never start; they print the command instead.
start_offer() {
	local answer="" cmd="sudo docker compose -f $COMPOSE_FILE up -d"
	if [ "$MODE" = dry ]; then
		echo "[dry-run] would ask: Start the forge now? [Y/n]; on yes, run from $REPO_DIR: $cmd"
		return 0
	fi
	if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
		echo "Not started (--yes or no terminal). To start it, run from $REPO_DIR: $cmd"
		return 0
	fi
	printf 'Start the forge now? [Y/n] ' >&2
	read -r answer || answer=""
	case "$answer" in
		'' | y | Y | yes | Yes | YES) ;;
		*)
			echo "Not started. To start it later, run from $REPO_DIR: $cmd"
			return 0
			;;
	esac
	CHANGES=$((CHANGES + 1))
	echo "[change] starting the forge: $cmd"
	if (cd "$REPO_DIR" && sudo docker compose -f "$COMPOSE_FILE" up -d); then
		echo "forge started: the forge URL above now answers"
	else
		echo "setup.sh: the forge did not start (docker printed why above)" >&2
		return 1
	fi
}

# The address applies only once the forge is started; then offer to start it.
echo "forge URL: $FORGE_URL (once started)"
start_status=0
start_offer || start_status=$?
if [ "$MODE" = dry ]; then
	echo "would change: $CHANGES (dry run: nothing changed)"
else
	echo "changes: $CHANGES"
fi
exit "$start_status"
