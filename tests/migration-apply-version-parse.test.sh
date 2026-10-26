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
#   remote        8-14 digits by length   (was {10,14}, then {8,14})
#   dry_set       [0-9]{8,14}_...\.sql    (was {10,14})
#   remote2       8-14 digits by length   (was {10,14}, then {8,14})
#
# The two remote sites are awk, and awk gets a length test instead of an
# interval: mawk, Debian's and Ubuntu's default awk, ignores {8,14} or reads it
# as {8}, so every 14-digit version vanished there (#21). The mawk leg below
# runs the extracted program under mawk whenever mawk is installed.
#
# The bug the {10,14} -> {8,14} change fixes: an 8- or 9-digit version already
# recorded on prod parsed as a local version but NOT as a remote one. It then
# survived `comm -23 local remote` into pending_versions, so the controller's
# independent inventory disagreed with the actual Supabase history. Keeping all
# four parsers symmetric ensures its dry-run and post-verify checks reason over
# the same migration ledger identity.
#
# Every pattern below is EXTRACTED from the script rather than restated, so this
# test tracks the real file instead of a copy that can drift away from it.
set -uo pipefail

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../scripts" && pwd)/migration-apply.sh"
[ -f "$SRC" ] || { echo "FAIL: cannot find migration-apply.sh at $SRC"; exit 1; }

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
remote_awk=$(grep -m1 -oE "awk -F'\|' '[^']+'" "$SRC" | sed -E "s/^awk -F'\|' '//; s/'$//")
local_re=$(sed -n "s/.*local_files=.*grep -E '\([^']*\)'.*/\1/p" "$SRC" | head -1)
dry_re=$(sed -n "s/.*dry_set=.*grep -oE '\([^']*\)'.*/\1/p" "$SRC" | head -1)

[ -n "$remote_awk" ] || { echo "FAIL: could not extract the remote-parse awk program"; exit 1; }
[ -n "$local_re" ]   || { echo "FAIL: could not extract the local_files grep pattern"; exit 1; }
[ -n "$dry_re" ]     || { echo "FAIL: could not extract the dry_set grep pattern"; exit 1; }

# Both remote parse sites (inventory + post-verify) must stay identical; a fix
# applied to one and not the other reintroduces the hole at push-verify time.
remote_sites=$(grep -cF 'length($2) >= 8 && length($2) <= 14 && $2 ~ /^[0-9]+$/' "$SRC")
ck_eq "both remote parse sites carry the same bound" "$remote_sites" "2"
interval_sites=$(grep -F "awk -F'|'" "$SRC" | grep -cF '{8,14}')
ck_eq "no awk parse site uses an interval expression" "$interval_sites" "0"

# --- helpers that run the REAL expressions --------------------------------
parse_remote() { printf '%s\n' "$1" | awk -F'|' "$remote_awk"; }
is_local_file() { printf '%s\n' "$1" | grep -E "$local_re"; }
parse_dry()    { printf '%s\n' "$1" | grep -oE "$dry_re" | sort -u; }

LISTING=$(cat <<'EOF'
        Local          |        Remote         |     Time (UTC)
  ---------------------|-----------------------|---------------------
   20240101000000      | 20240101000000        | 2024-01-01 00:00:00
                       | 20240102              | 2024-01-02 00:00:00
   20240103000000      |                       | 2024-01-03 00:00:00
EOF
)

# --- the fix --------------------------------------------------------------
got=$(parse_remote "$LISTING")
ck_has "14-digit remote version parses" "$got" "20240101000000"
ck_has "8-digit remote version parses" "$got" "20240102"
ck_not "a local-only row contributes no remote version" "$got" "20240103000000"

# --- the round-trip invariant that was broken -----------------------------
# Anything the local-file pattern calls a version must be visible to the remote
# parser, or prod state disappears from every drift and collision check.
for v in 20240102 202401021 20240101000000; do
  lf=$(is_local_file "${v}_thing.sql")
  ck_eq "local pattern accepts ${v}_thing.sql" "$lf" "${v}_thing.sql"
  rr=$(parse_remote "  x | $v | t")
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
  "$(parse_remote '  x | 2024010 | t')" ""

# --- mawk portability (#21) -----------------------------------------------
# The system awk above is often gawk; mawk is what a stock Debian or Ubuntu
# host runs. The same extracted program must give the same answers there.
if command -v mawk >/dev/null 2>&1; then
  parse_remote_mawk() { printf '%s\n' "$1" | mawk -F'|' "$remote_awk"; }
  for v in 20240102 202401021 20240101000000; do
    ck_eq "mawk: remote parser sees $v" "$(parse_remote_mawk "  x | $v | t")" "$v"
  done
  for v in 2024010 202401010000001 2024010a; do
    ck_eq "mawk: remote parser rejects $v" "$(parse_remote_mawk "  x | $v | t")" ""
  done
  ck_eq "mawk: the listing parses as under the system awk" \
    "$(parse_remote_mawk "$LISTING" | sort -u)" "$(parse_remote "$LISTING" | sort -u)"
else
  echo "note: mawk not installed; the mawk portability leg did not run"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ok — migration-apply version parse: $pass/$pass assertions passed"
  exit 0
fi
echo "FAILED — migration-apply version parse: $fail failed, $pass passed"
exit 1
