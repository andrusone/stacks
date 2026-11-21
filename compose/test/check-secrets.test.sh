#!/usr/bin/env bash
# The secrets check's test (ST268, HL-NFR-02). Temp git repos only, no network. Checks: a clean repo passes
# (an empty .env.example value, a $variable value, a placeholder, a setup.sh that writes its env file with
# install -m 600 through a sourced sibling); a tracked .env fails and names the file; a tracked *.env fails;
# a setup.sh that writes its env file without mode 600 fails and names the grep; a tracked file with a
# TOKEN value fails and names the file.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script="$here/../check-secrets.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# mkrepo NAME: an empty git repo in $tmp/NAME. The caller writes its files, then calls commit_all (git add).
mkrepo() {
	mkdir -p "$tmp/$1"
	git -C "$tmp/$1" init -q
}
commit_all() {
	git -C "$1" add -A
}

# A clean repo: every rule's allowed form.
clean="$tmp/clean"
mkrepo clean
printf 'API_TOKEN=\nPASSWORD=changeme\n' > "$clean/.env.example"
# shellcheck disable=SC2016 # the $ and ${ are fixture text, not expansions
printf 'NTFY_TOPIC=$topic\nSECRET="${OUTER_SECRET:-}"\n' > "$clean/app.conf"
cat > "$clean/setup.sh" <<'SETUP'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
. "$SCRIPT_DIR/lib.sh"
write_env
SETUP
cat > "$clean/lib.sh" <<'LIB'
write_env() {
	tmp="$(mktemp)"
	echo "NTFY_TOPIC=$topic" > "$tmp"
	install -m 600 "$tmp" "$ENV_FILE"
}
LIB
commit_all "$clean"
bash "$script" "$clean" > "$tmp/clean.out" 2>&1 || { cat "$tmp/clean.out" >&2; fail "clean repo should pass"; }
grep -qx 'ok check-secrets' "$tmp/clean.out" || fail "clean repo should print the ok line"

# (1) a tracked .env
envrepo="$tmp/env"
mkrepo env
printf 'NTFY_TOPIC=\n' > "$envrepo/.env"
commit_all "$envrepo"
if bash "$script" "$envrepo" > "$tmp/env.out" 2>&1; then fail "a tracked .env should fail"; fi
grep -q '^FAIL \.env: a tracked env file' "$tmp/env.out" || { cat "$tmp/env.out" >&2; fail "a tracked .env should be named"; }

# (1) a tracked *.env (the pins file shape)
pinsrepo="$tmp/pins"
mkrepo pins
mkdir -p "$pinsrepo/plex"
printf 'KOMETA_VERSION=2.4.8\n' > "$pinsrepo/plex/pins.env"
commit_all "$pinsrepo"
if bash "$script" "$pinsrepo" > "$tmp/pins.out" 2>&1; then fail "a tracked *.env should fail"; fi
grep -q '^FAIL plex/pins.env: a tracked env file' "$tmp/pins.out" || { cat "$tmp/pins.out" >&2; fail "a tracked *.env should be named"; }

# (2) a setup.sh that writes its env file without mode 600
modrepo="$tmp/mode"
mkrepo mode
cat > "$modrepo/setup.sh" <<'SETUP'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
tmp="$(mktemp)"
echo "A=1" > "$tmp"
install -m 644 "$tmp" "$ENV_FILE"
SETUP
commit_all "$modrepo"
if bash "$script" "$modrepo" > "$tmp/mode.out" 2>&1; then fail "a setup.sh without mode 600 should fail"; fi
# shellcheck disable=SC2016 # the \$ is grep text: the script's message has a literal $ENV_FILE
grep -q '^FAIL setup.sh: writes \$ENV_FILE with no mode 600' "$tmp/mode.out" || { cat "$tmp/mode.out" >&2; fail "a setup.sh without mode 600 should be named with the grep"; }

# (3) a tracked file with a TOKEN value (the name is split so this file does not match itself)
tokrepo="$tmp/token"
mkrepo token
printf 'API_%s=abc123\n' TOKEN > "$tokrepo/app.conf"
commit_all "$tokrepo"
if bash "$script" "$tokrepo" > "$tmp/token.out" 2>&1; then fail "a tracked TOKEN value should fail"; fi
grep -q '^FAIL app.conf:1:' "$tmp/token.out" || { cat "$tmp/token.out" >&2; fail "a tracked TOKEN value should name the file"; }

echo "ok check-secrets.test"
