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
TMP=$(mktemp -d)
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
  env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" \
    GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 \
    STUB_LOG="$TMP/curl.log" STUB_CODE="${STUB_CODE:-000}" \
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
note=$(git --git-dir="$TMP/origin.git" show backup/claude-memory:memory/-home-x/note.md 2>&1)
[ "$note" = "a private note" ] && ok || bad "local origin, vouched: backup branch lacks the note: $note"

echo "backup-harness public guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
