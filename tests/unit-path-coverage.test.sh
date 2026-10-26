#!/usr/bin/env bash
# Every directly executed managed-path service must declare a systemd PATH.
#
# systemd user services do not inherit the login shell PATH. That made
# dotup-refresh unable to resolve cosign and mise after install.sh gained its
# command -v preflight in #512: the checkout fast-forwarded, but install never
# re-applied the harness.
#
# Baseline exemptions are explicit below rather than silently omitted. They
# predate this policy and need a focused runtime-dependency audit before their
# PATH is changed; each says why it is exempt, so a new unit cannot inherit an
# accidental exception by name.
#
# Measured 2026-08-27: this discovery found 15 direct managed-path services.
# The planted negative was run with UNIT_PATH_COVERAGE_INVERT=1, which makes
# every PATH lookup fail: it produced 3/4 passed and 1 failed (the six covered
# units, including dotup-refresh.service, were reported as missing PATH).
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYSD=$REPO/systemd
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# The one exemption registry serves both skip_reason() and assertion 4 below;
# duplicating its unit names would make an unreachable exemption easy to miss.
# Each entry is `unit|reason` and has its explicit opt-out decision on record.
PATH_EXEMPTIONS=(
  # NO Environment=PATH ON PURPOSE. Backup dependency resolution is outside this outage fix.
  'backup-harness.service|backup runtime dependency audit is outside this outage fix'
  # NO Environment=PATH ON PURPOSE. The read-only watermark probe is outside this outage fix.
  'disk-watermark.service|watermark probe dependency audit is outside this outage fix'
  # docker-hygiene.service: EXEMPTION LIFTED 2026-10-04, audit done (issue #1555).
  # Under the stock systemd PATH the supabase CLI (~/.local/bin, or a mise
  # shim) resolves to nothing, so the unit's first STOP_ORPHANS stop attempts
  # (25 of them, 2026-09-30) were all exit 127 with stderr discarded, paged
  # only as Result=exit-code. docker, python3, ps, sed and awk all have
  # /usr/bin fallbacks; supabase does not. PATH added to docker-hygiene.service;
  # the script now preflights the binary, refuses stops and fails the run
  # under STRICT when it is missing, while reclaim keeps running.
  # NO Environment=PATH ON PURPOSE. Worktree-sweep dependency resolution is outside this outage fix.
  'wt-sweep.service|worktree-sweep dependency audit is outside this outage fix'
)

skip_reason() {
  local exemption unit reason
  for exemption in "${PATH_EXEMPTIONS[@]}"; do
    unit=${exemption%%|*}
    reason=${exemption#*|}
    if [ "$unit" = "$1" ]; then
      printf '%s\n' "$reason"
      return 0
    fi
  done
  return 1
}

# 1. Zero-run-green guard: the direct managed-path service corpus must exist.
units=()
for f in "$SYSD"/*.service; do
  [ -f "$f" ] || continue
  grep -qE '^ExecStart=%h/(dotfiles|\.claude|\.local)(/|[[:space:]]|$)' "$f" || continue
  units+=("$f")
done
[ "${#units[@]}" -ge 10 ] && ok || bad "expected >=10 direct managed-path services, found ${#units[@]}"

# 2. Every discovered service carries a PATH, or has an explicit recorded skip.
# UNIT_PATH_COVERAGE_INVERT is the planted-negative seam; never set it in CI.
missing=""
skipped=""
for f in "${units[@]}"; do
  b=$(basename "$f")
  if [ "${UNIT_PATH_COVERAGE_INVERT:-0}" != 1 ] && grep -q '^Environment=PATH=' "$f"; then
    continue
  fi
  if reason=$(skip_reason "$b"); then
    [ -n "$reason" ] && skipped="$skipped $b" && continue
    bad "recorded PATH skip has no reason: $b"
  fi
  missing="$missing $b"
done
[ -z "$missing" ] && ok || bad "managed-path service missing Environment=PATH:$missing"

# 3. A skip is not a mute button: every enumerated exception must state why.
# The registry's non-empty reasons are paired with the literal
# NO Environment=PATH ON PURPOSE comments above.
thin=""
for exemption in "${PATH_EXEMPTIONS[@]}"; do
  b=${exemption%%|*}
  reason=${exemption#*|}
  [ "$b" != "$reason" ] && [ -n "$reason" ] || thin="$thin $b"
done
[ -z "$thin" ] && ok || bad "PATH skip without a stated reason:$thin"

# 4. Every exemption must be reachable: it must name a discovered service that
# lacks PATH today. Otherwise a formerly unnecessary exception could silently
# excuse a future PATH regression.
unreachable=""
for exemption in "${PATH_EXEMPTIONS[@]}"; do
  b=${exemption%%|*}
  f=$SYSD/$b
  if [ ! -f "$f" ]; then
    unreachable="$unreachable $b(missing)"
  elif ! grep -qE '^ExecStart=%h/(dotfiles|\.claude|\.local)(/|[[:space:]]|$)' "$f"; then
    unreachable="$unreachable $b(not-discovered)"
  elif grep -q '^Environment=PATH=' "$f"; then
    unreachable="$unreachable $b(already-has-PATH)"
  fi
done
[ -z "$unreachable" ] && ok || bad "unreachable PATH exemption:$unreachable"

# 5. Portability: no Environment=PATH line may hardcode a home directory.
# %h expands correctly inside Environment=PATH= for user units (probed on workstation
# 2026-08-28: the %h-sourced units show the identical expanded string the
# hardcoded form produced). A hardcoded /home/<user> is invisible on the box
# it was written on and silently breaks PATH on every other host (#543).
# Scope: systemd/ user units only, every file including drop-ins.
# System units (systemd-system/) run as root, where %h is /root --
# see zram-swap.service -- so they are exempt by directory, not by name.
# The anchor accepts every directive spelling systemd does: optional leading
# whitespace, whitespace around '=', and single- or double-quoted assignments
# (all verified accepted by systemd-analyze; the 2026-08-28 inward vet showed
# an exact ^Environment=PATH= anchor let a quoted /home/probe line pass).
# Measured 2026-08-28: before the #543 conversion this assertion failed
# naming exactly the eight hardcoded units; planted /home/probe entries in
# plain, double-quoted, single-quoted, leading-space, and spaced-equals
# spellings each make it fail again.
path_lines=$(grep -rnE "^[[:space:]]*Environment[[:space:]]*=[[:space:]]*['\"]?PATH=" "$SYSD")
path_count=$(printf '%s\n' "$path_lines" | grep -c .)
# Strip the absolute $SYSD prefix BEFORE matching: the repo checkout itself
# lives under /home/<user>, so matching the raw grep -rn output would flag
# every line via its own filename (a self-poisoned probe, measured 2026-08-28:
# it named all ten files including the two already-%h units).
hardcoded=$(printf '%s\n' "$path_lines" | sed "s|^$SYSD/||" | grep -F '/home/' | cut -d: -f1-2 | tr '\n' ' ')
[ "$path_count" -ge 8 ] && ok || bad "expected >=8 Environment=PATH lines, found $path_count"
[ -z "${hardcoded% }" ] && ok || bad "Environment=PATH hardcodes a home directory: $hardcoded"

echo "unit-path-coverage: $pass/$((pass + fail)) assertions passed; skipped:${skipped:- none}"
[ "$fail" -eq 0 ]
