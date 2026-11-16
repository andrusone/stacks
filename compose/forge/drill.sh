#!/usr/bin/env bash
# One command for both forge drills and the runner check (ST71, FG-FR-02 MVP 1, OC6's
# Check path): `mise run forge-drill`, from a clone of stacks, on a machine with Docker.
#
# Steps. Each prints one line, PASS or FAIL, with its elapsed seconds on PASS. The first
# FAIL stops the run after cleanup, with the last lines of that step's log.
#   up         forge up; repo smoke; commit one on main, commit two on feature; PR feature -> main
#   reconnect  backup taken, then the backup folder moved aside (unreachable); forge down and
#              up on the same data: repo, both branches and the PR present; a push works
#   restore    backup; forge down; data folder emptied; restore; password reset (the archive
#              holds no admin.password); the same checks; a push works
#   runner     runner up; repo drill-runner; branch pass (check `true`) and branch fail (check
#              `false`): green and red by commit status within 5 minutes
#   cleanup    runner and forge down; data folders emptied and removed
#
# Everything lives in one temp folder the drill makes (under TMPDIR, else /tmp), never in the
# clone. The admin password is read from the forge data folder and never printed. The drill
# refuses to start if a container named forge or runner already exists.
#
# Test-only: FORGE_DRILL_SKIP_BACKUP=1 skips the backup before the restore step. Restore then
# has no archive to read and must FAIL, with exit 1 (the sabotage proof).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
runner_dir="$here/../runner"
image="$(sed -n 's/^ *image: *//p' "$here/docker-compose.yml" | head -n 1)"
owner=forge-admin
url=http://127.0.0.1:3000
api="$url/api/v1"

names="$(docker ps -a --format '{{.Names}}')"
for name in forge runner; do
  if grep -qx -- "$name" <<< "$names"; then
    echo "FAIL start: a container named $name already exists; remove it first (mise run forge-down or runner-down)"
    exit 1
  fi
done

work="$(mktemp -d "${TMPDIR:-/tmp}/forge-drill.XXXXXX")"
data="$work/forge-data"
backup="$work/backup"
runner_data="$work/runner-data"
clone="$work/forge-clone"
runner_clone="$work/runner-clone"
logs="$work/logs"
reason="$work/reason"
mkdir -p "$logs"
export FORGE_DATA="$data" FORGE_BACKUP="$backup" RUNNER_DATA="$runner_data"

# Remove everything in a folder through the forge image: its files may be root-owned (ssh/).
empty_dir() {
  [ -d "$1" ] || return 0
  docker run --rm --user 0 -v "$1:/d" --entrypoint sh "$image" \
    -c 'rm -rf /d/* /d/.[!.]* /d/..?*' >/dev/null 2>&1
}

cleanup() {
  set +e
  bash "$runner_dir/down.sh" >/dev/null 2>&1
  bash "$here/down.sh" >/dev/null 2>&1
  empty_dir "$data"
  empty_dir "$runner_data"
  rm -rf -- "$work"
}
trap cleanup EXIT

# A step's function calls fail with a reason; errexit is off inside a step (it runs in an
# if), so every command that can fail is checked explicitly.
fail() {
  printf '%s\n' "$*" > "$reason"
  exit 1
}

retry() { # tries command...: retry once a second, up to tries times
  local tries=$1 i
  shift
  for ((i = 0; i < tries; i++)); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

container_gone() {
  local now
  now="$(docker ps -a --format '{{.Names}}')"
  ! grep -qx -- "$1" <<< "$now"
}

auth_header() { # the admin's Basic auth, in a 600 file: the password is never printed
  [ -f "$data/admin.password" ] || return 1
  (umask 077 && printf 'Authorization: Basic %s\n' \
    "$(printf '%s:%s' "$owner" "$(cat "$data/admin.password")" | base64 -w0)" > "$work/auth.header")
}

git_auth() {
  git -c "http.extraHeader=$(cat "$work/auth.header")" "$@"
}

push_branch() { # repo branch dir
  git_auth -C "$3" push -q "$url/$owner/$1.git" "$2:refs/heads/$2"
}

remote_sha() { # repo branch: the sha the forge has; empty if missing
  git_auth ls-remote "$url/$owner/$1.git" "refs/heads/$2" | awk '{print $1}'
}

commit_in() { # dir message: commit what is staged
  git -C "$1" -c user.name=drill -c user.email=drill@localhost commit -q -m "$2"
}

commit_msg() {
  commit_in "$clone" "$1"
}

# The checks after a reconnect or a restore: repo present, both branches at the commits pushed,
# pull request 1 open.
verify_smoke() {
  auth_header || fail "the admin password is not in the data folder"
  curl -fsS -o /dev/null -H "@$work/auth.header" "$api/repos/$owner/smoke" \
    || fail "repo smoke is not present"
  local branch want got
  for branch in main feature; do
    want="$(git -C "$clone" rev-parse "$branch")"
    got="$(remote_sha smoke "$branch")"
    [ "$got" = "$want" ] || fail "$branch is '${got:-missing}' on the forge, expected $want"
  done
  local pr
  pr="$(curl -fsS -H "@$work/auth.header" "$api/repos/$owner/smoke/pulls/1")" \
    || fail "pull request 1 is not present"
  grep -q '"state":"open"' <<< "$pr" || fail "pull request 1 is not open"
}

# A push after a drill: a new commit on feature, and the forge has exactly the new head.
push_after_drill() {
  printf 'after drill %s\n' "$1" >> "$clone/README.md"
  git -C "$clone" add README.md || fail "staging after the $1 drill failed"
  commit_msg "smoke: after the $1 drill" || fail "commit after the $1 drill failed"
  push_branch smoke feature "$clone" || fail "push to feature after the $1 drill failed"
  [ "$(remote_sha smoke feature)" = "$(git -C "$clone" rev-parse feature)" ] \
    || fail "after the $1 drill, feature on the forge is not the pushed head"
}

step_up() {
  bash "$here/up.sh" || fail "forge up failed"
  auth_header || fail "the admin password is not in the data folder"
  curl -fsS -o /dev/null -H "@$work/auth.header" -H 'Content-Type: application/json' \
    -X POST "$api/user/repos" -d '{"name":"smoke","private":true,"auto_init":false}' \
    || fail "creating repo smoke failed"
  git init -q -b main "$clone" || fail "git init failed"
  printf 'one\n' > "$clone/README.md"
  git -C "$clone" add README.md || fail "staging commit one failed"
  commit_msg "smoke: commit one" || fail "commit one failed"
  push_branch smoke main "$clone" || fail "push of main failed"
  git -C "$clone" checkout -q -b feature || fail "creating branch feature failed"
  printf 'two\n' >> "$clone/README.md"
  git -C "$clone" add README.md || fail "staging commit two failed"
  commit_msg "smoke: commit two" || fail "commit two failed"
  push_branch smoke feature "$clone" || fail "push of feature failed"
  # The forge syncs a pushed branch into its database a moment later; a pull request made
  # before that is refused with 404 (ST69).
  retry 30 curl -fsS -o /dev/null -H "@$work/auth.header" "$api/repos/$owner/smoke/branches/feature" \
    || fail "the forge did not list branch feature within 30 s"
  curl -fsS -o /dev/null -H "@$work/auth.header" -H 'Content-Type: application/json' \
    -X POST "$api/repos/$owner/smoke/pulls" \
    -d '{"head":"feature","base":"main","title":"smoke: second commit"}' \
    || fail "opening pull request feature -> main failed"
}

step_reconnect() {
  bash "$here/backup.sh" || fail "backup before the reconnect failed"
  mv -- "$backup" "$work/backup-unreachable" || fail "moving the backup folder aside failed"
  bash "$here/down.sh" || fail "forge down failed"
  container_gone forge || fail "container forge still exists after down"
  bash "$here/up.sh" || fail "forge up on the same data failed"
  verify_smoke
  push_after_drill reconnect
}

step_restore() {
  if [ "${FORGE_DRILL_SKIP_BACKUP:-0}" = 1 ]; then
    echo "restore: backup skipped (FORGE_DRILL_SKIP_BACKUP=1, test only)"
  else
    bash "$here/backup.sh" || fail "backup before the restore failed"
  fi
  bash "$here/down.sh" || fail "forge down failed"
  container_gone forge || fail "container forge still exists after down"
  empty_dir "$data" || fail "emptying the data folder failed"
  [ -z "$(ls -A "$data")" ] || fail "the data folder is not empty after emptying"
  bash "$here/restore.sh" || fail "restore.sh failed; the message is in the log below"
  # The archive holds no admin.password, so the drill sets a new one through the CLI. The
  # password must not be flagged for change at next login: that makes the API answer 403 to
  # basic auth (found in the ST71 proof; up.sh passes the same flag).
  local new
  new="$(openssl rand -hex 24)"
  docker exec --user git forge forgejo admin user change-password \
    --username "$owner" --password "$new" --must-change-password=false >/dev/null \
    || fail "admin password reset after the restore failed"
  (umask 077 && printf '%s\n' "$new" > "$data/admin.password")
  verify_smoke
  push_after_drill restore
}

step_runner() {
  bash "$runner_dir/up.sh" || fail "runner up failed"
  auth_header || fail "the admin password is not in the data folder"
  curl -fsS -o /dev/null -H "@$work/auth.header" -H 'Content-Type: application/json' \
    -X POST "$api/user/repos" -d '{"name":"drill-runner","private":false,"auto_init":false}' \
    || fail "creating repo drill-runner failed"
  git init -q -b pass "$runner_clone" || fail "git init for the runner check failed"
  mkdir -p "$runner_clone/.forgejo/workflows"
  cat > "$runner_clone/.forgejo/workflows/check.yml" <<'YAML'
on: push
jobs:
  check:
    runs-on: mise
    steps:
      - name: fetch the pushed commit from the forge
        run: |
          git init -q .
          git fetch -q --depth 1 http://forge:3000/forge-admin/drill-runner.git "$GITHUB_SHA"
          git checkout -q FETCH_HEAD
      - name: mise run check
        run: |
          mise trust -q
          mise run check
YAML
  printf '[tasks.check]\nrun = "true"\n' > "$runner_clone/mise.toml"
  git -C "$runner_clone" add -A || fail "staging for branch pass failed"
  commit_in "$runner_clone" "drill: check passes" || fail "commit for branch pass failed"
  push_branch drill-runner pass "$runner_clone" || fail "push of branch pass failed"
  git -C "$runner_clone" checkout -q -b fail || fail "creating branch fail failed"
  printf '[tasks.check]\nrun = "false"\n' > "$runner_clone/mise.toml"
  git -C "$runner_clone" add -A || fail "staging for branch fail failed"
  commit_in "$runner_clone" "drill: check fails" || fail "commit for branch fail failed"
  push_branch drill-runner fail "$runner_clone" || fail "push of branch fail failed"

  local deadline=$((SECONDS + 300)) p f
  while true; do
    p="$(commit_state drill-runner pass)"
    f="$(commit_state drill-runner fail)"
    if [ -n "$p" ] && [ -n "$f" ] && [ "$p" != pending ] && [ "$f" != pending ]; then
      break
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 5
  done
  [ "$p" = success ] || fail "branch pass has status '${p:-none}', expected success within 5 minutes"
  [ "$f" = failure ] || fail "branch fail has status '${f:-none}', expected failure within 5 minutes"
}

commit_state() { # repo branch: the combined state; empty until a status exists
  local body
  body="$(curl -fsS -H "@$work/auth.header" "$api/repos/$owner/$1/commits/$2/status" 2>/dev/null)" \
    || return 0
  grep -o '"state":"[a-z]*"' <<< "$body" | head -n 1 | cut -d'"' -f4 || true
}

step_cleanup() {
  bash "$runner_dir/down.sh" || fail "runner down failed"
  bash "$here/down.sh" || fail "forge down failed"
  container_gone runner || fail "container runner still exists after down"
  container_gone forge || fail "container forge still exists after down"
  empty_dir "$data" || fail "emptying the forge data folder failed"
  empty_dir "$runner_data" || fail "emptying the runner data folder failed"
}

# step NAME FUNCTION: run FUNCTION with its output in a log, print PASS or FAIL.
step() {
  local name=$1 fn=$2 start=$SECONDS log="$logs/$1.log"
  rm -f -- "$reason"
  if ( "$fn" ) > "$log" 2>&1; then
    echo "PASS $name ($((SECONDS - start)) s)"
  else
    echo "FAIL $name: $(cat "$reason" 2>/dev/null || echo 'a command failed; see the log below')"
    tail -n 20 "$log" | sed 's/^/    /'
    exit 1
  fi
}

step up step_up
step reconnect step_reconnect
step restore step_restore
step runner step_runner
step cleanup step_cleanup
echo "drill: all steps PASS"
