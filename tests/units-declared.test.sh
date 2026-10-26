#!/usr/bin/env bash
# Every shipped unit file is declared, and every declared unit ships.
#
# Consumer: `sync.sh install`, which copies only the names in UNITS (user
# units, from systemd/) and SYSTEM_UNITS (root units, from
# systemd-system/). Defect class: a unit file in the tree that install
# never copies (it ships in the repo and never reaches a host), and the inverse,
# a declared name with no file behind it (install silently skips it).
# Deletion condition: when sync.sh enumerates the directories instead of
# carrying lists.
#
# Case 5 is the planted negative: a zz-probe.timer dropped into a scratch copy
# of the tree must be reported by the same comparison, so a blind comparison
# cannot pass.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# Words of a double-quoted, single-line assignment in sync.sh, e.g. UNITS="a b".
assigned() { sed -n "s/^$2=\"\\(.*\\)\"\$/\\1/p" "$1/sync.sh" | head -1; }

# The _enable list of one role branch (workstation|satellite).
role_enable() {
  sed -n "/$2)/,/;;/p" "$1/sync.sh" | grep -o '_enable="[^"]*"' | head -1 \
    | sed 's/^_enable="//; s/"$//'
}

# Files under a directory, relative to it, one per line.
tree_files() { [ -d "$1" ] && (cd "$1" && find . -type f | sed 's|^\./||' | sort); }

# compare ROOT: print one problem per line for the tree rooted at ROOT.
compare() {
  local root=$1 units sysunits crit ws sat name
  units=$(assigned "$root" UNITS)
  sysunits=$(assigned "$root" SYSTEM_UNITS)
  crit=$(assigned "$root" CRITICAL_SILENCE_TIMERS)
  ws=$(role_enable "$root" workstation)
  sat=$(role_enable "$root" satellite)

  # 1. Every UNITS name has a file.
  for name in $units; do
    [ -f "$root/systemd/$name" ] || echo "UNITS names $name but systemd/$name is absent"
  done
  # 2. Every SYSTEM_UNITS name has a file.
  for name in $sysunits; do
    [ -f "$root/systemd-system/$name" ] || echo "SYSTEM_UNITS names $name but systemd-system/$name is absent"
  done
  # 3. Every timer the install activates has a file.
  for name in $crit $ws $sat; do
    [ -f "$root/systemd/$name" ] || echo "activation list names $name but systemd/$name is absent"
  done
  # 4. Every shipped file is declared.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # The directory's README is documentation, not a unit; everything else must be declared.
    [ "$name" = README.md ] && continue
    case " $units " in *" $name "*) ;; *) echo "systemd/$name ships but is not in UNITS" ;; esac
  done < <(tree_files "$root/systemd")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case " $sysunits " in *" $name "*) ;; *) echo "systemd-system/$name ships but is not in SYSTEM_UNITS" ;; esac
  done < <(tree_files "$root/systemd-system")
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -qF "harnesses/pi/systemd/user/$name" "$root/lib/manifest.sh" 2>/dev/null \
      || echo "harnesses/pi/systemd/user/$name ships but lib/manifest.sh does not declare it"
  done < <(tree_files "$root/harnesses/pi/systemd/user")
}

# 0. Zero-run-green guard: the parse must yield real lists.
n_units=$(assigned "$REPO" UNITS | wc -w)
n_sys=$(assigned "$REPO" SYSTEM_UNITS | wc -w)
[ "$n_units" -ge 10 ] && [ "$n_sys" -ge 1 ] && ok \
  || bad "parsed $n_units UNITS and $n_sys SYSTEM_UNITS from sync.sh; expected >=10 and >=1"

# 1-4. The comparison against the real tree.
problems=$(compare "$REPO")
[ -z "$problems" ] && ok || bad "unit declaration mismatch:
$problems"

# 4b. The tunnel unit is declared by lib/manifest.sh instead of UNITS.
grep -qF 'harnesses/pi/systemd/user/pi-local-champion-tunnel.service' "$REPO/lib/manifest.sh" \
  && ok || bad "lib/manifest.sh does not declare harnesses/pi/systemd/user/pi-local-champion-tunnel.service"
[ -f "$REPO/harnesses/pi/systemd/user/pi-local-champion-tunnel.service" ] \
  && ok || bad "harnesses/pi/systemd/user/pi-local-champion-tunnel.service is absent"

# 5. Planted negative: an undeclared timer in a scratch copy must be reported.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/units-declared.XXXXXX") || { bad "no scratch dir"; SCRATCH=; }
if [ -n "$SCRATCH" ]; then
  trap 'rm -rf "$SCRATCH"' EXIT
  mkdir -p "$SCRATCH/lib" "$SCRATCH/harnesses/pi/systemd"
  cp "$REPO/sync.sh" "$SCRATCH/sync.sh"
  cp -R "$REPO/systemd" "$SCRATCH/systemd"
  cp -R "$REPO/systemd-system" "$SCRATCH/systemd-system"
  cp "$REPO/lib/manifest.sh" "$SCRATCH/lib/manifest.sh"
  [ -d "$REPO/harnesses/pi/systemd/user" ] && cp -R "$REPO/harnesses/pi/systemd/user" "$SCRATCH/harnesses/pi/systemd/user"
  : > "$SCRATCH/systemd/zz-probe.timer"
  probe=$(compare "$SCRATCH")
  case "$probe" in
    *"systemd/zz-probe.timer ships but is not in UNITS"*) ok ;;
    *) bad "planted zz-probe.timer was not reported (comparison is blind): [$probe]" ;;
  esac
  # And the declared-but-absent direction: drop a declared file.
  rm -f "$SCRATCH/systemd/skills-update.timer"
  probe=$(compare "$SCRATCH")
  case "$probe" in
    *"UNITS names skills-update.timer but systemd/skills-update.timer is absent"*) ok ;;
    *) bad "removed skills-update.timer was not reported (comparison is blind): [$probe]" ;;
  esac
fi

if [ "$fail" -eq 0 ]; then
  echo "ok — units declared: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — units declared: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
