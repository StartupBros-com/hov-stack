#!/usr/bin/env bash
# Hermetic end-to-end regression test for migration-apply.sh's pre-write gates.
# Every case uses an isolated HOME/repository and records Supabase/curl argv.
# The planted negatives must stop before any write-capable `supabase db push`.
set -euo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
APPLY="$HERE/scripts/migration-apply.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$APPLY" ] || fail "script not found at $APPLY"

# The repository and app/ref map are overlay data; this suite supplies its own fixture map.
TARGET_TABLE='acme-web:abcdefghijklmnopqrst
acme-shop:bcdefghijklmnopqrstu
acme-partners:cdefghijklmnopqrstuv
acme-help:defghijklmnopqrstuvw'
ORIGIN_FIXTURE='acme-org/app'
HOV_STACK_MIGRATION_TARGETS_FILE="$TMP/migration-targets.json"
export HOV_STACK_MIGRATION_TARGETS_FILE
printf '%s\n' "$TARGET_TABLE" | jq -R -s --arg repo "$ORIGIN_FIXTURE" \
  '{repository: $repo, apps: (split("\n") | map(select(length > 0) | split(":") | {(.[0]): .[1]}) | add)}' \
  >"$HOV_STACK_MIGRATION_TARGETS_FILE"
jq --slurpfile fixture "$HERE/tests/fixtures/migration-targets.json" \
  '.legacy_identities = $fixture[0].legacy_identities' "$HOV_STACK_MIGRATION_TARGETS_FILE" >"$TMP/targets.json"
mv "$TMP/targets.json" "$HOV_STACK_MIGRATION_TARGETS_FILE"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_CALLS"
if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  printf 'token reached git: %s\n' "$*" >>"$GIT_SECRET_LEAKS"
fi
if [ "${GIT_CONFIG_GLOBAL:-}" != /dev/null ] || [ "${GIT_CONFIG_SYSTEM:-}" != /dev/null ]; then
  printf 'config reached git: global=%s system=%s argv=%s\n' "${GIT_CONFIG_GLOBAL:-}" "${GIT_CONFIG_SYSTEM:-}" "$*" >>"$GIT_CONFIG_LEAKS"
fi
case " $* " in
  *" fetch "*) exit 0 ;;
  *" rev-parse --show-toplevel "*) printf '%s\n' "$GIT_REPO_ROOT"; exit 0 ;;
  *" rev-parse "*) printf '%s\n' "$GIT_MAIN_SHA"; exit 0 ;;
  *" remote get-url origin "*) printf '%s\n' "$GIT_ORIGIN_OUTPUT"; exit 0 ;;
  *" status "*) printf '%s' "${GIT_STATUS_OUTPUT:-}"; exit 0 ;;
  *" archive "*)
    output=''
    previous=''
    for argument in "$@"; do
      if [ "$previous" = '--output' ]; then output="$argument"; break; fi
      previous="$argument"
    done
    [ -n "$output" ] || exit 96
    tar -C "$COMMIT_FIXTURE" -cf "$output" apps
    exit 0
    ;;
esac
exit 0
STUB
cat >"$TMP/bin/flock" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
shift
exec "$@"
STUB
cat >"$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CURL_CALLS"
case " $* " in
  *'/config/database/pooler'*)
    [ "${POOLER_CURL_RC:-0}" -eq 0 ] || exit "$POOLER_CURL_RC"
    printf '%s\n' "$SUPABASE_POOLER_JSON"
    ;;
  *)
    [ "${CURL_RC:-0}" -eq 0 ] || exit "$CURL_RC"
    if grep -q '^db push$' "$SUPABASE_CALLS" && [ -n "${SUPABASE_LEDGER_JSON_AFTER:-}" ]; then
      printf '%s\n' "$SUPABASE_LEDGER_JSON_AFTER"
    else
      printf '%s\n' "$SUPABASE_LEDGER_JSON"
    fi
    ;;
esac
STUB
cat >"$TMP/bin/supabase" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >>"$SUPABASE_CWDS"
printf '%s\n' "${SUPABASE_ACCESS_TOKEN-<unset>}" >>"$SUPABASE_TOKENS"
if [ -f "$PWD/supabase/.temp/pooler-url" ]; then
  printf '%s\n' "$(<"$PWD/supabase/.temp/pooler-url")" >>"$POOLER_URLS"
  tail -c 1 "$PWD/supabase/.temp/pooler-url" | od -An -tu1 | tr -d ' ' >>"$POOLER_TERMINATORS"
fi
if [ "${1:-}" = '--workdir' ]; then shift 2; fi
case "$1 $2" in
  'migration list')
    if grep -q '^db push$' "$SUPABASE_CALLS" && [ -n "${SUPABASE_REMOTE_AFTER:-}" ]; then
      printf '%s\n' "$SUPABASE_REMOTE_AFTER"
    else
      printf '%s\n' "$SUPABASE_REMOTE"
    fi
    ;;
  'db push')
    printf '%s\n' "$*" >> "$SUPABASE_CALLS"
    case " $* " in
      *' --dry-run '*) printf '%s\n' "$SUPABASE_DRY_OUTPUT" ;;
      *)
        find "$PWD/supabase/migrations" -type f -name '*.sql' -exec sha256sum {} \; >>"$PUSHED_SQL_HASHES"
        exit "${SUPABASE_WRITE_RC:-97}"
        ;;
    esac
    ;;
  *)
    printf 'unexpected supabase argv: %s\n' "$*" >&2
    exit 98
    ;;
esac
STUB
chmod +x "$TMP/bin/git" "$TMP/bin/flock" "$TMP/bin/timeout" "$TMP/bin/curl" "$TMP/bin/supabase"

case_no=0
setup_case() {
  case_no=$((case_no + 1))
  APP_FIXTURE="${1:-acme-web}"
  LINKED_REF_FIXTURE="${2:-abcdefghijklmnopqrst}"
  CASE="$TMP/case-$case_no"
  HOME_FIXTURE="$CASE/home"
  REPO_FIXTURE="$CASE/repo"
  COMMIT_FIXTURE="$CASE/commit"
  DIR="$REPO_FIXTURE/apps/$APP_FIXTURE/supabase"
  SUPABASE_CALLS="$CASE/supabase-calls"
  SUPABASE_CWDS="$CASE/supabase-cwds"
  SUPABASE_TOKENS="$CASE/supabase-tokens"
  BWS_CALLS="$CASE/bws-calls"
  POOLER_URLS="$CASE/pooler-urls"
  POOLER_TERMINATORS="$CASE/pooler-terminators"
  PUSHED_SQL_HASHES="$CASE/pushed-sql-hashes"
  CURL_CALLS="$CASE/curl-calls"
  GIT_CALLS="$CASE/git-calls"
  GIT_SECRET_LEAKS="$CASE/git-secret-leaks"
  GIT_CONFIG_LEAKS="$CASE/git-config-leaks"
  GIT_MAIN_SHA='1111111111111111111111111111111111111111'
  GIT_ORIGIN_OUTPUT="git@github.com:$ORIGIN_FIXTURE.git"
  SUPABASE_POOLER_JSON=$(printf '[{"database_type":"PRIMARY","identifier":"%s","db_user":"postgres.%s","db_host":"aws-0-us-west-1.pooler.supabase.com","db_port":6543,"db_name":"postgres","pool_mode":"transaction"}]' "$LINKED_REF_FIXTURE" "$LINKED_REF_FIXTURE")
  SUPABASE_LEDGER_JSON='[]'
  SUPABASE_LEDGER_JSON_AFTER=''
  SUPABASE_REMOTE_AFTER=''
  SUPABASE_WRITE_RC=97
  CURL_RC=0
  POOLER_CURL_RC=0
  GIT_STATUS_OUTPUT=''
  mkdir -p "$HOME_FIXTURE/.claude/logs" "$DIR/.temp" "$DIR/migrations"
  ln -s "$HERE/scripts" "$CASE/linked-scripts"
  APPLY_LINK="$CASE/linked-scripts/migration-apply.sh"
  printf '%s\n' "$LINKED_REF_FIXTURE" >"$DIR/.temp/project-ref"
  : >"$SUPABASE_CALLS"
  : >"$SUPABASE_CWDS"
  : >"$SUPABASE_TOKENS"
  : >"$BWS_CALLS"
  rm -f "$TMP/bin/bws"
  : >"$POOLER_URLS"
  : >"$POOLER_TERMINATORS"
  : >"$PUSHED_SQL_HASHES"
  : >"$CURL_CALLS"
  : >"$GIT_CALLS"
  : >"$GIT_SECRET_LEAKS"
  : >"$GIT_CONFIG_LEAKS"
}

run_apply_with() {
  local dry_run="$1" dirty_path
  shift
  if [ ! -d "$COMMIT_FIXTURE/apps" ]; then
    mkdir -p "$COMMIT_FIXTURE"
    cp -a "$REPO_FIXTURE/apps" "$COMMIT_FIXTURE/apps"
    case "$GIT_STATUS_OUTPUT" in
      '?? '*) dirty_path=${GIT_STATUS_OUTPUT#'?? '}; rm -f -- "$COMMIT_FIXTURE/$dirty_path" ;;
    esac
  fi
  set +e
  OUT=$(HOME="$HOME_FIXTURE" REPO="$REPO_FIXTURE" DRY_RUN="$dry_run" \
    PATH="$TMP/bin:$PATH" SUPABASE_ACCESS_TOKEN="${APPLY_TOKEN_ENV-x}" BWS_ACCESS_TOKEN='' BWS_PROJECT_ID='' \
    SUPABASE_TOKENS="$SUPABASE_TOKENS" BWS_CALLS="$BWS_CALLS" GIT_STATUS_OUTPUT="$GIT_STATUS_OUTPUT" \
    GIT_CALLS="$GIT_CALLS" GIT_SECRET_LEAKS="$GIT_SECRET_LEAKS" GIT_CONFIG_LEAKS="$GIT_CONFIG_LEAKS" GIT_MAIN_SHA="$GIT_MAIN_SHA" \
    GIT_ORIGIN_OUTPUT="$GIT_ORIGIN_OUTPUT" GIT_REPO_ROOT="$REPO_FIXTURE" COMMIT_FIXTURE="$COMMIT_FIXTURE" \
    SUPABASE_CALLS="$SUPABASE_CALLS" SUPABASE_CWDS="$SUPABASE_CWDS" POOLER_URLS="$POOLER_URLS" POOLER_TERMINATORS="$POOLER_TERMINATORS" PUSHED_SQL_HASHES="$PUSHED_SQL_HASHES" SUPABASE_REMOTE="$SUPABASE_REMOTE" \
    SUPABASE_POOLER_JSON="$SUPABASE_POOLER_JSON" \
    CURL_CALLS="$CURL_CALLS" CURL_RC="$CURL_RC" POOLER_CURL_RC="$POOLER_CURL_RC" \
    SUPABASE_LEDGER_JSON="$SUPABASE_LEDGER_JSON" SUPABASE_LEDGER_JSON_AFTER="$SUPABASE_LEDGER_JSON_AFTER" \
    SUPABASE_REMOTE_AFTER="$SUPABASE_REMOTE_AFTER" SUPABASE_WRITE_RC="$SUPABASE_WRITE_RC" \
    SUPABASE_DRY_OUTPUT="$SUPABASE_DRY_OUTPUT" \
    bash "$APPLY_LINK" --app "$APP_FIXTURE" "$@" 2>&1)
  RC=$?
  set -e
}
run_apply() { run_apply_with 1; }

assert_eq() { [ "$2" = "$3" ] || fail "$1 (got '$2', want '$3'; output: $OUT)"; }
# HERE-STRINGS, NOT PIPES. `printf ... | grep -q` is unsafe in any script with
# `set -o pipefail` (line 5 here): grep -q exits the instant it matches and
# closes the pipe, the still-writing printf dies of SIGPIPE, and pipefail
# returns that 141 — so the pipeline reports FAILURE precisely because the match
# SUCCEEDED. Whether printf finishes first is a timing race against the ~64KB
# pipe buffer, so it passes locally and flips under CI load.
#
# Observed here 2026-08-29: "FAIL: P1a: full target commit is reported (missing
# 'commit=1111...')" printed alongside output that visibly CONTAINED
# commit=1111..., with `printf: write error: Broken pipe` on the line above. The
# same run passed nine minutes earlier on identical inputs.
#
# This exact pattern already cost a false prod-migration alert (an application-repository issue)
# from supabase-migration-drift.sh, where it invented 10 pending migrations that
# were all applied. That script was fixed and structurally guarded; the guard
# was scoped to that one file, so the pattern survived here.
assert_has() { grep -qF -- "$3" <<<"$2" || fail "$1 (missing '$3'; output: $OUT)"; }
assert_not_has() { ! grep -qF -- "$3" <<<"$2" || fail "$1 (unexpected '$3'; output: $OUT)"; }
assert_no_push() { [ ! -s "$SUPABASE_CALLS" ] || fail "$1 (saw: $(tr '\n' '|' <"$SUPABASE_CALLS"))"; }
assert_no_identity_read() { ! grep -q '/database/query' "$CURL_CALLS" || fail "$1 (saw: $(tr '\n' '|' <"$CURL_CALLS"))"; }
assert_no_api_read() { [ ! -s "$CURL_CALLS" ] || fail "$1 (saw: $(tr '\n' '|' <"$CURL_CALLS"))"; }
assert_git_isolated() {
  [ ! -s "$GIT_SECRET_LEAKS" ] || fail "$1 (token leak: $(tr '\n' '|' <"$GIT_SECRET_LEAKS"))"
  [ ! -s "$GIT_CONFIG_LEAKS" ] || fail "$1 (config leak: $(tr '\n' '|' <"$GIT_CONFIG_LEAKS"))"
}
assert_snapshot_only() {
  [ -s "$SUPABASE_CWDS" ] || fail "$1 (Supabase was never invoked)"
  if grep -qF "$REPO_FIXTURE/" "$SUPABASE_CWDS"; then
    fail "$1 (Supabase used mutable source: $(tr '\n' '|' <"$SUPABASE_CWDS"))"
  fi
  if grep -Ev '^/tmp/migration-apply-[a-z0-9-]+\.[A-Za-z0-9]+/apps/[a-z0-9-]+$' "$SUPABASE_CWDS" >/dev/null; then
    fail "$1 (unexpected execution path: $(tr '\n' '|' <"$SUPABASE_CWDS"))"
  fi
}
fixture_token() {
  local file hash
  {
    printf 'app=%s\ntarget-commit=%s\n' "$APP_FIXTURE" "$GIT_MAIN_SHA"
    for file in "$@"; do
      hash=$(sha256sum "$DIR/migrations/$file" | cut -d' ' -f1)
      printf 'file=%s\tsha256=%s\n' "$file" "$hash"
    done
  } | sha256sum | cut -d' ' -f1
}

# P1 regression: caller-provided credentials never reach Git while the source
# repository and origin are authenticated and archived.
setup_case
SUPABASE_REMOTE='-- | 20270701000000 | fixture'
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- unique' >"$DIR/migrations/20270801000000_unique.sql"
run_apply
assert_eq "P1a: coherent immutable dry-run exits clean" "$RC" 0
assert_git_isolated "P1a: Supabase token reached Git"
assert_snapshot_only "P1a: Supabase did not execute only from immutable snapshot"
assert_has "P1a: full target commit is reported" "$OUT" "commit=$GIT_MAIN_SHA"
assert_has "P1a: transaction metadata becomes validated session URL" "$(<"$POOLER_URLS")" "postgresql://postgres.${LINKED_REF_FIXTURE}@aws-0-us-west-1.pooler.supabase.com:5432/postgres"
[ "$(sort -u "$POOLER_TERMINATORS")" = 115 ] || fail "P1a: pooler URL must end at the database name with no newline"
assert_has "P1a: fetch uses fresh bare object store" "$(<"$GIT_CALLS")" "fetch --quiet --depth=1 git@github.com:$ORIGIN_FIXTURE.git main"
assert_not_has "P1a: caller repository must never execute fetch" "$(<"$GIT_CALLS")" "-C $REPO_FIXTURE fetch"
assert_has "P1a: archive binds immutable commit and owner path" "$(<"$GIT_CALLS")" "archive --format=tar --output"
assert_has "P1a: archive names exact target commit" "$(<"$GIT_CALLS")" "$GIT_MAIN_SHA apps/acme-web/supabase"

# P1 regression: an origin that is not the production source repository stops
# before any Supabase/API operation. Git remains token-scrubbed on this path too.
setup_case
GIT_ORIGIN_OUTPUT='ext::sh -c malicious'
SUPABASE_REMOTE='-- | 20270701000000 | fixture'
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
run_apply
assert_eq "P1b: untrusted origin exits precondition status" "$RC" 1
assert_has "P1b: untrusted origin diagnostic is explicit" "$OUT" "repository origin is not $ORIGIN_FIXTURE"
assert_git_isolated "P1b: Supabase token reached untrusted Git repo"
assert_no_push "P1b: untrusted origin reached db push"
assert_no_api_read "P1b: untrusted origin reached Supabase API"

# P1 regression: Management API pooler metadata cannot redirect the immutable
# snapshot to an arbitrary database host or smuggle a real embedded password.
setup_case
SUPABASE_POOLER_JSON=$(printf '[{"database_type":"PRIMARY","identifier":"%s","db_user":"postgres.%s","db_host":"evil.example","db_port":6543,"db_name":"postgres","pool_mode":"transaction"}]' "$LINKED_REF_FIXTURE" "$LINKED_REF_FIXTURE")
SUPABASE_REMOTE='-- | 20270701000000 | fixture'
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
run_apply
assert_eq "P1c: untrusted pooler metadata exits precondition status" "$RC" 1
assert_has "P1c: pooler metadata diagnostic is explicit" "$OUT" 'PRIMARY pooler response was empty, ambiguous, or not bound to expected project'
assert_git_isolated "P1c: Supabase token reached Git on invalid pooler path"
assert_no_push "P1c: untrusted pooler metadata reached db push"
[ "$(grep -c '/config/database/pooler' "$CURL_CALLS" || true)" = 1 ] || fail "P1c: expected one pooler metadata read"
[ "$(grep -c '/database/query' "$CURL_CALLS" || true)" = 0 ] || fail "P1c: invalid pooler metadata reached identity ledger"

# P1 regression: a committed SQL symlink cannot escape the fetched tree and
# supply mutable bytes to approval hashing, dry-run, or write.
setup_case
printf '%s\n' '-- mutable outside snapshot' >"$CASE/outside.sql"
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
ln -s "$CASE/outside.sql" "$DIR/migrations/20270801000000_escape.sql"
SUPABASE_REMOTE='-- | 20270701000000 | fixture'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_escape.sql...'
run_apply
assert_eq "P1d: committed migration symlink exits before credentials" "$RC" 1
assert_has "P1d: symlink diagnostic is explicit" "$OUT" 'immutable snapshot contains a migration symlink'
assert_git_isolated "P1d: Supabase token reached Git on symlink path"
assert_no_push "P1d: migration symlink reached db push"
assert_no_api_read "P1d: migration symlink reached Supabase API"

# Registry-consumer matrix: each supported app must resolve its own production
# ref through migration-apply.sh, not merely through direct registry assertions.
while IFS=: read -r app ref; do
  setup_case "$app" "$ref"
  SUPABASE_REMOTE='-- | 20270701000000 | fixture'
  SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
  SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
  printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
  printf '%s\n' '-- unique' >"$DIR/migrations/20270801000000_unique.sql"
  run_apply
  assert_eq "target $app: correct linked ref reaches dry-run" "$RC" 0
  [ "$(grep -c '^db push --dry-run$' "$SUPABASE_CALLS" || true)" = 1 ] \
    || fail "target $app: expected one dry-run"
  [ "$(grep -c '/database/query' "$CURL_CALLS" || true)" = 1 ] \
    || fail "target $app: expected one identity read"

  setup_case "$app" wrong-ref
  SUPABASE_REMOTE='-- | 20270701000000 | fixture'
  SUPABASE_DRY_OUTPUT=''
  printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
  run_apply
  assert_eq "target $app: wrong linked ref stops" "$RC" 1
  assert_has "target $app: wrong ref names expected target" "$OUT" "linked ref 'wrong-ref' != expected '$ref'"
  assert_no_push "target $app: wrong ref reached db push"
  assert_no_api_read "target $app: wrong ref reached Supabase API"
done <<<"$TARGET_TABLE"

# 0. PLANTED NEGATIVE: an untracked source-checkout migration must never enter
# inventory or dry-run. The fetched commit contains only the baseline migration.
setup_case
GIT_STATUS_OUTPUT='?? apps/acme-web/supabase/migrations/20270801000000_unmerged.sql'
SUPABASE_REMOTE='-- | 20270701000000 | fixture'
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- unmerged' >"$DIR/migrations/20270801000000_unmerged.sql"
run_apply
assert_eq "0: untracked source migration is ignored" "$RC" 0
assert_has "0: immutable snapshot reaches clean no-op" "$OUT" 'nothing pending for acme-web'
assert_no_push "0: untracked source migration reached db push"
assert_snapshot_only "0: untracked source migration escaped immutable snapshot"

# 1. PLANTED NEGATIVE: same local version on parallel branches, not yet remote.
# The guard must run before dry-run, which is the first path that could write.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- alpha' >"$DIR/migrations/20270801000000_alpha.sql"
printf '%s\n' '-- beta' >"$DIR/migrations/20270801000000_beta.sql"
run_apply
assert_eq "1: duplicate pending version exits anomaly status" "$RC" 3
assert_has "1: duplicate diagnostic is explicit" "$OUT" 'STOP: duplicate local migration version(s): 20270801000000'
assert_no_push "1: duplicate pending version reached db push"
assert_no_identity_read "1: duplicate pending version reached remote identity read"

# 2. PLANTED NEGATIVE: the same two local files exist after one version was
# recorded remotely. This proves the duplicate gate precedes the empty-pending
# success shortcut, which otherwise misclassifies the divergent checkout clean.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' '-- | 20270801000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- alpha' >"$DIR/migrations/20270801000000_alpha.sql"
printf '%s\n' '-- beta' >"$DIR/migrations/20270801000000_beta.sql"
run_apply
assert_eq "2: duplicate already remote exits anomaly status" "$RC" 3
assert_has "2: duplicate already remote is not reported clean" "$OUT" 'STOP: duplicate local migration version(s): 20270801000000'
assert_no_push "2: duplicate already remote reached db push"
assert_no_identity_read "2: duplicate already remote reached remote identity read"

# 3. Control: a coherent inventory reaches exactly the dry-run path in its
# default DRY_RUN=1 mode and never reaches a real db push. This makes the two
# zero-effect planted-negative assertions load-bearing rather than stub-vacuous.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- unique' >"$DIR/migrations/20270801000000_unique.sql"
run_apply
assert_eq "3: coherent default dry-run exits clean" "$RC" 0
assert_has "3: dry-run success names version/name proof" "$OUT" 'every recorded version/name identity agrees'
assert_not_has "3: dry-run success does not claim broad migration identity" "$OUT" 'migration identities agree'
[ "$(grep -c '^db push --dry-run$' "$SUPABASE_CALLS" || true)" = 1 ] \
  || fail "3: expected exactly one db push --dry-run (saw: $(tr '\n' '|' <"$SUPABASE_CALLS"))"
[ "$(grep -c '^db push$' "$SUPABASE_CALLS" || true)" = 0 ] \
  || fail "3: default DRY_RUN=1 reached a real db push"
[ "$(grep -c '/database/query' "$CURL_CALLS" || true)" = 1 ] \
  || fail "3: expected exactly one remote identity read"
if grep -qF 'Bearer x' "$CURL_CALLS"; then
  fail "3: access token leaked into curl argv"
fi

# 4. PLANTED NEGATIVE: version sets agree, but the version reached prod under a
# sibling branch's migration name. Presence-only checks call this clean; the
# identity gate must stop before the empty-pending shortcut and before db push.
setup_case
printf '%s\n' '-- | 20270801000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_LEDGER_JSON='[{"version":"20270801000000","name":"sibling_branch_name"}]'
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- local branch' >"$DIR/migrations/20270801000000_local_branch_name.sql"
run_apply
assert_eq "4: remote/local identity mismatch exits anomaly status" "$RC" 3
assert_has "4: identity mismatch is explicit" "$OUT" "migration identity mismatch for 20270801000000 (prod='sibling_branch_name', main='local_branch_name')"
assert_no_push "4: identity mismatch reached db push"

# 5. PLANTED NEGATIVE: the CLI and Management API are two independent reads.
# If they disagree, neither source is safe to approve and the controller stops.
setup_case
printf '%s\n' '-- | 20270801000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_LEDGER_JSON='[{"version":"20270802000000","name":"other"}]'
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- local' >"$DIR/migrations/20270801000000_unique.sql"
run_apply
assert_eq "5: incoherent remote inventories exit anomaly status" "$RC" 3
assert_has "5: inventory disagreement is explicit" "$OUT" 'CLI migration versions disagree with the remote identity ledger'
assert_no_push "5: incoherent remote inventories reached db push"

# 6. Legacy control: a pre-gate historical mismatch is accepted only when both
# the recorded remote name and current local suffix match the exact registry row.
setup_case
printf '%s\n' '-- | 20250501000003 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_LEDGER_JSON='[{"version":"20250501000003","name":"create_example_1"}]'
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- legacy' >"$DIR/migrations/20250501000003_create_example_1 copy.sql"
run_apply
assert_eq "6: exact legacy identity exits clean" "$RC" 0
assert_has "6: exact legacy identity reaches no-op" "$OUT" 'nothing pending for acme-web'
assert_has "6: no-op success names version/name proof" "$OUT" 'every recorded version/name identity matches main'
assert_not_has "6: no-op success does not claim broad migration identity" "$OUT" 'migration identities verified'
assert_no_push "6: exact legacy identity reached db push"

# 7. Remote identity read failure is not a no-op and cannot degrade to the CLI's
# version-only view. The controller fails before approval or push.
setup_case
printf '%s\n' '-- | 20270801000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
CURL_RC=22
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- local' >"$DIR/migrations/20270801000000_unique.sql"
run_apply
assert_eq "7: failed identity read exits precondition status" "$RC" 1
assert_has "7: failed identity read is explicit" "$OUT" 'could not read remote migration identities'
assert_no_push "7: failed identity read reached db push"

# 8. A response that is HTTP-successful but not the documented row array also
# fails closed. This catches auth/proxy error objects disguised behind status 200.
setup_case
printf '%s\n' '-- | 20270801000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_LEDGER_JSON='{"message":"unexpected"}'
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- local' >"$DIR/migrations/20270801000000_unique.sql"
run_apply
assert_eq "8: malformed identity response exits precondition status" "$RC" 1
assert_has "8: malformed identity response is explicit" "$OUT" 'remote migration identity response was empty or unparseable'
assert_no_push "8: malformed identity response reached db push"

# 9. A legacy exception binds both names. Keeping the old remote name while
# changing the local suffix must still stop; the registry is not a version-only
# bypass.
setup_case
printf '%s\n' '-- | 20250501000003 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_LEDGER_JSON='[{"version":"20250501000003","name":"create_example_1"}]'
SUPABASE_DRY_OUTPUT=''
printf '%s\n' '-- renamed' >"$DIR/migrations/20250501000003_new_local_name.sql"
run_apply
assert_eq "9: changed legacy local name exits anomaly status" "$RC" 3
assert_has "9: changed legacy local name reports mismatch" "$OUT" "prod='create_example_1', main='new_local_name'"
assert_no_push "9: changed legacy local name reached db push"

# 10. PLANTED NEGATIVE: changing tracked source SQL after approval while
# retaining the filename cannot change the bytes executed from fetched main.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_REMOTE_AFTER=$(printf '%s\n' '-- | 20270701000000 | fixture' '-- | 20270801000000 | fixture')
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_LEDGER_JSON_AFTER='[{"version":"20270701000000","name":"baseline"},{"version":"20270801000000","name":"unique"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
SUPABASE_WRITE_RC=0
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- approved bytes' >"$DIR/migrations/20270801000000_unique.sql"
approved_hash=$(sha256sum "$DIR/migrations/20270801000000_unique.sql" | cut -d' ' -f1)
run_apply
assert_eq "10: initial immutable approval exits clean" "$RC" 0
approved_token=$(printf '%s\n' "$OUT" | awk '/confirm token:/ { print $NF }' | tail -1)
[[ "$approved_token" =~ ^[0-9a-f]{64}$ ]] || fail "10: approval token is not a full SHA-256 digest: $approved_token"
printf '%s\n' '-- substituted bytes' >"$DIR/migrations/20270801000000_unique.sql"
substituted_hash=$(sha256sum "$DIR/migrations/20270801000000_unique.sql" | cut -d' ' -f1)
run_apply_with 0 --confirm "$approved_token"
assert_eq "10: mutable source substitution cannot alter approved write" "$RC" 0
[ "$(grep -c '^db push$' "$SUPABASE_CALLS" || true)" = 1 ] || fail "10: expected one write from approved snapshot"
assert_has "10: write contains approved SQL bytes" "$(<"$PUSHED_SQL_HASHES")" "$approved_hash"
assert_not_has "10: write excludes substituted source bytes" "$(<"$PUSHED_SQL_HASHES")" "$substituted_hash"
assert_git_isolated "10: Supabase token reached Git during changed-byte replay"
assert_snapshot_only "10: changed-byte replay used mutable source checkout"

# 11. PLANTED NEGATIVE: a new immutable commit/content set invalidates the prior
# content-bound token even when the source checkout exactly matches that new set.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- first commit bytes' >"$DIR/migrations/20270801000000_unique.sql"
run_apply
assert_eq "11: first commit approval exits clean" "$RC" 0
old_token=$(printf '%s\n' "$OUT" | awk '/confirm token:/ { print $NF }' | tail -1)
printf '%s\n' '-- next commit bytes' >"$DIR/migrations/20270801000000_unique.sql"
rm -r -- "$COMMIT_FIXTURE/apps"
GIT_MAIN_SHA='2222222222222222222222222222222222222222'
run_apply_with 0 --confirm "$old_token"
assert_eq "11: new commit and SQL bytes invalidate prior approval" "$RC" 4
assert_has "11: token diagnostic names immutable binding" "$OUT" 'app, commit, filename set, or SQL bytes changed since approval'
[ "$(grep -c '^db push$' "$SUPABASE_CALLS" || true)" = 0 ] || fail "11: changed commit reached a real db push"

# 12. Write control: a successful stubbed push must perform a second CLI history
# read and a second identity-ledger read before claiming success.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_REMOTE_AFTER=$(printf '%s\n' '-- | 20270701000000 | fixture' '-- | 20270801000000 | fixture')
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_LEDGER_JSON_AFTER='[{"version":"20270701000000","name":"baseline"},{"version":"20270801000000","name":"unique"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
SUPABASE_WRITE_RC=0
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- unique' >"$DIR/migrations/20270801000000_unique.sql"
token=$(fixture_token '20270801000000_unique.sql')
run_apply_with 0 --confirm "$token"
assert_eq "11: coherent stubbed write exits clean" "$RC" 0
assert_has "11: post-write version/name verification is reported" "$OUT" 'every approved version/name identity is recorded and matches main'
assert_not_has "11: post-write success does not claim broad identity" "$OUT" 'all pending versions recorded with matching identities'
[ "$(grep -c '^db push --dry-run$' "$SUPABASE_CALLS" || true)" = 1 ] || fail "11: expected one dry-run"
[ "$(grep -c '^db push$' "$SUPABASE_CALLS" || true)" = 1 ] || fail "11: expected one write"
[ "$(grep -c '/database/query' "$CURL_CALLS" || true)" = 2 ] || fail "11: expected pre- and post-write identity reads"

# 12. POST-WRITE PLANTED NEGATIVE: version appears after push under the wrong
# remote name. History presence alone must not produce a success claim.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_REMOTE_AFTER=$(printf '%s\n' '-- | 20270701000000 | fixture' '-- | 20270801000000 | fixture')
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_LEDGER_JSON_AFTER='[{"version":"20270701000000","name":"baseline"},{"version":"20270801000000","name":"wrong_name"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
SUPABASE_WRITE_RC=0
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- unique' >"$DIR/migrations/20270801000000_unique.sql"
token=$(fixture_token '20270801000000_unique.sql')
run_apply_with 0 --confirm "$token"
assert_eq "12: wrong post-write identity exits verification status" "$RC" 5
assert_has "12: wrong post-write identity is explicit" "$OUT" 'POST-VERIFY FAILED: remote migration identities do not match main after push'
[ "$(grep -c '^db push$' "$SUPABASE_CALLS" || true)" = 1 ] || fail "12: expected the simulated write before post-verify failure"

# 13. POST-WRITE PLANTED NEGATIVE: a concurrent actor adds another coherent
# migration after preflight. The approved transition is remote-before + pending,
# so the extra version must make post-verification fail even when both reads agree.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_REMOTE_AFTER=$(printf '%s\n' '-- | 20270701000000 | fixture' '-- | 20270801000000 | fixture' '-- | 20270901000000 | fixture')
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_LEDGER_JSON_AFTER='[{"version":"20270701000000","name":"baseline"},{"version":"20270801000000","name":"unique"},{"version":"20270901000000","name":"external"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
SUPABASE_WRITE_RC=0
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- unique' >"$DIR/migrations/20270801000000_unique.sql"
token=$(fixture_token '20270801000000_unique.sql')
run_apply_with 0 --confirm "$token"
assert_eq "13: unexpected post-write version exits verification status" "$RC" 5
assert_has "13: unexpected post-write version is explicit" "$OUT" 'remote history differs from preflight + approved set'
[ "$(grep -c '^db push$' "$SUPABASE_CALLS" || true)" = 1 ] || fail "13: expected the simulated write before post-verify failure"

# 14. POST-WRITE PLANTED NEGATIVE: the push ran but the post-push listing parses
# to no version at all (a CLI error banner instead of the table). That must stop
# with the parse failure named, not as a history delta listing every expected
# version, which reads as "nothing was applied" (#21).
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_REMOTE_AFTER='Cannot connect to the remote database: connection timed out'
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_LEDGER_JSON_AFTER='[{"version":"20270701000000","name":"baseline"},{"version":"20270801000000","name":"unique"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
SUPABASE_WRITE_RC=0
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- unique' >"$DIR/migrations/20270801000000_unique.sql"
token=$(fixture_token '20270801000000_unique.sql')
run_apply_with 0 --confirm "$token"
assert_eq "14: unparseable post-push history exits verification status" "$RC" 5
assert_has "14: unparseable post-push history is named" "$OUT" 'POST-VERIFY FAILED: could not parse post-push migration history'
assert_not_has "14: the parse failure is not reported as a history delta" "$OUT" 'remote history differs from preflight + approved set'
[ "$(grep -c '^db push$' "$SUPABASE_CALLS" || true)" = 1 ] || fail "14: expected the simulated write before post-verify failure"

# B1. bws sits between env and ~/.secrets. With no env token the script resolves
# the bws record through resolve_trusted_bin (a stub on PATH), the supabase
# client sees that token on every call, git never does, and ~/.secrets (which
# holds a different token so a fallthrough would show) is never consulted.
setup_case
printf '%s\n' '-- | 20270701000000 | fixture' >"$CASE/remote"
SUPABASE_REMOTE=$(<"$CASE/remote")
SUPABASE_LEDGER_JSON='[{"version":"20270701000000","name":"baseline"}]'
SUPABASE_DRY_OUTPUT='Applying migration 20270801000000_unique.sql...'
printf '%s\n' '-- baseline' >"$DIR/migrations/20270701000000_baseline.sql"
printf '%s\n' '-- unique' >"$DIR/migrations/20270801000000_unique.sql"
mkdir -p "$HOME_FIXTURE/.config/bws"
printf 'bws-access-fixture\n' >"$HOME_FIXTURE/.config/bws/token"
printf 'project-fixture\n' >"$HOME_FIXTURE/.config/bws/sb-project-id"
printf 'SUPABASE_ACCESS_TOKEN=sbp_secretsfixture0000000000000000000000000\n' >"$HOME_FIXTURE/.secrets"
cat >"$TMP/bin/bws" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s\n' "$*" "${BWS_ACCESS_TOKEN:-<unset>}" >>"$BWS_CALLS"
printf '[{"key":"OTHER","value":"x"},{"key":"SUPABASE_ACCESS_TOKEN","value":"sbp_bwsfixture00000000000000000000000000000"}]\n'
STUB
chmod +x "$TMP/bin/bws"
APPLY_TOKEN_ENV=
run_apply
unset APPLY_TOKEN_ENV
assert_eq "B1: bws-resolved default dry-run exits clean" "$RC" 0
assert_has "B1: bws-resolved dry-run reaches the identity proof" "$OUT" 'every recorded version/name identity agrees'
[ "$(cat "$BWS_CALLS")" = '--color no secret list project-fixture|bws-access-fixture' ] \
  || fail "B1: expected exactly one bws listing with the configured project and access token (saw: $(tr '\n' '|' <"$BWS_CALLS"))"
[ -s "$SUPABASE_TOKENS" ] || fail "B1: the supabase stub recorded no token"
[ "$(grep -vc '^sbp_bwsfixture00000000000000000000000000000$' "$SUPABASE_TOKENS" || true)" = 0 ] \
  || fail "B1: a supabase call ran without the bws token (saw: $(sort -u "$SUPABASE_TOKENS" | tr '\n' '|'))"
[ ! -s "$GIT_SECRET_LEAKS" ] || fail "B1: the bws-resolved token reached git: $(cat "$GIT_SECRET_LEAKS")"
assert_not_has "B1: the bws token is never printed" "$OUT" 'sbp_bwsfixture'
assert_not_has "B1: the ~/.secrets token is never printed" "$OUT" 'sbp_secretsfixture'

# B2. PLANTED NEGATIVE: bws is configured but fails twice and ~/.secrets is
# absent. The script stops before any supabase call with a message naming all
# three sources, after exactly the one retry.
setup_case
mkdir -p "$HOME_FIXTURE/.config/bws"
printf 'bws-access-fixture\n' >"$HOME_FIXTURE/.config/bws/token"
printf 'project-fixture\n' >"$HOME_FIXTURE/.config/bws/sb-project-id"
cat >"$TMP/bin/bws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BWS_CALLS"
echo 'bws: 429 Too Many Requests' >&2
exit 1
STUB
chmod +x "$TMP/bin/bws"
APPLY_TOKEN_ENV=
run_apply
unset APPLY_TOKEN_ENV
assert_eq "B2: bws failing twice with no ~/.secrets exits 1" "$RC" 1
assert_has "B2: the failure names every source" "$OUT" 'SUPABASE_ACCESS_TOKEN unavailable (checked env, the bws record SUPABASE_ACCESS_TOKEN and ~/.secrets)'
[ "$(wc -l <"$BWS_CALLS")" = 2 ] || fail "B2: expected exactly two bws attempts (saw $(wc -l <"$BWS_CALLS"))"
[ ! -s "$SUPABASE_CWDS" ] || fail "B2: supabase was called without a token"

# B3. PLANTED NEGATIVE: the bws record exists but is not an sbp_ token. A valid
# ~/.secrets line must not paper over the malformed canonical record.
setup_case
mkdir -p "$HOME_FIXTURE/.config/bws"
printf 'bws-access-fixture\n' >"$HOME_FIXTURE/.config/bws/token"
printf 'project-fixture\n' >"$HOME_FIXTURE/.config/bws/sb-project-id"
printf 'SUPABASE_ACCESS_TOKEN=sbp_secretsfixture0000000000000000000000000\n' >"$HOME_FIXTURE/.secrets"
cat >"$TMP/bin/bws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BWS_CALLS"
printf '[{"key":"SUPABASE_ACCESS_TOKEN","value":"sbp_short"}]\n'
STUB
chmod +x "$TMP/bin/bws"
APPLY_TOKEN_ENV=
run_apply
unset APPLY_TOKEN_ENV
assert_eq "B3: a malformed bws record exits 1" "$RC" 1
assert_has "B3: the refusal names the record" "$OUT" 'the bws record SUPABASE_ACCESS_TOKEN is not a personal access token'
[ ! -s "$SUPABASE_CWDS" ] || fail "B3: supabase was called after a malformed bws record"
assert_not_has "B3: ~/.secrets did not stand in for the malformed record" "$OUT" 'every recorded version/name identity agrees'

echo "ok — migration-apply gates: isolated bare Git, immutable snapshots, content-bound approval, duplicate/identity/incoherence negatives, and exact post-write verification are load-bearing"
