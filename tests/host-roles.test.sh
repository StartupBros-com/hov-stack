#!/usr/bin/env bash
# hosts.tsv + lib/profile.sh: the role model, and the two guards that depend on it.
#
# Roles answer "whose live state is canonical" by DECLARATION rather than by
# which machine someone happened to run `sync.sh push` on. Before this, workstation was
# canonical by accident.
#
# Planted negatives, each verified failing alone before this shipped:
#   declare a second workstation      -> case 4
#   let profile_role default a role   -> case 2
#   raise the shrink threshold        -> case 7
#   drop backup-harness from the       -> case 6
#     satellite exclusion
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

DOTFILES_ROLE_FILE=$REPO/hosts.tsv
export DOTFILES_ROLE_FILE
# shellcheck source=../lib/profile.sh
. "$REPO/lib/profile.sh"

# 1. Zero-run-green guard: the table must actually contain hosts.
n=$(grep -cvE '^\s*(#|$)' "$REPO/hosts.tsv")
[ "$n" -ge 2 ] && ok || bad "hosts.tsv declares $n hosts, expected >=2"

# 2. An UNMAPPED host resolves to nothing and returns non-zero. Defaulting would
#    be silent either way: "satellite" disables a workstation's timers,
#    "workstation" lets a second machine publish over the canonical one.
( unset DOTFILES_ROLE; profile_role no-such-host-xyz >/dev/null 2>&1 ) \
  && bad "unmapped host resolved to a role" || ok

# 3. Both real machines resolve, and to different roles.
w=$( unset DOTFILES_ROLE; profile_role workstation-host 2>/dev/null )
x=$( unset DOTFILES_ROLE; profile_role satellite-host 2>/dev/null )
[ "$w" = workstation ] && [ "$x" = satellite ] \
  && ok || bad "expected workstation-host=workstation satellite-host=satellite, got workstation-host=$w satellite-host=$x"

# 4. EXACTLY ONE workstation. Two would mean two machines pushing canonical
#    state, which is the corruption the whole model exists to prevent.
c=$(awk -F'\t' '!/^#/ && NF>=2 && $2=="workstation"' "$REPO/hosts.tsv" | wc -l)
[ "$c" -eq 1 ] && ok || bad "hosts.tsv declares $c workstations, must be exactly 1"

# 5. Every declared role is one of the two known ones.
u=$(awk -F'\t' '!/^#/ && NF>=2 && $2!="workstation" && $2!="satellite" {print $2}' "$REPO/hosts.tsv")
[ -z "$u" ] && ok || bad "unknown role(s) in hosts.tsv: $u"

# 6. The satellite timer set must EXCLUDE the writers. A second host writing
#    the canonical backup duplicates or clobbers the workstation's copy.
sat=$(sed -n '/satellite)/,/;;/p' "$REPO/sync.sh" | grep -o '_enable="[^"]*"' | head -1)
leak=""
for t in backup-harness; do
  case "$sat" in *"$t"*) leak="$leak $t" ;; esac
done
[ -z "$leak" ] && ok || bad "satellite would enable workstation-only timers:$leak"

# 7. The shrink guard refuses the exact accident that motivated it (693 -> 46)
#    and permits an ordinary edit.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n '/^push_shrink_guard() {/,/^}/p' "$REPO/sync.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || bad "push_shrink_guard not found in sync.sh"
# shellcheck source=/dev/null
. "$T/fn.sh"
seq 1 693 > "$T/canon"; seq 1 46 > "$T/small"; seq 1 650 > "$T/similar"
if push_shrink_guard "$T/small" "$T/canon" >/dev/null 2>&1; then
  bad "shrink guard accepted a 693->46 line loss"
elif push_shrink_guard "$T/similar" "$T/canon" >/dev/null 2>&1; then ok
else bad "shrink guard refused an ordinary 693->650 edit"; fi

# 8. push must consult the role. A grep, not a run: invoking push writes the repo.
grep -q 'profile_is workstation' "$REPO/sync.sh" \
  && ok || bad "sync.sh push does not gate on the workstation role"

# 8b. AND ITS REFUSAL MUST NOT ADVERTISE A HATCH THAT NO LONGER OPENS.
#
#     The message used to end "Deliberate exception: DOTFILES_ROLE=workstation
#     sync.sh push", which was true before the table existed. Both paths through
#     profile_role now close it -- a declared host has the table win over a
#     contradicting env var, and an undeclared host is refused the workstation
#     role outright -- and a declared satellite is the only thing that reaches
#     the refusal at all. So the message named a route to exactly the population
#     that cannot take it.
#
#     Pinned as a test rather than just fixed, because a stale error message is
#     invisible to every other check here: the gate was correct the whole time
#     and only its explanation had rotted. Cases 12 and 13 below prove the two
#     closures behaviourally; this one keeps the text honest about them.
#     Comment lines are stripped first. Without that this greps the comment
#     that EXPLAINS the removal and fails on a correct file -- the same
#     self-matching trap that made an earlier assertion in this harness vacuous
#     in the opposite direction.
_refusal=$(sed -n '/^push() {/,/^  fi$/p' "$REPO/sync.sh" | grep -v '^[[:space:]]*#' | grep -c 'DOTFILES_ROLE=workstation sync.sh push')
[ "${_refusal:-1}" -eq 0 ] \
  && ok || bad "push's refusal still advertises DOTFILES_ROLE=workstation, which no host can use"

# 9. The unmapped-host DRIFT must require a readable table. A tree with no
#    hosts.tsv is not an undeclared machine -- it is a partial checkout or a
#    hermetic fixture, and claiming "no role in hosts.tsv" where none exists
#    broke two suites for a condition neither was testing.
sync=$REPO/sync.sh
grep -q 'DOTFILES_ROLE_FILE:-.HERE/hosts.tsv' "$sync" \
  && ok || bad "unmapped-host drift is not gated on the table being readable"

# 10. But it must STILL fire when a table IS readable and this host is absent
#     from it -- otherwise case 9 is satisfied by deleting the check outright.
#     /dev/null is the minimal such table: readable, and containing no host.
#     Output is captured BEFORE matching: this suite runs `set -o pipefail`, and
#     `sync.sh check` exits 1 whenever it reports ANY drift, so piping it into
#     grep fails the pipeline even when the match succeeds. The first version of
#     this case failed for exactly that reason and not because the check was
#     broken -- a test asserting on the wrong thing looks identical to a bug.
_out=$(DOTFILES_ROLE_FILE=/dev/null bash "$sync" check 2>&1 || true)
case "$_out" in
  *"no role in hosts.tsv"*) ok ;;
  *) bad "unmapped host not reported even with a readable table" ;;
esac

# 11. THE TABLE BEATS THE ENVIRONMENT for a declared host. Previously
#     profile_role returned any nonempty DOTFILES_ROLE before consulting
#     hosts.tsv, so any process on any machine could claim `workstation` with one
#     env var and push canonical state -- defeating the feature this file exists
#     for. Verified against the real destructive case: DOTFILES_ROLE=workstation
#     sync.sh push from this satellite once replaced the workstation's 693-line
#     settings.json with the laptop's.
r=$( unset DOTFILES_ROLE; DOTFILES_ROLE=workstation profile_role satellite-host 2>/dev/null )
[ "$r" = satellite ] && ok || bad "DOTFILES_ROLE overrode a declared host (got '$r')"

# 12. But an UNDECLARED host may still self-declare, or a rebuild under a
#     temporary hostname could not install at all.
r=$( DOTFILES_ROLE=satellite profile_role no-such-host-xyz 2>/dev/null )
[ "$r" = satellite ] && ok || bad "undeclared host could not use the override (got '$r')"

# 13. install() must RECONCILE, not only enable. Without a disable path a
#     satellite keeps every singleton timer it already had, and the migration
#     this model exists for is a no-op against the real collision risk.
grep -q 'systemctl --user disable --now' "$REPO/sync.sh" \
  && ok || bad "no role-driven disable path in install()"

# 14. An unrecognised role must be FATAL at install and DRIFT at check. It used
#     to enable nothing while check() still called the host mapped, so a typo on
#     a rebuilt machine produced a green check and zero scheduled work.
grep -q 'unrecognised role' "$REPO/sync.sh" \
  && ok || bad "check() does not flag an unrecognised role"
grep -q 'profile_assert_known' "$REPO/sync.sh" \
  && ok || bad "profile_assert_known still has no consumer"

# 16. The WORKSTATION role requires a hosts.tsv row, unconditionally. An
#     unregistered host claiming it by environment variable is exactly the hole
#     the table exists to close -- push authority hangs off this role, and a
#     fresh machine, a CI runner or any third box could otherwise assert it.
r=$( DOTFILES_ROLE=workstation profile_role some-unregistered-box 2>/dev/null )
rc=$?
{ [ "$rc" -ne 0 ] && [ -z "$r" ]; } \
  && ok || bad "unregistered host was granted workstation by env var (rc=$rc, role='$r')"

# 17. But `satellite` is still allowed for an unregistered host: it fails DOWN,
#     enabling the minimal timer set and holding no push authority. Without this
#     a rebuild under a temporary hostname could not install at all.
r=$( DOTFILES_ROLE=satellite profile_role some-unregistered-box 2>/dev/null )
[ "$r" = satellite ] && ok || bad "unregistered host could not self-declare as satellite (got '$r')"

# 18. The cron-migrated role set is exactly two, and remains outside the
# satellite base set. Workstation admission is dynamic per ownership scan, so
# hardcoding these into the workstation literal would bypass the safety gate.
critical=$(sed -n 's/^CRITICAL_SILENCE_TIMERS="\(.*\)"/\1/p' "$REPO/sync.sh")
[ "$(printf '%s\n' "$critical" | wc -w)" -eq 2 ] \
  && ok || bad "critical-silence role set does not contain exactly two timers"
for timer in \
  mcp-servers-update.timer \
  skills-update.timer; do
  case " $critical " in *" $timer "*) ok ;; *) bad "migrated role set omits $timer" ;; esac
  case "$sat" in *"$timer"*) bad "satellite base role directly admits $timer" ;; *) ok ;; esac
done

# 19. Role reconciliation and U5's record CAS share the one named lock; a
# second lock would make each path individually serialized but jointly racy.
grep -q 'flock -n 8' "$REPO/sync.sh" \
  && grep -q 'CLAUDE_SYNC_CUTOVER_LOCK' "$REPO/sync.sh" \
  && ok || bad "role reconciliation does not acquire the shared cutover lock"

if [ "$fail" -eq 0 ]; then
  echo "ok — host roles: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — host roles: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
