#!/usr/bin/env bash
# Prepare a golden-image VM as a Docker host (SK-FR-09, ST116): installs the Docker engine and the
# compose plugin from Docker's own apt repository, adds you to the docker group, and enables Docker
# at boot where systemd runs. Run as your normal user: ./host/prepare.sh. It calls sudo itself.
# Prints one [step] or [change] line per item and ends with "changes: n"; a rerun ends "changes: 0".
# It does not set up ssh, ufw, cifs or git (the baseline does), mounts nothing and installs no mise.
set -euo pipefail

SCRIPT_VERSION=1
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
CHANGES=0

step() { echo "[step] $*"; }

stop() {
	echo "prepare.sh: $*" >&2
	exit 1
}

# The only place a machine change happens.
change() {
	local description=$1
	shift
	CHANGES=$((CHANGES + 1))
	echo "[change] $description"
	"$@"
}

# Docker's apt key and repository file are both in place (read only).
repo_ready() {
	[ -f "$DOCKER_KEY" ] && [ -f "$DOCKER_SOURCES" ]
}

# Docker's key is checked against its fingerprint before it is trusted; nothing is installed when it differs.
add_repo() {
	local tmp_dir codename fingerprints
	codename=$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release)
	tmp_dir=$(mktemp -d)
	mkdir -m 700 "$tmp_dir/gnupg"
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp_dir/docker.asc"
	fingerprints=$(gpg --homedir "$tmp_dir/gnupg" --show-keys --with-colons "$tmp_dir/docker.asc")
	if ! grep -qxF "fpr:::::::::${DOCKER_KEY_FPR}:" <<< "$fingerprints"; then
		rm -rf "$tmp_dir"
		stop "Docker's key does not have fingerprint $DOCKER_KEY_FPR; nothing installed"
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
}

# The engine and the compose plugin both answer (read only).
docker_ready() {
	command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

install_docker() {
	sudo apt-get update -qq
	sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-compose-plugin
}

# Is the user listed in the docker group in /etc/group? Read only; a new login is needed for it to apply.
in_docker_group() {
	getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qx "$(id -un)"
}

# --- the run ---------------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
	stop "run as your normal user, not root; the script calls sudo itself"
fi

step "prepare.sh version $SCRIPT_VERSION"
if [ "$(sed -n 's/^ID=//p' /etc/os-release)" != ubuntu ]; then
	stop "not Ubuntu (apt); nothing changed"
fi
for tool in sudo curl gpg; do
	command -v "$tool" >/dev/null 2>&1 || stop "$tool is missing; the golden image provides it. Nothing changed"
done

if repo_ready; then
	step "Docker's apt repository already set up ($DOCKER_SOURCES)"
else
	change "add Docker's apt repository, key fingerprint $DOCKER_KEY_FPR (sudo)" add_repo
fi

if docker_ready; then
	step "docker engine and compose plugin already installed"
else
	change "install docker-ce and docker-compose-plugin from Docker's repository (sudo)" install_docker
fi

if in_docker_group; then
	step "$(id -un) already in the docker group"
else
	change "add $(id -un) to the docker group (sudo); a new login applies it" sudo usermod -aG docker "$(id -un)"
fi

if [ -d /run/systemd/system ]; then
	if [ "$(systemctl is-enabled docker 2>/dev/null || true)" = enabled ]; then
		step "docker already enabled at boot"
	else
		change "enable docker at boot (sudo)" sudo systemctl enable docker
	fi
else
	echo "[step] no systemd running here; docker is not enabled at boot (not counted as a change)"
fi

echo "changes: $CHANGES"
