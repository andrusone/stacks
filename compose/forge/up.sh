#!/usr/bin/env bash
# Bring up the local Forgejo (ST66, FG-FR-02 MVP 1). On the first run it creates
# the admin user forge-admin with a random password written to data/admin.password
# (git-ignored; never printed). A rerun on existing data changes nothing.
set -euo pipefail

cd "$(dirname "$0")"

compose=(docker compose -f docker-compose.yml)
pass_file=data/admin.password
url=http://127.0.0.1:3000

mkdir -p data
export FORGE_UID="$(id -u)" FORGE_GID="$(id -g)"
"${compose[@]}" up -d

for _ in $(seq 60); do
  if curl -fsS -o /dev/null "$url/api/healthz" 2>/dev/null; then
    break
  fi
  sleep 1
done
if ! curl -fsS -o /dev/null "$url/api/healthz"; then
  echo "forge: did not answer within 60 s" >&2
  exit 1
fi

if [ -f "$pass_file" ]; then
  echo "forge: data present, nothing to create"
  exit 0
fi

password="$(openssl rand -hex 24)"
"${compose[@]}" exec -T --user git forge forgejo admin user create \
  --admin --username forge-admin --email forge-admin@forge.localhost \
  --password "$password" --must-change-password=false
(umask 077 && printf '%s\n' "$password" > "$pass_file")
echo "forge: admin user forge-admin created; password is in compose/forge/$pass_file"
