#!/usr/bin/env bash
# The secrets check (HL-NFR-02, ST268). Run in a git repo: the current one, or the folder given. Fails, naming
# the file, when (1) a tracked file is named .env or *.env (.env.example is allowed); (2) a setup.sh writes an
# env file without mode 600 on it, grep for: install -m 600 ... "$VAR", or chmod 600 then mv to it within two
# lines, or umask 077 (the sourced siblings in the same folder count as the same script); (3) a tracked file
# has a TOKEN, PASSWORD, SECRET or TOPIC assignment whose value is not empty, a $variable, or a placeholder.
set -euo pipefail
cd "${1:-.}"
fails=0
fail() {
	echo "FAIL $*"
	fails=$((fails + 1))
}

# (1) tracked env files
while IFS= read -r f; do
	case "${f##*/}" in .env | *.env) fail "$f: a tracked env file; keep it out of git (only .env.example is tracked)" ;; esac
done < <(git ls-files)

# (2) every env file a setup.sh writes is mode 600
while IFS= read -r s; do
	dir="$(dirname "$s")"
	text="$(cat "$s")"
	# the literal $SCRIPT_DIR in these patterns is text to match, not an expansion
	# shellcheck disable=SC2016
	while IFS= read -r src; do
		[ -f "$dir/$src" ] && text+=$'\n'"$(cat "$dir/$src")"
	done < <(grep -oE '"\$SCRIPT_DIR/[^"]+\.sh"' "$s" | tr -d '"' | sed 's|^\$SCRIPT_DIR/||' || true)
	# shellcheck disable=SC2016
	while IFS= read -r v; do
		dest="\"\\\$$v\""
		grep -qE "(install|mv|cp|>) [^|;]*$dest" <<<"$text" || continue
		grep -qE "install -m 600 [^|;]*$dest" <<<"$text" && continue
		grep -qE 'umask 077' <<<"$text" && continue
		grep -A2 'chmod 600' <<<"$text" | grep -qE "mv [^|;]*$dest" && continue
		fail "$s: writes \$$v with no mode 600 on it (grep for: install -m 600 ... $dest, or chmod 600 then mv to it)"
	done < <(grep -oE '^[A-Za-z_]+="[^"]*\.env"' <<<"$text" | cut -d= -f1 || true)
done < <(git ls-files | grep -E '(^|/)setup\.sh$' || true)

# (3) secret-like values in tracked files
while IFS= read -r hit; do
	rhs="$(sed -E 's/.*(TOKEN|PASSWORD|SECRET|TOPIC)[A-Za-z0-9_]*=//' <<<"$hit")"
	read -r tok _ <<<"$rhs" || true
	tok="${tok#[\"\']}"
	tok="${tok%%[\\\"\']*}"
	case "$tok" in '' | '$'* | '%'* | '<'* | '`'*) continue ;; esac
	case "${tok,,}" in placeholder | changeme | change-me | replace-me | example | your-* | xxx*) continue ;; esac
	fail "$hit: a secret-like value in a tracked file (HL-NFR-02)"
done < <(git grep -n -I -E '(^|[^A-Za-z0-9_])[A-Za-z0-9_]*(TOKEN|PASSWORD|SECRET|TOPIC)[A-Za-z0-9_]*=[^=]' || true)

if [ "$fails" -gt 0 ]; then
	echo "check-secrets: $fails FAIL"
	exit 1
fi
echo "ok check-secrets"
