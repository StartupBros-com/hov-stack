#!/usr/bin/env bash
# shellcheck shell=bash
#
# foreign-units.sh — the foreign-unit register: --user units another repository owns,
# which sync.sh's undeclared-unit check, scripts/unit-health.sh and
# scripts/harness-doctor.sh must not report as nobody's.
#
# It has two halves. sync.sh's UNITS_FOREIGN="..." line names the units of public
# repositories. A host's own units (a private repository's timers) are named in
# <overlay>/foreign-units instead, one per line, so the public tree never carries them;
# a # after optional leading whitespace starts a comment line. The overlay is
# $HOV_STACK_OVERLAY, else $XDG_CONFIG_HOME/hov-stack when that is absolute, else
# ~/.config/hov-stack, the resolution setup uses. A relative overlay is ignored.
#
# All three readers go through these functions, so the overlay half cannot be seen by
# one of them and missed by another.

# foreign_units_with_overlay LIST: print LIST with the overlay's unit names appended.
foreign_units_with_overlay() {
  local list=$1 xdg=${XDG_CONFIG_HOME:-} dir line content
  case $xdg in /*) ;; *) xdg=$HOME/.config ;; esac
  dir=${HOV_STACK_OVERLAY:-$xdg/hov-stack}
  case $dir in
    /*)
      if [ -f "$dir/foreign-units" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
          content=${line#"${line%%[![:space:]]*}"}
          case $content in
            ''|'#'*) continue ;;
          esac
          case $line in
            *[!A-Za-z0-9@._-]*) printf 'foreign-units: malformed unit name: %s\n' "$line" >&2 ;;
            *) list="$list $line" ;;
          esac
        done < "$dir/foreign-units"
      fi ;;
  esac
  printf '%s\n' "$list"
}

# foreign_units_register SYNC_SH: the static UNITS_FOREIGN line of SYNC_SH with the
# overlay's names appended. Prints nothing when that line is missing, so a reader that
# needs the register still fails closed on a sync.sh it cannot parse.
foreign_units_register() {
  local static
  [ -f "$1" ] || return 0
  static=$(sed -n 's/^UNITS_FOREIGN="\(.*\)"$/\1/p' "$1") || return 0
  [ -n "$static" ] || return 0
  foreign_units_with_overlay "$static"
}
