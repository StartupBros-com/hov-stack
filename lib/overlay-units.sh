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
# not. A row naming a path another installer owns (overlay_units_reserved) is refused
# the same way. No overlay, or no units file, leaves all four empty.
#
# Readers: sync.sh (install, refresh, check) and lib/foreign-units.sh (the register).

# shellcheck source=lib/overlay.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/overlay.sh"
# shellcheck source=lib/hygiene-posture.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/hygiene-posture.sh"

# overlay_units_reserved: the unit-directory paths that installers other than UNITS own,
# one path<TAB>owner line each. lib/manifest.sh links some units into the unit directory
# as symlinks into this repository, so a copy over one would write through the link into
# the tracked file. sync.sh writes and deletes the hygiene-posture drop-ins itself. Fails
# when lib/manifest.sh cannot be read.
overlay_units_reserved() {
  local lib stem kind
  lib=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
  [ -r "$lib/manifest.sh" ] || return 1
  (
    # The manifest's arrays stay in this subshell, out of the caller's namespace.
    # shellcheck source=lib/manifest.sh
    . "$lib/manifest.sh" || exit 1
    for entry in "${DOTFILES_LINKS[@]}" "${DOTFILES_COPIES[@]}"; do
      destination=${entry#*|}
      case $destination in
        .config/systemd/user/?*) printf '%s\tlib/manifest.sh\n' "${destination#.config/systemd/user/}" ;;
      esac
    done
  ) || return 1
  for stem in $HYGIENE_POSTURE_STEMS; do
    for kind in service timer; do
      printf '%s\tthe hygiene posture\n' "$stem.$kind.d/$HYGIENE_POSTURE_DROPIN"
    done
  done
}

overlay_units_load() {
  local units=${1:-} directory line content path source flag rest reason number=0
  local unit_pattern='[A-Za-z0-9@._-]+\.(service|timer|path|socket|target|mount|automount|swap|slice|scope|device)'
  local path_pattern reserved_rows reserved_path owner
  local -A accepted=() reserved=()
  OVERLAY_UNIT_PATHS=() OVERLAY_UNIT_SOURCES=() OVERLAY_UNIT_FLAGS=() OVERLAY_UNIT_ERRORS=()
  directory=$(overlay_dir) || return 0
  [ -f "$directory/units" ] || return 0
  directory=$(readlink -f -- "$directory") || return 0
  if ! reserved_rows=$(overlay_units_reserved); then
    OVERLAY_UNIT_ERRORS+=("overlay units: cannot read lib/manifest.sh, so no row can be checked against the unit paths it owns; every row refused")
    return 0
  fi
  while IFS=$'\t' read -r reserved_path owner; do
    [ -z "$reserved_path" ] || reserved[$reserved_path]=$owner
  done <<<"$reserved_rows"
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
      for reserved_path in "${!reserved[@]}"; do
        case $path in
          "$reserved_path"|"$reserved_path"/*) reason="collision with a path ${reserved[$reserved_path]} owns" ;;
        esac
      done
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
