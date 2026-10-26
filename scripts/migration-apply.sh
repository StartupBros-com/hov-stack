#!/usr/bin/env bash
# migration-apply.sh: the prod migration runbook as a script, human gate intact.
#
# WHY: applying Supabase migrations to prod is deliberately manual (merge does
# NOT apply), but the mechanics — link-verify, independent pending-set
# computation, dry-run, anomaly detection, post-verify — were tribal knowledge
# in memory notes. 2026-08-03 proved the failure modes are real: version-number
# collisions across parallel branches, prod history ahead of main from a
# pre-merge apply, and out-of-order versions that normal `db push` refuses.
# Agents may run everything up to the confirm token; only the operator (or an
# agent explicitly handed the token) supplies --confirm for the write.
#
# usage: migration-apply.sh --app <name from the target map>
#                           [--allow-out-of-order] [--confirm TOKEN]
#
# Env: DRY_RUN=1 (default; the write requires DRY_RUN=0 AND a matching --confirm)
#      REPO=~/SITES/<app> (must resolve to the canonical origin named in the target map)
#      HOV_STACK_MIGRATION_TARGETS_FILE=path to the repository + app/ref map (default:
#        migration-targets.json in the overlay directory, $HOV_STACK_OVERLAY or
#        $XDG_CONFIG_HOME/hov-stack; see config/migration-targets.example.json)
#      MIGRATION_CONFIG_ONLY=1 (print effective repo + targets; no credentials)
#
# Exit codes:
#   0  dry-run clean (token printed), or apply + history post-verify clean
#   1  precondition failure (creds, source identity, link metadata, snapshot, lock)
#   2  usage error
#   3  anomaly detected — STOPPED, nothing written (remote-ahead drift,
#      out-of-order without --allow-out-of-order, version collision,
#      dry-run set != independently computed set)
#   4  confirm token missing/mismatched — approval not given, nothing written
#   5  push ran but post-verify failed — needs manual eyes NOW
set -uo pipefail

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=migration-targets.sh
. "$SCRIPT_DIR/migration-targets.sh"

REPO="${REPO:-$(migration_default_repo)}" || exit 1
ORIGIN_REPO=$(migration_origin_repo) || exit 1
DRY_RUN="${DRY_RUN:-1}"
if [ "${MIGRATION_CONFIG_ONLY:-0}" = 1 ]; then
  printf 'repo=%s\n' "$REPO"
  migration_target_entries
  exit 0
fi
APP="" ALLOW_OOO=0 CONFIRM=""
usage() { echo 'usage: migration-apply.sh --app <name from the target map> [--allow-out-of-order] [--confirm TOKEN]  (env: DRY_RUN=0 to write)' >&2; exit 2; }
log() { echo "migration-apply: $*"; }

SNAPSHOT_ROOT=""
cleanup() {
  if [ -n "$SNAPSHOT_ROOT" ] && [[ "$SNAPSHOT_ROOT" == "${TMPDIR:-/tmp}/migration-apply-$APP."* ]]; then
    chmod -R u+w "$SNAPSHOT_ROOT" 2>/dev/null || true
    rm -rf -- "$SNAPSHOT_ROOT"
  fi
}
trap cleanup EXIT

# A caller may provide the Supabase token in the environment. Every Git process
# still receives an explicitly scrubbed environment while authenticating and
# materializing the source commit.
safe_git() {
  (
    unset SUPABASE_ACCESS_TOKEN
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$GIT_BIN" "$@"
  )
}

resolve_trusted_bin() {
  local name="$1" candidate
  candidate=$(command -v "$name") || return 1
  candidate=$(readlink -f "$candidate") || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
    "$repo_root"/*) log "$name resolves inside the repository: $candidate" >&2; return 1 ;;
  esac
  printf '%s\n' "$candidate"
}

approval_manifest() {
  local file hash
  printf 'app=%s\ntarget-commit=%s\n' "$APP" "$main"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    hash=$("$SHA256_BIN" "$DIR/supabase/migrations/$file" | cut -d' ' -f1) || return 1
    printf 'file=%s\tsha256=%s\n' "$file" "$hash"
  done <<<"$expected_set"
}

read_remote_pooler_url() {
  local result pooler
  result=$("$CURL_BIN" -fsS --max-time 120 \
    "https://api.supabase.com/v1/projects/$EXPECT_REF/config/database/pooler" \
    --header @<(printf 'Authorization: Bearer %s\n' "$SUPABASE_ACCESS_TOKEN")) \
    || { log "could not read PRIMARY pooler metadata from Supabase Management API" >&2; return 1; }
  # Build from typed fields rather than trusting the API's presentation URL.
  # shellcheck disable=SC2016 # $ref/$user are jq variables, not shell expansions.
  pooler=$("$JQ_BIN" -er --arg ref "$EXPECT_REF" --arg user "postgres.$EXPECT_REF" '
    [ .[] | select(
      .database_type == "PRIMARY" and
      .identifier == $ref and
      .db_user == $user and
      (.db_host | type == "string" and test("^[a-z0-9.-]+\\.pooler\\.supabase\\.com$")) and
      .db_name == "postgres" and
      (
        (.pool_mode == "transaction" and .db_port == 6543) or
        (.pool_mode == "session" and .db_port == 5432)
      )
    ) ] |
    if length == 1 then .[0] else error("expected one validated PRIMARY pooler") end |
    "postgresql://\(.db_user)@\(.db_host):5432/\(.db_name)"
  ' <<<"$result" 2>/dev/null) \
    || { log "PRIMARY pooler response was empty, ambiguous, or not bound to expected project $EXPECT_REF" >&2; return 1; }
  printf '%s\n' "$pooler"
}

read_remote_identities() {
  local query payload result
  query='select version, name from supabase_migrations.schema_migrations order by version'
  # shellcheck disable=SC2016 # $query is a jq variable, not a shell expansion.
  payload=$("$JQ_BIN" -nc --arg query "$query" '{query:$query}')
  result=$("$CURL_BIN" -fsS --max-time 120 -X POST \
    "https://api.supabase.com/v1/projects/$EXPECT_REF/database/query" \
    --header @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$SUPABASE_ACCESS_TOKEN") \
    --data "$payload") \
    || { log "could not read remote migration identities from Supabase Management API" >&2; return 1; }

  if ! "$JQ_BIN" -e 'type == "array" and all(.[]; (.version | type == "string") and ((.name == null) or (.name | type == "string")))' \
    >/dev/null 2>&1 <<<"$result"; then
    log "remote migration identity response was empty or unparseable" >&2
    return 1
  fi
  printf '%s\n' "$result"
}

verify_remote_identities() {
  local cli_versions="$1" ledger_json="$2" ledger_versions ledger_delta
  local base v local_name recorded_name legacy_identity legacy_remote legacy_local
  local -A remote_has ledger_name

  ledger_versions=$("$JQ_BIN" -r '.[].version' <<<"$ledger_json" | sort -u)
  ledger_delta=$(comm -3 <(printf '%s\n' "$cli_versions") <(printf '%s\n' "$ledger_versions"))
  if [ -n "$ledger_delta" ]; then
    log "STOP: CLI migration versions disagree with the remote identity ledger:" >&2
    printf '  %s\n' $ledger_delta >&2
    return 3
  fi

  while IFS= read -r v; do [ -n "$v" ] && remote_has["$v"]=1; done <<<"$cli_versions"
  while IFS=$'\t' read -r v recorded_name; do
    [ -n "$v" ] && ledger_name["$v"]="$recorded_name"
  done < <("$JQ_BIN" -r '.[] | [.version, (if .name == null then "<unnamed>" else .name end)] | @tsv' <<<"$ledger_json")

  while IFS= read -r base; do
    [ -n "$base" ] || continue
    v=${base%%_*}
    [ -n "${remote_has[$v]:-}" ] || continue
    local_name=${base#${v}_}
    local_name=${local_name%.sql}
    recorded_name=${ledger_name[$v]:-<missing>}
    [ "$recorded_name" = "$local_name" ] && continue

    legacy_identity=$(migration_legacy_identity "$APP" "$v" 2>/dev/null || true)
    legacy_remote=${legacy_identity%%$'\t'*}
    legacy_local=${legacy_identity#*$'\t'}
    if [ -n "$legacy_identity" ] && [ "$recorded_name" = "$legacy_remote" ] && [ "$local_name" = "$legacy_local" ]; then
      continue
    fi

    log "STOP: migration identity mismatch for $v (prod='$recorded_name', main='$local_name')" >&2
    log "restore the original filename or add an exact reviewed legacy identity; never repair history blindly" >&2
    return 3
  done <<<"$local_files"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:?--app needs a name}"; shift 2 ;;
    --allow-out-of-order) ALLOW_OOO=1; shift ;;
    --confirm) CONFIRM="${2:?--confirm needs a token}"; shift 2 ;;
    *) usage ;;
  esac
done

EXPECT_REF=$(migration_target_ref "$APP") || usage
SOURCE_DIR="$REPO/apps/$APP"

export PATH="$HOME/.local/bin:$PATH"
for command in git tar mktemp flock sha256sum supabase curl jq timeout readlink find; do
  command -v "$command" >/dev/null || { log "$command is required on PATH" >&2; exit 1; }
done
GIT_BIN=$(readlink -f "$(command -v git)") \
  || { log "could not resolve the Git executable" >&2; exit 1; }
mkdir -p "$HOME/.claude/logs"
exec 9>"$HOME/.claude/logs/.migration-apply-$APP.lock"
flock -n 9 || { log "another apply for $APP is already running" >&2; exit 1; }

# Authenticate the caller-selected checkout before loading any standing
# credential. REPO remains overridable for compatibility, but it must be a
# canonical worktree of the one production source repository.
repo_path=$(cd -P "$REPO" 2>/dev/null && pwd -P) \
  || { log "repository path is unavailable: $REPO" >&2; exit 1; }
case "$GIT_BIN" in
  "$repo_path"/*) log "Git resolves inside the caller-selected repository: $GIT_BIN" >&2; exit 1 ;;
esac
repo_root=$(safe_git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null) \
  || { log "repository is not a Git worktree: $repo_path" >&2; exit 1; }
repo_root=$(cd -P "$repo_root" 2>/dev/null && pwd -P) \
  || { log "repository root is unavailable: $repo_root" >&2; exit 1; }
[ "$repo_root" = "$repo_path" ] \
  || { log "REPO must name the canonical Git worktree root (got $repo_path, root $repo_root)" >&2; exit 1; }
SOURCE_DIR="$repo_root/apps/$APP"
origin_url=$(safe_git -C "$repo_root" remote get-url origin 2>/dev/null) \
  || { log "repository origin is unreadable" >&2; exit 1; }
case "$origin_url" in
  "git@github.com:$ORIGIN_REPO.git"|"ssh://git@github.com/$ORIGIN_REPO.git"|"https://github.com/$ORIGIN_REPO"|"https://github.com/$ORIGIN_REPO.git") ;;
  *) log "repository origin is not $ORIGIN_REPO: $origin_url" >&2; exit 1 ;;
esac

SUPABASE_BIN=$(resolve_trusted_bin supabase) \
  || { log "could not resolve a trusted Supabase executable" >&2; exit 1; }
TIMEOUT_BIN=$(resolve_trusted_bin timeout) \
  || { log "could not resolve a trusted timeout executable" >&2; exit 1; }
CURL_BIN=$(resolve_trusted_bin curl) \
  || { log "could not resolve a trusted curl executable" >&2; exit 1; }
JQ_BIN=$(resolve_trusted_bin jq) \
  || { log "could not resolve a trusted jq executable" >&2; exit 1; }
TAR_BIN=$(resolve_trusted_bin tar) \
  || { log "could not resolve a trusted tar executable" >&2; exit 1; }
SHA256_BIN=$(resolve_trusted_bin sha256sum) \
  || { log "could not resolve a trusted sha256sum executable" >&2; exit 1; }
FIND_BIN=$(resolve_trusted_bin find) \
  || { log "could not resolve a trusted find executable" >&2; exit 1; }

linked=$(cat "$SOURCE_DIR/supabase/.temp/project-ref" 2>/dev/null || true)
[ "$linked" = "$EXPECT_REF" ] \
  || { log "linked ref '${linked:-none}' != expected '$EXPECT_REF' (run: cd $SOURCE_DIR && supabase link --project-ref $EXPECT_REF)" >&2; exit 1; }

# Never fetch inside the caller-selected repository: repo-local Git config may
# execute helpers that implant a later credential-bearing binary. Fetch a fixed
# GitHub URL into a fresh bare repository with global/system Git config disabled.
SNAPSHOT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/migration-apply-$APP.XXXXXX") \
  || { log "could not create immutable migration snapshot" >&2; exit 1; }
empty_template="$SNAPSHOT_ROOT/empty-template"
bare_repo="$SNAPSHOT_ROOT/source.git"
mkdir -p "$empty_template"
safe_git init --bare --quiet --template="$empty_template" "$bare_repo" \
  || { log "could not initialize private source repository" >&2; exit 1; }
safe_git --git-dir="$bare_repo" fetch --quiet --depth=1 \
  "git@github.com:$ORIGIN_REPO.git" main \
  || { log "could not fetch canonical $ORIGIN_REPO main" >&2; exit 1; }
main=$(safe_git --git-dir="$bare_repo" rev-parse FETCH_HEAD) \
  || { log "could not resolve immutable fetched main" >&2; exit 1; }
[[ "$main" =~ ^[0-9a-f]{40}$ ]] \
  || { log "fetched main did not resolve to a full commit SHA" >&2; exit 1; }
archive="$SNAPSHOT_ROOT/repo.tar"
safe_git --git-dir="$bare_repo" archive --format=tar --output "$archive" "$main" "apps/$APP/supabase" \
  || { log "could not archive immutable fetched main $main" >&2; exit 1; }
"$TAR_BIN" -xf "$archive" -C "$SNAPSHOT_ROOT" \
  || { log "could not extract immutable origin/main snapshot" >&2; exit 1; }
rm -f -- "$archive"
DIR="$SNAPSHOT_ROOT/apps/$APP"
if [ -L "$DIR/supabase/migrations" ]; then
  log "immutable snapshot migrations path is a symlink; refusing to leave the fetched tree" >&2
  exit 1
fi
[ -d "$DIR/supabase/migrations" ] \
  || { log "no tracked Supabase migrations for $APP at fetched main $main" >&2; exit 1; }
snapshot_symlink=$("$FIND_BIN" -P "$DIR/supabase/migrations" -type l -print -quit)
if [ -n "$snapshot_symlink" ]; then
  log "immutable snapshot contains a migration symlink; refusing to dereference it: ${snapshot_symlink#"$SNAPSHOT_ROOT/"}" >&2
  exit 1
fi
# The caller checkout may be stale, dirty, or on another branch. Its migration
# files are deliberately never compared, copied, hashed, dry-run, or applied.
mkdir -p "$DIR/supabase/.temp"
printf '%s\n' "$EXPECT_REF" >"$DIR/supabase/.temp/project-ref"
chmod -R a-w "$DIR/supabase/migrations"

# Token order: env, the bws record SUPABASE_ACCESS_TOKEN, then ~/.secrets, through
# the shared resolver in lib/supabase-access-token.sh. bws is pinned like every
# other binary here; an absent bws is "no bws" (BWS_BIN set but empty), never a
# PATH lookup inside the lib.
# shellcheck source=lib/supabase-access-token.sh
. "$SCRIPT_DIR/lib/supabase-access-token.sh"
BWS_BIN=$(resolve_trusted_bin bws) || BWS_BIN=
resolve_supabase_access_token
case $? in
  0) ;;
  2) log "SUPABASE_ACCESS_TOKEN refused: the bws record is malformed (see above)" >&2; exit 1 ;;
  *) log "SUPABASE_ACCESS_TOKEN unavailable (checked env, the bws record SUPABASE_ACCESS_TOKEN and ~/.secrets)" >&2; exit 1 ;;
esac
# The token may have arrived exported by the caller or ~/.secrets. Keep it as a
# shell value and scope it only to validated network clients.
export -n SUPABASE_ACCESS_TOKEN
pooler_url=$(read_remote_pooler_url) || exit $?
printf '%s' "$pooler_url" >"$DIR/supabase/.temp/pooler-url"

# ---- Independent inventory (read-only) ----------------------------------
listing=$(cd "$DIR" && SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN" "$TIMEOUT_BIN" 120 "$SUPABASE_BIN" --workdir "$DIR" migration list --linked 2>&1) || { log "migration list failed:"; printf '%s\n' "$listing" | tail -3 >&2; exit 1; }
# The 8-14 digit bound is a length test, not an awk interval: mawk, the default
# awk on Debian and Ubuntu, ignores {8,14} or reads it as {8}, which hides every
# 14-digit version (#21). Both remote parse sites must stay identical.
remote=$(printf '%s\n' "$listing" | awk -F'|' 'NF>=2 { gsub(/ /,"",$2); if (length($2) >= 8 && length($2) <= 14 && $2 ~ /^[0-9]+$/) print $2 }' | sort -u)
[ -n "$remote" ] || { log "could not parse remote migration history" >&2; exit 1; }
remote_max=$(printf '%s\n' "$remote" | sort -n | tail -1)

local_files=$(ls "$DIR/supabase/migrations/" 2>/dev/null | grep -E '^[0-9]{8,14}_.*\.sql$' | sort)
local_versions=$(printf '%s\n' "$local_files" | sed -E 's/^([0-9]+)_.*/\1/')

# A migration version is the Supabase ledger identity. Two local files sharing
# one version are ambiguous whether that version is pending or already applied,
# so stop before either the empty-pending shortcut or any CLI invocation.
dupes=$(printf '%s\n' "$local_versions" | sort | uniq -d)
if [ -n "$dupes" ]; then
  log "STOP: duplicate local migration version(s): $dupes" >&2
  exit 3
fi

# Remote-ahead drift: prod has versions main does not. Operator judgment only
# (repair vs restore-from-branch-history); this script never touches it.
remote_only=$(comm -23 <(printf '%s\n' "$remote" | sort) <(printf '%s\n' "$local_versions" | sort))
if [ -n "$remote_only" ]; then
  log "STOP: prod has versions with no file in this checkout (renamed or unmerged branch?):"
  printf '  %s\n' $remote_only
  log "resolve per the migration runbook (never 'migration repair' blindly)"
  exit 3
fi

# Version presence alone cannot detect the collision that matters: prod may
# record version V under migration name A while main now assigns V to name B.
# Read the authoritative ledger identities and require them to agree with both
# the CLI's version set and local filenames before taking the no-op or push path.
ledger_json=$(read_remote_identities) || exit $?
verify_remote_identities "$remote" "$ledger_json" || exit $?

pending_versions=$(comm -23 <(printf '%s\n' "$local_versions" | sort) <(printf '%s\n' "$remote"))
if [ -z "$pending_versions" ]; then
  log "nothing pending for $APP (prod max $remote_max) — every recorded version/name identity matches main"
  exit 0
fi
pending_files=$(for v in $pending_versions; do printf '%s\n' "$local_files" | grep "^${v}_"; done)

# Out-of-order: pending below prod's max needs --include-all, which sweeps —
# never add it silently.
ooo=$(for v in $pending_versions; do [ "$v" -lt "$remote_max" ] 2>/dev/null && echo "$v"; done)
PUSH_FLAGS=""
if [ -n "$ooo" ]; then
  if [ "$ALLOW_OOO" -eq 1 ]; then
    log "out-of-order acknowledged (--allow-out-of-order): $ooo — using --include-all"
    PUSH_FLAGS="--include-all"
  else
    log "STOP: pending version(s) sort below prod's max $remote_max: $ooo"
    log "plain 'db push' refuses this pending set; re-run with --allow-out-of-order to acknowledge --include-all"
    exit 3
  fi
fi

# ---- CLI dry-run must agree with the independent computation --------------
dry=$(cd "$DIR" && SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN" "$TIMEOUT_BIN" 120 "$SUPABASE_BIN" --workdir "$DIR" db push --dry-run $PUSH_FLAGS 2>&1)
dry_set=$(printf '%s\n' "$dry" | grep -oE '[0-9]{8,14}_[A-Za-z0-9_-]+\.sql' | sort -u)
expected_set=$(printf '%s\n' "$pending_files" | sort -u)
if [ "$dry_set" != "$expected_set" ]; then
  log "STOP: CLI dry-run set differs from independently computed set"
  log "computed:"; printf '  %s\n' $expected_set
  log "dry-run:";  printf '  %s\n' ${dry_set:-'(none)'}
  exit 3
fi

# ---- Approval moment ------------------------------------------------------
manifest=$(approval_manifest) \
  || { log "could not hash the immutable pending SQL files" >&2; exit 3; }
token=$(printf '%s\n' "$manifest" | "$SHA256_BIN" | cut -d' ' -f1)
log "app=$APP ref=$EXPECT_REF commit=$main prod-max=$remote_max"
log "PENDING (exact immutable set — nothing else will be applied):"
printf '  %s\n' $expected_set
log "dry-run matches computed set (OK); no remote-ahead drift; every recorded version/name identity agrees"
log "confirmation binds app + commit + ordered filenames + SQL SHA-256 hashes"

if [ "$DRY_RUN" = 1 ] || [ -z "$CONFIRM" ]; then
  log "confirm token: $token"
  log "apply with: DRY_RUN=0 $0 --app $APP${ALLOW_OOO:+ }$( [ "$ALLOW_OOO" -eq 1 ] && echo '--allow-out-of-order ' )--confirm $token"
  exit 0
fi

[ "$CONFIRM" = "$token" ] \
  || { log "confirm token mismatch (got '$CONFIRM', immutable snapshot hashes to '$token') — app, commit, filename set, or SQL bytes changed since approval; nothing written" >&2; exit 4; }
# Rehash immediately before the write. The private snapshot is read-only, but
# this makes any same-user tampering between dry-run and approval fail closed.
prewrite_manifest=$(approval_manifest) \
  || { log "could not rehash the immutable pending SQL files before write" >&2; exit 3; }
prewrite_token=$(printf '%s\n' "$prewrite_manifest" | "$SHA256_BIN" | cut -d' ' -f1)
[ "$prewrite_token" = "$token" ] \
  || { log "immutable snapshot changed after dry-run; nothing written" >&2; exit 4; }

# ---- The write ------------------------------------------------------------
log "applying $(printf '%s\n' "$expected_set" | grep -c .) migration(s) from commit ${main:0:12} to $EXPECT_REF..."
out=$(cd "$DIR" && SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN" "$SUPABASE_BIN" --workdir "$DIR" db push $PUSH_FLAGS 2>&1 <<< "Y") || { log "push FAILED:"; printf '%s\n' "$out" | tail -5 >&2; exit 5; }

# ---- Post-verify: history must now equal the exact approved transition -----
listing2=$(cd "$DIR" && SUPABASE_ACCESS_TOKEN="$SUPABASE_ACCESS_TOKEN" "$TIMEOUT_BIN" 120 "$SUPABASE_BIN" --workdir "$DIR" migration list --linked 2>/dev/null)
remote2=$(printf '%s\n' "$listing2" | awk -F'|' 'NF>=2 { gsub(/ /,"",$2); if (length($2) >= 8 && length($2) <= 14 && $2 ~ /^[0-9]+$/) print $2 }' | sort -u)
# An empty parse would also fail the delta check below, but as a list of every
# expected version, which reads as "nothing applied"; name the real failure.
[ -n "$remote2" ] || { log "POST-VERIFY FAILED: could not parse post-push migration history" >&2; exit 5; }
expected_remote2=$(printf '%s\n%s\n' "$remote" "$pending_versions" | grep -E '^[0-9]+$' | sort -u)
post_delta=$(comm -3 <(printf '%s\n' "$expected_remote2") <(printf '%s\n' "$remote2"))
if [ -n "$post_delta" ]; then
  log "POST-VERIFY FAILED: remote history differs from preflight + approved set:" >&2
  printf '  %s\n' $post_delta >&2
  exit 5
fi
ledger_json2=$(read_remote_identities) || { log "POST-VERIFY FAILED: remote identities unreadable after push" >&2; exit 5; }
if ! verify_remote_identities "$remote2" "$ledger_json2"; then
  log "POST-VERIFY FAILED: remote migration identities do not match main after push" >&2
  exit 5
fi
log "applied + history verified: every approved version/name identity is recorded and matches main"
log "remaining runbook verification (agent/MCP): service_role-only grants on touched functions, security+performance advisors"
log "then close the pending-prod-migration issue for $APP"
exit 0
