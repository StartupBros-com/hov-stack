#!/usr/bin/env bash
# .bashrc must export CASS_AUTO_REFRESH=0 to NON-interactive shells too, and only
# on a host with the cass-index timer installed (dotfiles#1235).
#
# WezTerm launches pi, codex and claude as `bash -lc 'exec ...'`: a login shell
# reads ~/.profile, which sources ~/.bashrc, and that stops at the
# non-interactive guard. An export placed below the guard never reaches those
# agents, and their tool shells inherit only their own process env. So the
# effect is asserted in a non-interactive shell, and the guard is proven to
# have fired by an interactive-only function (mkcd) being absent there. The
# ~/.profile hop is host-local (not a linked dotfile), so it is not exercised.
#
# The value is read with printenv, a child process, so an assignment that lost
# its `export` fails here the same way it would fail the exec'd agent.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASHRC=$REPO/.bashrc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# A workstation HOME has the installed timer unit; a satellite HOME does not.
WS=$TMP/ws SAT=$TMP/sat
mkdir -p "$WS/.config/systemd/user" "$SAT"
: >"$WS/.config/systemd/user/cass-index.timer"

probe='printf "%s %s\n" "$(printenv CASS_AUTO_REFRESH || echo unset)" "$(type -t mkcd || echo none)"'

# Non-interactive, the way `bash -lc` reaches it. `env -i` keeps a caller's own
# CASS_AUTO_REFRESH (a Claude session exports it) from satisfying the check.
noninteractive() {
  env -i HOME="$1" PATH=/usr/bin:/bin \
    bash --noprofile --norc -c 'source "$1"; eval "$2"' _ "$BASHRC" "$probe" 2>"$1.ni.err"
}

ws_ni=$(noninteractive "$WS")
case "$ws_ni" in
  *" none") ok ;;
  *) bad "non-interactive source ran past the guard (mkcd defined), so this case proves nothing: '$ws_ni' stderr: $(cat "$WS.ni.err")" ;;
esac
case "$ws_ni" in
  "0 "*) ok ;;
  *) bad "non-interactive shell exported CASS_AUTO_REFRESH='${ws_ni%% *}', expected 0; the export must sit above the guard. stderr: $(cat "$WS.ni.err")" ;;
esac

# Interactive: the whole file runs, and the export still holds at the end.
ws_i=$(env -i HOME="$WS" PATH=/usr/bin:/bin TERM=dumb \
  bash --noprofile --rcfile "$BASHRC" -ic "$probe" 2>"$WS.i.err" </dev/null)
ws_i=${ws_i##*$'\n'}
case "$ws_i" in
  "0 function") ok ;;
  *) bad "interactive shell reported '$ws_i', expected '0 function'. stderr: $(cat "$WS.i.err")" ;;
esac

# Without the timer, cass's on-read refresh is the only indexer, so the knob
# must stay off. The guard precondition is the same as above.
sat_ni=$(noninteractive "$SAT")
case "$sat_ni" in
  "unset none") ok ;;
  *) bad "host without cass-index.timer reported '$sat_ni', expected 'unset none'. stderr: $(cat "$SAT.ni.err")" ;;
esac

if [ "$fail" -eq 0 ]; then
  printf 'ok — bashrc cass guard: %s/%s assertions passed\n' "$pass" "$((pass + fail))"
else
  printf 'FAIL — bashrc cass guard: %s of %s assertions failed\n' "$fail" "$((pass + fail))" >&2
  exit 1
fi
