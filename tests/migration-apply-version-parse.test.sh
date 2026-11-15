#!/usr/bin/env bash
# migration-apply-version-parse.test.sh: pins the migration-version patterns in
# scripts/migration-apply.sh against each other.
#
# migration-apply.sh never runs here -- it needs a linked Supabase project and
# it pushes to prod. What IS testable without one is the part that was actually
# wrong: the script recognises a "migration version" in four places, and those
# four patterns have to agree or its safety checks read a different world than
# the CLI does.
#
#   local_files   ^[0-9]{8,14}_.*\.sql$   (was unbounded)
#   remote        8-14 digits, jq         (was awk {10,14}, {8,14}, a length test)
#   dry_set       [0-9]{8,14}_...\.sql    (was {10,14})
#   remote2       the same helper as remote
#
# Both remote sites now read the CLI's JSON through supabase_remote_versions in
# lib/supabase-migration-list.sh. They used to scrape the CLI's table with awk,
# which broke twice: mawk ignored the {8,14} interval (#21),
# then CLI v2.122.0 backticked every table cell and the parse read zero
# versions. The old mawk leg went with the awk program; the helper's own suite,
# supabase-migration-list.test.sh, runs it against the vendor's real output.
#
# The bug the {10,14} -> {8,14} change fixes: an 8- or 9-digit version already
# recorded on prod parsed as a local version but NOT as a remote one. It then
# survived `comm -23 local remote` into pending_versions, so the controller's
# independent inventory disagreed with the actual Supabase history. Keeping all
# four parsers symmetric ensures its dry-run and post-verify checks reason over
# the same migration ledger identity.
#
# Every local pattern below is EXTRACTED from the script rather than restated,
# and the remote side runs the sourced helper the script runs, so this test
# tracks the real files instead of copies that can drift away from them.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../scripts" && pwd)"
SRC="$SCRIPTS/migration-apply.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find migration-apply.sh at $SRC"; exit 1; }
# shellcheck source=../scripts/lib/supabase-migration-list.sh
. "$SCRIPTS/lib/supabase-migration-list.sh"

pass=0; fail=0
ck_eq() {
  if [ "$2" = "$3" ]; then pass=$((pass + 1));
  else fail=$((fail + 1)); echo "FAIL: $1 (got '$2', want '$3')"; fi
}
ck_has() {
  if grep -qF -- "$3" <<<"$2"; then pass=$((pass + 1));
  else fail=$((fail + 1)); echo "FAIL: $1"; echo "  wanted: $3"; echo "  got: $2"; fi
}
ck_not() {
  if grep -qF -- "$3" <<<"$2"; then fail=$((fail + 1)); echo "FAIL: $1"; echo "  did NOT want: $3"; echo "  got: $2";
  else pass=$((pass + 1)); fi
}

# --- extract the live expressions ----------------------------------------
local_re=$(sed -n "s/.*local_files=.*grep -E '\([^']*\)'.*/\1/p" "$SRC" | head -1)
dry_re=$(sed -n "s/.*dry_set=.*grep -oE '\([^']*\)'.*/\1/p" "$SRC" | head -1)

[ -n "$local_re" ]   || { echo "FAIL: could not extract the local_files grep pattern"; exit 1; }
[ -n "$dry_re" ]     || { echo "FAIL: could not extract the dry_set grep pattern"; exit 1; }

# Both remote reads (inventory + post-verify) must ask for JSON and share the one
# parse; a fix applied to one and not the other reintroduces the hole at
# push-verify time.
ck_eq "both remote reads pin --output-format json" \
  "$(grep -cF 'migration list --linked --output-format json' "$SRC")" "2"
ck_eq "both remote reads parse through supabase_remote_versions" \
  "$(grep -cF '| supabase_remote_versions)' "$SRC")" "2"
ck_eq "no remote read scrapes the CLI's table with awk" \
  "$(grep -cF "awk -F'|'" "$SRC")" "0"

# --- helpers that run the REAL expressions --------------------------------
# One migration-list JSON row per (local, remote) pair, in the CLI's shape.
listing_json() {
  local rows="" sep="" l r
  while [ "$#" -ge 2 ]; do
    l=$1 r=$2; shift 2
    rows="$rows$sep{\"local\":\"$l\",\"remote\":\"$r\",\"time\":\"t\"}"; sep=,
  done
  printf '{"migrations":[%s],"message":"Migrations listed"}\n' "$rows"
}
parse_remote() { listing_json x "$1" | supabase_remote_versions; }
is_local_file() { printf '%s\n' "$1" | grep -E "$local_re"; }
parse_dry()    { printf '%s\n' "$1" | grep -oE "$dry_re" | sort -u; }

LISTING=$(listing_json 20240101000000 20240101000000 '' 20240102 20240103000000 '')

# --- the fix --------------------------------------------------------------
got=$(printf '%s\n' "$LISTING" | supabase_remote_versions)
ck_has "14-digit remote version parses" "$got" "20240101000000"
ck_has "8-digit remote version parses" "$got" "20240102"
ck_not "a local-only row contributes no remote version" "$got" "20240103000000"

# --- the round-trip invariant that was broken -----------------------------
# Anything the local-file pattern calls a version must be visible to the remote
# parser, or prod state disappears from every drift and collision check.
for v in 20240102 202401021 20240101000000; do
  lf=$(is_local_file "${v}_thing.sql")
  ck_eq "local pattern accepts ${v}_thing.sql" "$lf" "${v}_thing.sql"
  rr=$(parse_remote "$v")
  ck_eq "remote parser also sees $v (round-trip)" "$rr" "$v"
done

# --- dry-run agreement ----------------------------------------------------
# dry_set and expected_set are compared for exact equality, so a filename the
# dry-run pattern cannot see becomes a hard STOP on a legitimate push.
ck_eq "dry-run pattern sees an 8-digit filename" \
  "$(parse_dry 'Applying migration 20240102_thing.sql...')" "20240102_thing.sql"
ck_eq "dry-run pattern still sees a 14-digit filename" \
  "$(parse_dry 'Applying migration 20240101000000_thing.sql...')" "20240101000000_thing.sql"

# --- the lower-bound symmetry that closes the residual gap ----------------
# A local version outside the remote/dry-run grammar is invisible to at least
# one side of the exact-set comparison, so reject it before inventory.
ck_eq "local pattern rejects a 7-digit version" \
  "$(is_local_file '2024010_thing.sql')" ""
ck_eq "remote parser also rejects a 7-digit version" \
  "$(parse_remote 2024010)" ""
# The upper bound and the digits-only rule, which the old mawk leg pinned.
for v in 202401010000001 2024010a; do
  ck_eq "remote parser rejects $v" "$(parse_remote "$v")" ""
done

echo
if [ "$fail" -eq 0 ]; then
  echo "ok — migration-apply version parse: $pass/$pass assertions passed"
  exit 0
fi
echo "FAILED — migration-apply version parse: $fail failed, $pass passed"
exit 1
