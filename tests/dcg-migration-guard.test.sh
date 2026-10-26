#!/usr/bin/env bash
# The prod-migration guard posture, proven by ASKING dcg, not by reading config.
#
# WHY. On 2026-08-29 a forensic dig found an agent had applied a migration to
# a private app's PRODUCTION database from an unmerged worktree branch, with no
# prompt and no block. Its own transcript: "Applying the migration to production
# (applied-first, since the cron and webhook call these RPCs)." At that moment
# `dcg explain "supabase db push --linked"` returned ALLOW / "quick-rejected (no
# keywords)", because the database.supabase pack was not in [packs] enabled, and
# that app's settings.local.json pre-allows `Bash(supabase db *)` so nothing
# prompted either. Not a one-off: the same pre-merge apply happened for three
# other migrations inside 48h.
#
# TWO-SIDED ON PURPOSE. A guard that denies everything is as useless as one that
# denies nothing — it just gets switched off instead of ignored. The ALLOW half
# below is the half that keeps this posture alive: db push --dry-run, migration
# list/new, db diff, gen types, db dump and ordinary psql must stay frictionless,
# or the next person to hit the friction removes the pack.
#
# TWO TIERS, BECAUSE CI HAS NO dcg. Tier 2 runs `dcg explain` and reads the real
# verdict — the only thing that can catch a pack enabled but shadowed,
# misspelled, or overridden. It needs the binary, so it does not run on a
# runner. Tier 1 is text assertions over config.toml: strictly weaker, but it
# runs everywhere and catches the regression that actually happens (a deleted
# pack line or override entry).
#
# The split exists because v1 of this suite exited 0 when dcg was absent, and CI
# is exactly that. Its shipping run printed "SKIP: dcg not on PATH" under a green
# check — verifying nothing, while claiming to guard the route to prod. A skip
# that reads as a pass is the failure mode this whole PR series is about, so the
# suite that enforces it does not get to commit it.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export DCG_CONFIG="$REPO/config/dcg/config.toml"

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1" >&2; }

if [ ! -f "$DCG_CONFIG" ]; then
  echo "FAIL: dcg config not found at $DCG_CONFIG — cannot verify posture" >&2
  exit 1
fi

echo "dcg-migration-guard.test.sh"

# --- TIER 1: config invariants. ALWAYS RUNS, dcg or no dcg. -----------------
# The first version of this suite exited 0 when dcg was absent, which is what
# CI is. Measured on the very run that shipped it: "SKIP: dcg not on PATH;
# migration-guard posture not verified" — green check, nothing verified. That is
# precisely the skip-reads-as-green failure this PR series exists to remove, so
# it does not get to live in the suite that removes it.
#
# These are text assertions and weaker than tier 2 by design: they cannot see a
# pack that is enabled but shadowed, which is why tier 2 exists. What they DO
# catch is the realistic regression — someone deleting the pack line or an
# override entry — and they catch it on every runner, which tier 2 cannot.
grep -qE '^\s*"database\.supabase",' "$DCG_CONFIG" \
  && ok "database.supabase is in [packs] enabled" \
  || bad "database.supabase missing from [packs] enabled — supabase db push returns ALLOW again"

# The three routes the pack itself does not cover. Asserted individually so a
# deletion names which one went.
grep -qF 'psql\\b[^|;&]*\\s-f\\s+[^\\s|;&]*supabase/migrations/' "$DCG_CONFIG" \
  && ok "override blocks: psql -f <migration>" \
  || bad "override missing: psql -f <migration> is unguarded again"
grep -qF 'psql\\b[^|;&]*<\\s*[^\\s|;&]*supabase/migrations/' "$DCG_CONFIG" \
  && ok "override blocks: psql < <migration>" \
  || bad "override missing: psql < <migration> is unguarded again"
grep -qF 'supabase/migrations/[^\\s|;&]*\\.sql[^|;&]*\\|\\s*psql\\b' "$DCG_CONFIG" \
  && ok "override blocks: <migration> | psql" \
  || bad "override missing: <migration> | psql is unguarded again"

# [overrides] allow is a whole-command bypass — an entry here launders every
# rule for the rest of the command, including the ones it never described. The
# config says it MUST STAY EMPTY; assert that, because a single entry would
# silently undo everything above.
grep -qE '^allow = \[\]' "$DCG_CONFIG" \
  && ok "[overrides] allow is still empty" \
  || bad "[overrides] allow is non-empty — a whole-command bypass can launder the migration guard"

# --- TIER 2: behaviour. Needs dcg, so it runs on a dev box and not in CI. ----
if ! command -v dcg >/dev/null 2>&1; then
  printf '\n%s passed, %s failed (tier 1 only)\n' "$pass" "$fail"
  echo "note: dcg not on PATH — config invariants verified, live verdicts NOT verified" >&2
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# A real regular file under supabase/migrations/. database.postgresql's
# stdin-unverified rule denies a MISSING -f target regardless of path, so a
# fabricated path would pass the DENY cases for the wrong reason and prove
# nothing about the migration guard.
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT
mkdir -p "$TD/apps/acme-web/supabase/migrations"
MIG="$TD/apps/acme-web/supabase/migrations/20270829000100_probe.sql"
printf 'create table public.probe (id int);\n' > "$MIG"
PLAIN="$TD/seed.sql"
printf 'select 1;\n' > "$PLAIN"

verdict() { dcg explain "$1" 2>&1 | grep -oE 'Decision: [A-Z]+' | head -1 | sed 's/Decision: //'; }

want() { # want <expected> <label> <command>
  local expected=$1 label=$2 cmd=$3 got
  got=$(verdict "$cmd")
  case "$got" in
    "$expected") ok "$label ($got)" ;;
    "") bad "$label — dcg produced no verdict (explain failed)" ;;
    *)  bad "$label — got $got, want $expected" ;;
  esac
}


# --- the routes to prod that must not be silent -----------------------------
want DENY "supabase db push --linked"      "supabase db push --linked"
want DENY "supabase db push via pnpm exec" "pnpm --filter acme-web exec supabase db push"
want DENY "supabase db reset --linked"     "supabase db reset --linked"
want DENY "supabase migration repair"      "supabase migration repair --status reverted 20270829000100"
# The observed real-world shape: connection string in an env var, so no
# host-based pattern could ever match it. The migration PATH is the literal part.
want DENY "psql \$URL -f <migration>"      "psql \"\$POSTGRES_URL_NON_POOLING\" -f $MIG"
want DENY "psql < <migration>"             "psql \"\$POSTGRES_URL_NON_POOLING\" < $MIG"
want DENY "cat <migration> | psql"         "cat $MIG | psql \"\$POSTGRES_URL_NON_POOLING\""

# --- and the ordinary work that must stay frictionless ----------------------
want ALLOW "db push --dry-run"             "supabase db push --linked --dry-run"
want ALLOW "migration list"                "supabase migration list --linked"
want ALLOW "migration new"                 "supabase migration new add_widget"
want ALLOW "db diff"                       "supabase db diff --linked"
want ALLOW "gen types"                     "supabase gen types typescript --linked"
want ALLOW "db dump (the backup lever)"    "supabase db dump --linked -f $TD/backup.sql"
want ALLOW "status"                        "supabase status"
want ALLOW "psql read-only -c"             "psql \"\$DEV_URL\" -c 'select count(*) from users'"
want ALLOW "psql -f a non-migration file"  "psql \"\$DEV_URL\" -f $PLAIN"

# --- the denial must TEACH, not just refuse --------------------------------
# The pack's own reason for db push says only "Use --dry-run to preview first",
# which is true and useless: --dry-run never applies anything, so an agent that
# needs a migration live dry-runs it, succeeds, and reaches for `dcg allow-once`
# — routing around the guard rather than using the safe route. An override with
# a better reason fixes that, and this pins it: a denial that stops naming the
# alternative silently recreates the allow-once habit.
# Captured, not piped: under pipefail, grep -q exits at its first match and
# dcg's next write takes SIGPIPE (141), failing a run that matched. Measured
# 1 in 400 bare pipes and 6 in 40 runs of this suite (dotfiles#1612).
explain=$(dcg explain 'supabase db push --linked' 2>&1)
if grep -qF 'migration-apply.sh' <<<"$explain"; then
  ok "db push denial names the sanctioned path"
else
  bad "db push denial no longer names migration-apply.sh — agents will reach for allow-once instead"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
