#!/usr/bin/env bash
# shellcheck shell=bash
#
# overlay-units.sh — reads <overlay>/units, the private user units and drop-ins a host
# installs beside this repository's, one path<TAB>source[<TAB>on] row per line
# (systemd/README.md, "Units from the overlay", has the row rules).
#
# overlay_units_load [UNITS] fills four arrays. OVERLAY_UNIT_PATHS, OVERLAY_UNIT_SOURCES
# (a relative source resolved against the overlay's real directory) and
# OVERLAY_UNIT_FLAGS ("on" or empty) hold the accepted rows in file order;
# OVERLAY_UNIT_ERRORS holds one line per refused row, naming its line number. UNITS is
# sync.sh's own list: a row naming one of those paths is refused, a drop-in on one is
# not. No overlay, or no units file, leaves all four empty.
#
# Readers: sync.sh (install, refresh, check) and lib/foreign-units.sh (the register).

# shellcheck source=lib/overlay.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/overlay.sh"

overlay_units_load() {
  local units=${1:-} directory line content path source flag rest reason number=0
  local unit_pattern='[A-Za-z0-9@._-]+\.(service|timer|path|socket|target|mount|automount|swap|slice|scope|device)'
  local path_pattern
  local -A accepted=()
  OVERLAY_UNIT_PATHS=() OVERLAY_UNIT_SOURCES=() OVERLAY_UNIT_FLAGS=() OVERLAY_UNIT_ERRORS=()
  directory=$(overlay_dir) || return 0
  [ -f "$directory/units" ] || return 0
  directory=$(readlink -f -- "$directory") || return 0
  path_pattern="^${unit_pattern}(\.d/[A-Za-z0-9@._-]+\.conf)?$"
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    line=${line%$'\r'}
    content=${line#"${line%%[![:space:]]*}"}
    case $content in ''|'#'*) continue ;; esac
    reason='' flag=''
    path=${line%%$'\t'*}
    rest=${line#*$'\t'}
    source=${rest%%$'\t'*}
    if [[ "$line" != *$'\t'* ]] || [ -z "$source" ]; then
      reason='expected path<TAB>source[<TAB>on]'
    elif [[ ! "$path" =~ $path_pattern ]] || [[ "$path" == *..* ]]; then
      reason='invalid unit path'
    elif [[ "$rest" == *$'\t'* ]]; then
      flag=${rest#*$'\t'}
      if [ "$flag" != on ] || [[ "$path" != *.timer ]]; then
        reason='only a .timer may have the optional on field'
      elif [[ "$path" == *@.timer ]]; then
        reason='a template timer cannot take on: it has no instance to start'
      fi
    fi
    if [ -z "$reason" ]; then
      case " $units " in *" $path "*) reason='collision with hov-stack UNITS' ;; esac
      if [ -n "${accepted[$path]:-}" ]; then reason='duplicate unit path'; fi
      case $source in /*) ;; *) source=$directory/$source ;; esac
      if [ -z "$reason" ] && [ ! -f "$source" ]; then reason='source is not an existing regular file'; fi
    fi
    if [ -n "$reason" ]; then
      OVERLAY_UNIT_ERRORS+=("overlay units: line $number: $reason: $line")
      continue
    fi
    accepted[$path]=1
    OVERLAY_UNIT_PATHS+=("$path")
    OVERLAY_UNIT_SOURCES+=("$source")
    OVERLAY_UNIT_FLAGS+=("$flag")
  done < "$directory/units"
}
