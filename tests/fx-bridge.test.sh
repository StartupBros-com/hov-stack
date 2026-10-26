#!/usr/bin/env bash
# Tests for harnesses/fx/sync-skills.sh + harnesses/fx/sync.sh (PR #419 destructive-sync fixes).
#
# The point of this suite is the DATA-SAFETY guarantee set that the PR's
# adversarial review reproduced as live failures:
#   - case 6 (PLANTED NEGATIVE): a crash between the swap renames must be
#     recoverable — revert copy_skill's parked-rename swap to rm-then-mv and
#     there is no parked copy to recover, so the skill stays vanished.
#   - case 7 (PLANTED NEGATIVE): an in-flight staging dir carries the ownership
#     marker; drop the dot-dir guard from orphan cleanup / check and it is
#     reaped as an orphan (install) or flagged as drift (check).
#   - case 4 (PLANTED NEGATIVE): an empty source view used to `return 1`,
#     which aborted the whole set -e installer; it must be a no-op success
#     that prunes nothing.
# Hermetic: fabricated plugin cache + installed_plugins.json under mktemp;
# HOME/FX_SKILLS/FX_HOME all point at scratch. Never touches ~/.fx.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for dep in jq rsync flock; do
  command -v "$dep" >/dev/null 2>&1 || { echo "FAIL: $dep is required for this suite (refusing to skip-green)" >&2; exit 1; }
done

pass=0 fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ if eval "$1"; then ok; else bad "$2"; fi; }

HOME=$TMP/home
export HOME
mkdir -p "$HOME"

BRIDGE=$REPO/harnesses/fx/sync-skills.sh

# Fabricated plugin cache matching PLUGIN_SPEC's compound-engineering entry.
CACHE=$TMP/cache/every-marketplace/compound-engineering/1.0.0
mkdir -p "$CACHE/skills/ce-plan" "$CACHE/skills/ce-code-review" "$CACHE/skills/ce-test-xcode"
printf '# ce-plan\n' >"$CACHE/skills/ce-plan/SKILL.md"
printf '# ce-code-review\n' >"$CACHE/skills/ce-code-review/SKILL.md"
printf '# ce-test-xcode\n' >"$CACHE/skills/ce-test-xcode/SKILL.md"

PLUGINS_JSON=$TMP/installed_plugins.json
jq -n --arg p "$CACHE" \
  '{plugins:{"compound-engineering@every-marketplace":[{scope:"user",installPath:$p}]}}' \
  >"$PLUGINS_JSON"

export FX_SKILLS=$TMP/fx-skills
export CLAUDE_PLUGINS_JSON=$PLUGINS_JSON

# ── 1. clean install: bridged skills exist, skip list respected ──────────────
out=$(bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 0 ]'                                    "clean install exited $rc, not 0"
check '[ -f "$FX_SKILLS/ce-plan/SKILL.md" ]'               "ce-plan was not bridged"
check '[ -f "$FX_SKILLS/ce-plan/.fx-bridge-managed" ]'     "ce-plan lacks the ownership marker"
check '[ -f "$FX_SKILLS/ce-code-review/SKILL.md" ]'        "ce-code-review was not bridged"
check '[ ! -e "$FX_SKILLS/ce-test-xcode" ]'                "skip-listed ce-test-xcode was bridged anyway"

# ── 2. idempotent second run; check mode agrees ──────────────────────────────
bash "$BRIDGE" install >/dev/null 2>&1; rc=$?
check '[ "$rc" -eq 0 ]'                                    "second install exited $rc, not 0"
bash "$BRIDGE" check >/dev/null 2>&1; rc=$?
check '[ "$rc" -eq 0 ]'                                    "check reported drift ($rc) right after install"

# ── 3. collision refusal + no pruning while any copy fails ───────────────────
# An unmanaged dst must be refused (rc 1, content intact), and a stale managed
# orphan must SURVIVE that run — pruning against a partial sync is data loss.
mkdir -p "$FX_SKILLS/stale-skill"; printf 'stale\n' >"$FX_SKILLS/stale-skill/SKILL.md"
printf 'stale-skill\n' >"$FX_SKILLS/stale-skill/.fx-bridge-managed"
rm "$FX_SKILLS/ce-plan/.fx-bridge-managed"                 # make ce-plan look user-owned
printf 'USER-EDIT\n' >>"$FX_SKILLS/ce-plan/SKILL.md"
out=$(bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 1 ]'                                    "collision run exited $rc, not 1"
check 'grep -q USER-EDIT "$FX_SKILLS/ce-plan/SKILL.md"'    "unmanaged ce-plan was overwritten despite refusal"
check '[ -d "$FX_SKILLS/stale-skill" ]'                    "orphan was pruned during a partial (failing) sync"
check 'grep -q "orphan cleanup skipped" <<<"$out"' "no skipped-cleanup notice on partial sync"

# ── 4. PLANTED NEGATIVE: empty source view = no-op success, prunes nothing ───
# Old behavior returned 1 (aborting install.sh under set -e) — and an empty
# view must never be read as "every bridged skill is an orphan".
jq -n '{plugins:{}}' >"$TMP/empty_plugins.json"
out=$(CLAUDE_PLUGINS_JSON=$TMP/empty_plugins.json bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 0 ]'                                    "empty-manifest install exited $rc, not 0 (bricks set -e installers)"
check '[ -d "$FX_SKILLS/ce-code-review" ]'                 "empty view pruned a still-bridged skill"
check '[ -d "$FX_SKILLS/stale-skill" ]'                    "empty view pruned the managed orphan"
# Same guarantee for the mid-update shape: json entry present, cache gone.
jq -n --arg p "$TMP/vanished-cache" \
  '{plugins:{"compound-engineering@every-marketplace":[{scope:"user",installPath:$p}]}}' \
  >"$TMP/midupdate_plugins.json"
out=$(CLAUDE_PLUGINS_JSON=$TMP/midupdate_plugins.json bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 0 ]'                                    "mid-update install exited $rc, not 0"
check '[ -d "$FX_SKILLS/ce-code-review" ]'                 "mid-update view pruned a still-installed skill"
# Corrupted JSON is a FAULT (rc 1, surfaced via fxBridgeError), not a silent
# no-op — but it still must prune nothing.
printf 'not-json{' >"$TMP/corrupt_plugins.json"
out=$(CLAUDE_PLUGINS_JSON=$TMP/corrupt_plugins.json bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 1 ]'                                    "corrupt-JSON install exited $rc, not 1 (fault hidden)"
check '[ -d "$FX_SKILLS/ce-code-review" ]'                 "corrupt-JSON view pruned a still-bridged skill"
check 'grep -q "not valid JSON" <<<"$out"'        "corrupt-JSON fault was not named in output"

# ── 5. orphan cleanup on a fully-successful sync ─────────────────────────────
# Restore ce-plan to managed, then a clean run must prune the stale orphan and
# leave a user's unmanaged dir alone.
rm -rf "$FX_SKILLS/ce-plan"
mkdir -p "$FX_SKILLS/hand-made"; printf 'mine\n' >"$FX_SKILLS/hand-made/keep"
out=$(bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 0 ]'                                    "cleanup run exited $rc, not 0"
check '[ ! -e "$FX_SKILLS/stale-skill" ]'                  "stale managed orphan was not pruned on full success"
check '[ -d "$FX_SKILLS/hand-made" ]'                      "unmanaged user dir was pruned (must never happen)"
check '[ -f "$FX_SKILLS/ce-plan/.fx-bridge-managed" ]'     "ce-plan was not re-bridged as managed"

# ── 6. PLANTED NEGATIVE: crash between the swap renames is recoverable ───────
# Fabricate the exact post-crash state a kill between `mv dst old` and
# `mv staging dst` leaves: parked copy present, skill dir gone. With the old
# rm-then-mv swap there is no parked copy — the skill is simply vanished.
mv "$FX_SKILLS/ce-plan" "$FX_SKILLS/.ce-plan.old.CRASH1"
out=$(bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 0 ]'                                    "post-crash install exited $rc, not 0"
check '[ -f "$FX_SKILLS/ce-plan/SKILL.md" ]'               "crashed swap was not recovered — skill stayed vanished"
check '! ls -d "$FX_SKILLS"/.ce-plan.old.* 2>/dev/null'    "parked .old dir was left behind after recovery"
check 'grep -q "recovered ce-plan" <<<"$out"'     "recovery did not announce itself"

# ── 7. PLANTED NEGATIVE: staging dirs are bridge internals, never orphans ────
# A staging dir carries the ownership marker mid-flight; cleanup/check must
# skip dot-dirs entirely (reaping one mid-swap destroys a concurrent copy).
mkdir -p "$FX_SKILLS/.ce-zombie.staging.Xq3abc"            # 6-char suffix, like mktemp XXXXXX
printf 'ce-zombie\n' >"$FX_SKILLS/.ce-zombie.staging.Xq3abc/.fx-bridge-managed"
bash "$BRIDGE" check >/dev/null 2>&1; rc=$?
check '[ "$rc" -eq 0 ]'                                    "check flagged a staging dir as drift/orphan"
out=$(bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 0 ]'                                    "install with zombie staging exited $rc, not 0"
check '! ls -d "$FX_SKILLS"/.ce-zombie.staging.* 2>/dev/null' "dead staging dir was not garbage-collected by recovery"
check '! ls -d "$FX_SKILLS"/.*.staging.* 2>/dev/null'      "some staging leftover survived recovery"
check '[ -d "$FX_SKILLS/ce-plan" ] && [ -d "$FX_SKILLS/ce-code-review" ]' "real skills damaged during staging cleanup"

# ── 8. concurrent install is refused by the lock, not interleaved ────────────
# Hold the lock in this shell until the probe returns. A timed background
# holder can expire while the install is still doing its pre-lock checks
# (dotfiles#1641). Close fd 9 in the probe subshell so it cannot inherit our
# lock's open file description; the real installer must contend independently.
if { exec 9>>"$FX_SKILLS/.fx-bridge.lock"; } && flock -n 9; then
  ok  # The contention precondition is established before starting the probe.
  out=$(exec 9>&-; bash "$BRIDGE" install 2>&1); rc=$?
  exec 9>&-
  check '[ "$rc" -eq 0 ]'                                    "locked-out install exited $rc, not 0"
  check 'grep -q "another install is already running" <<<"$out"' "locked-out install did not announce the skip"
  check '[ -d "$FX_SKILLS/ce-plan" ]'                        "locked-out install still mutated the tree"
else
  exec 9>&-
  bad "could not acquire the fixture lock before the concurrent install probe"
fi

# ── 8b. PLANTED NEGATIVE: a killed install's orphans must NOT hold the lock ──
# flock lives on the open file description, so an orphaned rsync inheriting
# fd 9 keeps the lock past the parent's death — phantom-blocking every later
# install. copy_skill closes fd 9 inside the substitution subshell; revert
# that `exec 9>&-` and this case fails. A slowed rsync shim gives the kill a
# window; the assertion runs while the orphan is still alive.
REAL_RSYNC=$(command -v rsync)
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nsleep 3\nexec %s "$@"\n' "$REAL_RSYNC" >"$TMP/bin/rsync"
chmod +x "$TMP/bin/rsync"
rm -rf "$FX_SKILLS/ce-plan"                                # force a real copy so rsync runs
env PATH="$TMP/bin:$PATH" bash "$BRIDGE" install >/dev/null 2>&1 &
BPID=$!
for _ in $(seq 1 50); do                                   # wait until a stage is in flight
  ls -d "$FX_SKILLS"/.*.staging.* >/dev/null 2>&1 && break
  sleep 0.1
done
kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null
lock_free=1
for _ in $(seq 1 10); do                                   # lock must free promptly, orphan or not
  if flock -n "$FX_SKILLS/.fx-bridge.lock" -c true 2>/dev/null; then lock_free=0; break; fi
  sleep 0.1
done
check '[ "$lock_free" -eq 0 ]'                             "orphaned child still holds the install lock after parent death"
sleep 3.5                                                  # let the orphan shim finish before converging
out=$(bash "$BRIDGE" install 2>&1); rc=$?
check '[ "$rc" -eq 0 ]'                                    "post-kill converge install exited $rc, not 0"
check '[ -f "$FX_SKILLS/ce-plan/SKILL.md" ]'               "post-kill converge did not restore ce-plan"

# ── 9. sync.sh: settings seed + merge + credential-free push ─────────────────
# Run a COPY of fx/ so push's repo-write lands in scratch, never the worktree.
FXREPO=$TMP/fxrepo
mkdir -p "$FXREPO"
cp "$REPO/harnesses/fx/sync.sh" "$REPO/harnesses/fx/sync-skills.sh" "$REPO/harnesses/fx/settings.json" "$FXREPO/"
export FX_HOME=$TMP/fx-home
mkdir -p "$FX_HOME"
printf 'leaked\n' >"$FX_HOME/.settings.json.fx.STALE"      # from a "killed" prior merge
out=$(bash "$FXREPO/sync.sh" install 2>&1); rc=$?
check '[ "$rc" -eq 0 ]'                                    "sync.sh install exited $rc, not 0"
check 'cmp -s "$FX_HOME/settings.json" "$FXREPO/settings.json"' "settings.json was not seeded from the repo copy"
check '[ ! -e "$FX_HOME/.settings.json.fx.STALE" ]'        "stale merge temp file was not swept"
# Live file grows machine-local keys + drifted context_limits; install must
# converge ONLY context_limits, push must extract ONLY context_limits.
jq '.context_limits.skill_catalog_bytes = 1 | .apiKey = "SECRET-DO-NOT-TRACK"' \
  "$FX_HOME/settings.json" >"$FX_HOME/settings.json.tmp"
mv "$FX_HOME/settings.json.tmp" "$FX_HOME/settings.json"
bash "$FXREPO/sync.sh" install >/dev/null 2>&1
check '[ "$(jq -r .context_limits.skill_catalog_bytes "$FX_HOME/settings.json")" = "65536" ]' \
                                                           "drifted context_limits were not converged by install"
check '[ "$(jq -r .apiKey "$FX_HOME/settings.json")" = "SECRET-DO-NOT-TRACK" ]' \
                                                           "install clobbered machine-local keys"
bash "$FXREPO/sync.sh" push >/dev/null 2>&1; rc=$?
check '[ "$rc" -eq 0 ]'                                    "sync.sh push exited $rc, not 0"
check '! grep -q SECRET-DO-NOT-TRACK "$FXREPO/settings.json"' "push leaked a machine-local key into the repo copy"
check '[ "$(jq -r "keys|length" "$FXREPO/settings.json")" = "1" ]' \
                                                           "push wrote extra top-level keys"
check '[ "$(jq -r "keys[0]" "$FXREPO/settings.json")" = "context_limits" ]' \
                                                           "push wrote a key other than context_limits"

echo
echo "fx-bridge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
