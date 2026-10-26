#!/usr/bin/env bash
# check()'s live-but-undeclared --user unit detection, driven END-TO-END.
#
# The forward check ("every declared unit is installed") already existed. This
# covers its INVERSE, which did not: every live unit must be declared. Measured
# 2026-08-27 on workstation — 29 enabled --user timers against 18 declared; 13 would have
# vanished on a rebuild.
#
# WHY THIS SUITE WAS REWRITTEN. Its first version reimplemented the classifier as
# a local verdict() helper and asserted against the copy. It therefore could not
# catch either defect a reviewer found in the real one: the query enumerated
# --type=timer only while the comment claimed every live unit (hiding enabled
# SERVICES), and the query's exit status was never tested, so a dead user bus
# produced zero rows, raised no DRIFT, and let check() print "in sync". A test
# that reimplements the thing under test can only prove the reimplementation.
#
# Every case below runs the real sync.sh check with a fake systemctl on
# PATH, and asserts on its actual output.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SYNC=$REPO/sync.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

# fake_systemctl <rows-file> <exit-code> [fragment-map-file]
#   rows-file      : "unit.timer enabled enabled" lines for list-unit-files
#   fragment-map   : "unit<TAB>fragmentpath" lines for show -p FragmentPath
mk_systemctl() {
  local dir=$1 rows=$2 rc=$3 frags=$4
  mkdir -p "$dir"
  cat > "$dir/systemctl" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *list-unit-files*)
      [ "$rc" -ne 0 ] && exit $rc
      # Honour --type exactly as systemctl does. A permissive stub that returned
      # every row regardless made this suite blind to the very defect it exists
      # for: reverting the query to --type=timer still passed, because the fake
      # handed back service rows nobody asked for.
      want=""
      for a in "\$@"; do case "\$a" in --type=*) want="\$want \${a#--type=}" ;; esac; done
      while read -r u rest; do
          [ -n "\$u" ] || continue
          suf=\${u##*.}
          if [ -z "\$want" ]; then printf '%s %s\n' "\$u" "\$rest"; continue; fi
          case " \$want " in *" \$suf "*) printf '%s %s\n' "\$u" "\$rest" ;; esac
      done < "$rows" 2>/dev/null
      exit 0 ;;
  *"show -p FragmentPath"*)
      u=\${!#}
      awk -F'\t' -v u="\$u" '\$1==u {print \$2}' "$frags" 2>/dev/null
      exit 0 ;;
esac
exit 0
EOS
  chmod +x "$dir/systemctl"
}

# run_check <stubdir> [home] -> prints the DRIFT lines the detector emitted
#
# The optional HOME override exists because the detector only resolves symlinks
# for fragments under $HOME. Case 6 previously put its fixture in $TMP and
# therefore passed via the non-$HOME skip -- it would have passed with the
# readlink logic deleted, which is the definition of a vacuous case.
run_check() {
  local stub=$1 home=${2:-$HOME} role_file=${3:-}
  if [ -n "$role_file" ]; then
    HOME="$home" DOTFILES_ROLE_FILE="$role_file" PATH="$stub:$PATH" bash "$SYNC" check 2>&1 |
      grep -E 'enabled but nothing declares|could not enumerate|returned nothing|undeclared-unit check did NOT run|cannot classify enabled unit' || true
  else
    HOME="$home" PATH="$stub:$PATH" bash "$SYNC" check 2>&1 |
      grep -E 'enabled but nothing declares|could not enumerate|returned nothing|undeclared-unit check did NOT run|cannot classify enabled unit' || true
  fi
}

# ---------------------------------------------------------------- fixtures
D=$TMP/stub; R=$TMP/rows; F=$TMP/frags
: > "$F"

emit() { printf '%s\n' "$1" > "$R"; printf '%s\t%s\n' "${1%% *}" "$2" > "$F"; }

# 1. An undeclared TIMER under $HOME is reported.
emit "zz-probe.timer enabled enabled" "$HOME/.config/systemd/user/zz-probe.timer"
mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *zz-probe.timer*) ok ;; *) bad "undeclared timer not reported" ;; esac

# 2. An undeclared SERVICE is reported too. This is the defect the previous
#    suite structurally could not see: the query was --type=timer only.
emit "zz-probe.service enabled enabled" "$HOME/.config/systemd/user/zz-probe.service"
mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *zz-probe.service*) ok ;; *) bad "undeclared SERVICE not reported (timers-only regression)" ;; esac

# 3. A declared unit ($UNITS) is silent.
emit "dcg-auto-update.timer enabled enabled" "$HOME/.config/systemd/user/dcg-auto-update.timer"
mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *dcg-auto-update*) bad "declared unit was reported" ;; *) ok ;; esac

# 3a. An unknown host cannot escalate with DOTFILES_ROLE=workstation: check
#     must stay fail-closed when hosts.tsv has no row for this host.
unknown_roles=$TMP/unknown-hosts.tsv
printf '# no declared hosts\n' >"$unknown_roles"
unknown_out=$(HOME="$HOME" DOTFILES_ROLE=workstation DOTFILES_ROLE_FILE="$unknown_roles" \
  PATH="$D:$PATH" bash "$SYNC" check 2>&1 || true)
case "$unknown_out" in
  *"has no role in hosts.tsv"*) ok ;;
  *) bad "unknown host did not remain fail-closed" ;;
esac

# 4. Overlay and in-tree foreign unit stems are silent; an absent stem is reported.
OVERLAY=$TMP/overlay
mkdir -p "$OVERLAY"
export HOV_STACK_OVERLAY=$OVERLAY
printf '# externally managed\n\n   # indented comment\nacme-growth-backup\ninvalid/name\nacme-unlisted other\n' > "$OVERLAY/foreign-units"
emit "acme-growth-backup.timer enabled enabled" "$HOME/.config/systemd/user/acme-growth-backup.timer"
mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *acme-growth-backup*) bad "overlay foreign unit was reported" ;; *) ok ;; esac
out=$(PATH="$D:$PATH" bash "$SYNC" check 2>&1 || true)
case "$out" in *"foreign-units: malformed unit name: invalid/name"*) ok ;; *) bad "malformed name not reported" ;; esac
emit "check-fleet-drift.timer enabled enabled" "$HOME/.config/systemd/user/check-fleet-drift.timer"
mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *check-fleet-drift*) bad "in-tree foreign unit was reported" ;; *) ok ;; esac
emit "acme-unlisted.timer enabled enabled" "$HOME/.config/systemd/user/acme-unlisted.timer"
mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *acme-unlisted*) ok ;; *) bad "unit absent from both lists was not reported" ;; esac
# Missing files and relative overlays cannot suppress the inverse check.
rm "$OVERLAY/foreign-units"
emit "acme-growth-backup.timer enabled enabled" "$HOME/.config/systemd/user/acme-growth-backup.timer"
mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *acme-growth-backup*) ok ;; *) bad "missing overlay file suppressed unit" ;; esac
printf 'acme-growth-backup\n' > "$OVERLAY/foreign-units"
# The relative overlay must exist from where sync.sh runs, or ignoring it proves nothing.
mkdir -p "$TMP/rel-cwd/relative"
printf 'acme-growth-backup\n' > "$TMP/rel-cwd/relative/foreign-units"
case "$(cd "$TMP/rel-cwd" && HOV_STACK_OVERLAY=relative run_check "$D")" in *acme-growth-backup*) ok ;; *) bad "relative overlay suppressed unit" ;; esac
# Absolute XDG roots work, including a final line without a newline. Relative
# XDG roots fall back to HOME/.config, just as setup does.
mkdir -p "$TMP/xdg/hov-stack" "$TMP/overlay-home/.config/hov-stack"
printf '%s' acme-growth-backup > "$TMP/xdg/hov-stack/foreign-units"
printf '%s' acme-growth-backup > "$TMP/overlay-home/.config/hov-stack/foreign-units"
case "$(HOV_STACK_OVERLAY='' XDG_CONFIG_HOME="$TMP/xdg" run_check "$D")" in *acme-growth-backup*) bad "absolute XDG overlay was not read" ;; *) ok ;; esac
emit "acme-growth-backup.timer enabled enabled" "$TMP/overlay-home/.config/systemd/user/acme-growth-backup.timer"
mk_systemctl "$D" "$R" 0 "$F"
case "$(HOV_STACK_OVERLAY='' XDG_CONFIG_HOME=relative run_check "$D" "$TMP/overlay-home")" in *acme-growth-backup*) bad "relative XDG did not fall back to HOME" ;; *) ok ;; esac

# 5. A DISTRO unit is silent. launchpadlib-cache-clean ships in
#    /usr/lib/systemd/user from python3-launchpadlib; flagging the OS's own
#    units trains the reader to ignore this check.
emit "launchpadlib-cache-clean.timer enabled enabled" "/usr/lib/systemd/user/launchpadlib-cache-clean.timer"
mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *launchpadlib*) bad "distro unit under /usr/lib was reported" ;; *) ok ;; esac

# 6. A unit declared by lib/manifest.sh — a SYMLINK into this repo rather than a
#    $UNITS copy — is silent. pi-local-champion-tunnel.service is the live case;
#    reporting it would be crying wolf at a correctly-managed unit.
TH=$TMP/home; mkdir -p "$TH/.config/systemd/user"
if [ -e "$REPO/harnesses/pi/systemd/user/pi-local-champion-tunnel.service" ]; then
  ln -sfn "$REPO/harnesses/pi/systemd/user/pi-local-champion-tunnel.service" \
     "$TH/.config/systemd/user/pi-local-champion-tunnel.service"
  emit "pi-local-champion-tunnel.service enabled enabled" \
       "$TH/.config/systemd/user/pi-local-champion-tunnel.service"
  mk_systemctl "$D" "$R" 0 "$F"
  # HOME is the fixture home, so the fragment IS under $HOME and the readlink
  # branch runs for real. Deleting that branch now makes this case fail.
  case "$(run_check "$D" "$TH")" in
    *pi-local-champion*) bad "manifest-symlinked unit was reported" ;;
    *) ok ;;
  esac
else
  bad "fixture source missing: $REPO/systemd/user/pi-local-champion-tunnel.service"
fi

# 7. A FAILED enumeration must be DRIFT, not silence. Previously the status was
#    never tested, so a dead user manager let check() print "in sync" — the
#    zero-run-green shape, inside the check meant to catch silent gaps.
mk_systemctl "$D" "$R" 3 "$F"
case "$(run_check "$D")" in *"could not enumerate"*) ok ;; *) bad "failed enumeration did not raise DRIFT" ;; esac

# 8. Zero rows is also DRIFT: install() enables units, so an empty list means the
#    query did not work, not that the box is clean.
: > "$R"; mk_systemctl "$D" "$R" 0 "$F"
case "$(run_check "$D")" in *"returned nothing"*) ok ;; *) bad "empty enumeration did not raise DRIFT" ;; esac

# ------------------------------------------------- declaration-side invariants
# 9. Zero-run-green guard: the units this PR captured must actually BE declared.
missing=""
for u in backup-harness.timer wt-sweep.timer jsm-auto-update.timer; do
  grep -q "$u" "$SYNC" || missing="$missing $u"
done
[ -z "$missing" ] && ok || bad "captured units absent from UNITS:$missing"

# 10. A declared unit's ExecStart must resolve to something this repo ships.
#     Declaring the TIMER while the SCRIPT lives only on one machine restores a
#     schedule that immediately fails — #508's defect at the systemd layer.
orphan=""
for f in "$REPO"/systemd/*.service; do
  e=$(grep -oE '^ExecStart=.*' "$f" 2>/dev/null | head -1 | sed 's/^ExecStart=//' | awk '{print $1}')
  case "$e" in
    *%h/.local/bin/*)    b=${e##*/}; [ -e "$REPO/bin/$b" ]   || orphan="$orphan $(basename "$f")" ;;
    *%h/.pi/agent/bin/*) b=${e##*/}; [ -e "$REPO/pi/agent/bin/$b" ] || orphan="$orphan $(basename "$f")" ;;
  esac
done
[ -z "$orphan" ] && ok || bad "unit ExecStart not shipped by this repo:$orphan"

# 11. A unit whose FragmentPath cannot be read is a NAMED FAILURE, not a skip.
#     This was fail-open one layer below the enumeration: `systemctl show`
#     errors were suppressed, the empty result took the non-$HOME continue, and
#     the detector stayed green while unable to classify an enabled unit.
mkdir -p "$D"
cat > "$D/systemctl" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *list-unit-files*)        printf 'zz-opaque.service enabled enabled\n'; exit 0 ;;
  *"show -p FragmentPath"*) exit 9 ;;
esac
exit 0
EOS
chmod +x "$D/systemctl"
case "$(run_check "$D")" in
  *"cannot classify enabled unit"*) ok ;;
  *) bad "a unit whose FragmentPath could not be read was silently skipped" ;;
esac

# 12. NO systemd --user manager at all is NOT APPLICABLE, not drift — and the
#     skip must be PRINTED. CI containers have no user manager, so a fail-closed
#     enumeration reported drift on every run; a fail-closed check that fires
#     where it does not apply is one people mute. /run/systemd/system exists
#     exactly when systemd is PID 1.
mk_systemctl "$D" "$R" 3 "$F"
# The stub systemctl fails EVERY subcommand, including the reachability probe,
# which is what a container or a bus-less context actually looks like.
cat > "$D/systemctl" <<'EOS'
#!/usr/bin/env bash
exit 3
EOS
chmod +x "$D/systemctl"
out=$(PATH="$D:$PATH" bash "$SYNC" check 2>&1 || true)
case "$out" in
  *"not applicable"*) ok ;;
  *) bad "no-systemd host did not print a visible SKIP" ;;
esac
case "$out" in
  *"could not enumerate"*) bad "no-systemd host reported drift instead of not-applicable" ;;
  *) ok ;;
esac

# 13. But when the manager IS reachable and the enumeration fails, that is STILL
#     drift — otherwise case 12 would be satisfiable by deleting the check.
#     mk_systemctl answers `show` (so the probe succeeds) while failing
#     list-unit-files, which is exactly the broken-but-reachable shape.
mk_systemctl "$D" "$R" 3 "$F"
case "$(run_check "$D")" in
  *"could not enumerate"*) ok ;;
  *) bad "failed enumeration stopped being drift on a systemd host" ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "ok — undeclared-unit check: $pass/$((pass + fail)) assertions passed"
else
  echo "FAIL — undeclared-unit check: $fail of $((pass + fail)) assertions failed" >&2
  exit 1
fi
