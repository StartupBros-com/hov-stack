#!/usr/bin/env bash
# scripts/backup-harness.sh pushes live memory to origin. From a public checkout (this repo,
# or a fork of it) that would publish every memory note, so the script refuses unless origin
# is confirmed private: a github.com remote by an unauthenticated lookup (404 passes, 200 and
# anything else refuse), any other remote only when HARNESS_BACKUP_REMOTE_PRIVATE=1 vouches
# for it.
#
# Hermetic: curl is a stub on PATH that records the URL it was asked for, and
# GIT_ALLOW_PROTOCOL=file keeps git off the network, so a github.com origin never connects.
# The vouched case runs a whole backup into a local bare repository.
set -uo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$SRC/scripts/backup-harness.sh
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# curl stub: append the last argument (the URL) to $TMP/curl.log, print STUB_CODE.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do last=$a; done
printf '%s\n' "$last" >> "$STUB_LOG"
printf '%s' "${STUB_CODE:-000}"
[ "${STUB_CODE:-000}" != 000 ]
EOF
chmod +x "$TMP/bin/curl"

# Trace setup and cleanup in the real script, with failure injection before local Git runs.
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
stage=
case ${1:-} in
  fetch)
    case ${4:-} in
      +refs/heads/main:*) stage=fetch-main ;;
      +refs/heads/backup/claude-memory:*) stage=fetch-backup-branch ;;
    esac
    ;;
  worktree) [[ ${2:-} == add ]] && stage=add-worktree ;;
  -C) [[ ${3:-} == worktree && ${4:-} == remove ]] && stage=remove-worktree ;;
esac
if [ -n "$stage" ]; then
  printf '%s\n' "$stage" >> "$STUB_GIT_LOG"
  if [ "$stage" = "${STUB_GIT_FAIL:-}" ]; then
    printf 'fixture Git stderr: %s\n' "$stage" >&2
    exit "$STUB_GIT_RC"
  fi
  # Cleanup failure must not change the setup command's status.
  if [ "$stage" = remove-worktree ] && [ -n "${STUB_GIT_FAIL:-}" ]; then exit 97; fi
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$TMP/bin/git"

# The backup source: a bare origin whose main carries a stub sync.sh that writes one note.
g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }
g init -q --bare "$TMP/origin.git"
g init -q "$TMP/seed"
cat > "$TMP/seed/sync.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = memory-push ] || exit 2
d=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$d/memory/-home-x"
echo "a private note" > "$d/memory/-home-x/note.md"
echo "memory-push: 1 file"
EOF
g -C "$TMP/seed" add sync.sh && g -C "$TMP/seed" commit -q -m seed
g -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:main
g clone -q "$TMP/origin.git" "$TMP/repo"

# run <origin push url>: run the real script against $TMP/repo with that origin.
# Prints combined output; returns the script's status.
run() {
  g -C "$TMP/repo" remote set-url origin "$1"
  : > "$TMP/curl.log"
  : > "$TMP/git.log"
  env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" \
    GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 \
    STUB_LOG="$TMP/curl.log" STUB_CODE="${STUB_CODE:-000}" \
    STUB_GIT_LOG="$TMP/git.log" STUB_GIT_FAIL="${STUB_GIT_FAIL:-}" STUB_GIT_RC="${STUB_GIT_RC:-1}" \
    HARNESS_BACKUP_REMOTE_PRIVATE="${VOUCH:-0}" \
    DOTFILES="$TMP/repo" BACKUP_TMP_ROOT="$TMP/cache" CLAUDE_HOME="$TMP/home/.claude" \
    bash "$SCRIPT" 2>&1
}
mkdir -p "$TMP/home"
API=https://api.github.com/repos

# 1. A public GitHub origin (200) is refused, and nothing is fetched or locked.
out=$(STUB_CODE=200 run git@github.com:acme/public-repo.git); rc=$?
[ "$rc" -eq 1 ] && ok || bad "public origin: rc=$rc, want 1"
case $out in *"REFUSED"*"acme/public-repo"*"public GitHub repository"*) ok ;; *) bad "public origin: no refusal naming it: $out" ;; esac
[ "$(cat "$TMP/curl.log")" = "$API/acme/public-repo" ] && ok || bad "public origin: looked up '$(cat "$TMP/curl.log")'"
[ ! -e "$TMP/cache/backup.lock" ] && ok || bad "public origin: the lock was taken before the refusal"

# 2. An https origin with a token: the owner/name is parsed out and the token never logged.
out=$(STUB_CODE=200 run "https://x-access-token:tok-SECRET-1@github.com/acme/public-repo.git/"); rc=$?
[ "$rc" -eq 1 ] && ok || bad "token origin: rc=$rc, want 1"
[ "$(cat "$TMP/curl.log")" = "$API/acme/public-repo" ] && ok || bad "token origin: looked up '$(cat "$TMP/curl.log")'"
case $out in *tok-SECRET-1*) bad "token origin: the token reached the log" ;; *) ok ;; esac

# 3. A lookup that fails or answers anything but 200/404 is refused (fail closed).
out=$(STUB_CODE=000 run git@github.com:acme/private-repo.git); rc=$?
[ "$rc" -eq 1 ] && ok || bad "failed lookup: rc=$rc, want 1"
case $out in *"REFUSED: could not confirm"*"HTTP 000"*) ok ;; *) bad "failed lookup: $out" ;; esac
out=$(STUB_CODE=403 run ssh://git@github.com/acme/private-repo); rc=$?
[ "$rc" -eq 1 ] && ok || bad "rate-limited lookup: rc=$rc, want 1"
case $out in *"HTTP 403"*) ok ;; *) bad "rate-limited lookup: $out" ;; esac

# 4. A private GitHub origin (404) passes the guard. The fetch after it then fails, because
#    git may not leave the machine here, which shows the script went on past the guard.
out=$(STUB_CODE=404 run git@github.com:acme/private-repo.git); rc=$?
case $out in *"not publicly readable"*) ok ;; *) bad "private origin: guard did not pass: $out" ;; esac
case $out in *REFUSED*) bad "private origin: refused: $out" ;; *) ok ;; esac
[ "$(cat "$TMP/curl.log")" = "$API/acme/private-repo" ] && ok || bad "private origin: looked up '$(cat "$TMP/curl.log")'"

# 5. A host that only looks like github.com in its path is not GitHub.
out=$(STUB_CODE=404 run https://other.example/x@github.com/acme/private-repo); rc=$?
[ "$rc" -eq 1 ] && ok || bad "lookalike origin: rc=$rc, want 1"
[ ! -s "$TMP/curl.log" ] && ok || bad "lookalike origin: GitHub was asked about it"

# 6. A non-GitHub origin is refused unless vouched for; vouched, a whole backup runs.
out=$(run "$TMP/origin.git"); rc=$?
[ "$rc" -eq 1 ] && ok || bad "local origin, not vouched: rc=$rc, want 1"
case $out in *"REFUSED: origin is not a github.com"*) ok ;; *) bad "local origin, not vouched: $out" ;; esac
[ ! -s "$TMP/curl.log" ] && ok || bad "local origin: GitHub was asked about it"
out=$(VOUCH=1 run "$TMP/origin.git"); rc=$?
[ "$rc" -eq 0 ] && ok || bad "local origin, vouched: rc=$rc: $out"
if grep -Fxq fetch-backup-branch "$TMP/git.log"; then
  bad "first backup fetched a branch that did not exist"
else
  ok
fi
note=$(git --git-dir="$TMP/origin.git" show backup/claude-memory:memory/-home-x/note.md 2>&1)
[ "$note" = "a private note" ] && ok || bad "local origin, vouched: backup branch lacks the note: $note"

# 7. Each setup failure logs a fixed parent-shell stage, preserves the primary status
#    despite cleanup failure, and does not replay or swallow the original stderr.
for pair in fetch-main:61 fetch-backup-branch:62 add-worktree:63; do
  stage=${pair%:*} want=${pair#*:}
  out=$(VOUCH=1 STUB_GIT_FAIL="$stage" STUB_GIT_RC="$want" run "$TMP/origin.git"); rc=$?
  [ "$rc" -eq "$want" ] && ok || bad "$stage: rc=$rc, want $want: $out"
  case $out in
    *"backup-harness: git setup $stage failed (exit $want)"*) ok ;;
    *) bad "$stage: expected setup diagnostic: $out" ;;
  esac
  [ "$(grep -Fxc "fixture Git stderr: $stage" <<< "$out")" -eq 1 ] && ok ||
    bad "$stage: original Git stderr lost or replayed: $out"
  grep -Fxq remove-worktree "$TMP/git.log" && ok || bad "$stage: cleanup trap did not run"
  case $out in
    *"memory-push:"*|*"pushed current harness"*) bad "$stage: ran copy or push after setup failure" ;;
    *) ok ;;
  esac
done

echo "backup-harness public guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
