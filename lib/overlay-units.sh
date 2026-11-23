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
# OVERLAY_UNITS_FILE is the units file it read, through the overlay's real directory,
# or empty when there is none.
#
# The install record (overlay_record_*) keeps one path<TAB>sha256<TAB>units-file row per
# overlay unit file sync.sh installed, in $CLAUDE_HOME/.hov-stack/overlay-units-installed.
# A row deleted from the units file leaves its record behind, which is how sync.sh finds
# the installed copy that nothing lists any more (#859).
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

# overlay_unit_path_valid PATH: true when PATH is a name a units row may install, a unit
# file or a <unit>.d/<file>.conf drop-in, with no "..".
overlay_unit_path_valid() {
  local unit_pattern='[A-Za-z0-9@._-]+\.(service|timer|path|socket|target|mount|automount|swap|slice|scope|device)'
  local path_pattern="^${unit_pattern}(\.d/[A-Za-z0-9@._-]+\.conf)?$"
  [[ "$1" =~ $path_pattern ]] && [[ "$1" != *..* ]]
}

overlay_units_load() {
  local units=${1:-} directory line content path source flag rest reason number=0
  local reserved_rows reserved_path owner
  local -A accepted=() reserved=()
  OVERLAY_UNIT_PATHS=() OVERLAY_UNIT_SOURCES=() OVERLAY_UNIT_FLAGS=() OVERLAY_UNIT_ERRORS=()
  OVERLAY_UNITS_FILE=
  directory=$(overlay_dir) || return 0
  [ -f "$directory/units" ] || return 0
  directory=$(readlink -f -- "$directory") || return 0
  OVERLAY_UNITS_FILE=$directory/units
  if ! reserved_rows=$(overlay_units_reserved); then
    OVERLAY_UNIT_ERRORS+=("overlay units: cannot read lib/manifest.sh, so no row can be checked against the unit paths it owns; every row refused")
    return 0
  fi
  while IFS=$'\t' read -r reserved_path owner; do
    [ -z "$reserved_path" ] || reserved[$reserved_path]=$owner
  done <<<"$reserved_rows"
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
    elif ! overlay_unit_path_valid "$path"; then
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

# overlay_record_file: where the install record lives.
overlay_record_file() {
  printf '%s\n' "${CLAUDE_HOME:-$HOME/.claude}/.hov-stack/overlay-units-installed"
}

# overlay_unit_sum FILE: FILE's sha256, the form the record keeps.
overlay_unit_sum() {
  local sum
  sum=$(sha256sum < "$1") || return 1
  printf '%s\n' "${sum%% *}"
}

# overlay_record_load: read the record into OVERLAY_RECORD_SUM and OVERLAY_RECORD_FROM,
# keyed by unit path. A row that is not three fields, or whose path a units row could not
# name, is dropped: forgetting a row can only leave a unit installed, never remove one.
overlay_record_load() {
  local file path sum from extra
  declare -gA OVERLAY_RECORD_SUM=() OVERLAY_RECORD_FROM=()
  OVERLAY_RECORD_DIRTY=0
  file=$(overlay_record_file)
  [ -f "$file" ] || return 0
  while IFS=$'\t' read -r path sum from extra || [ -n "$path" ]; do
    if [ -z "$sum" ] || [ -z "$from" ] || [ -n "$extra" ] || ! overlay_unit_path_valid "$path"; then
      OVERLAY_RECORD_DIRTY=1
      continue
    fi
    OVERLAY_RECORD_SUM[$path]=$sum
    OVERLAY_RECORD_FROM[$path]=$from
  done < "$file"
}

# overlay_record_set PATH SUM: record PATH as installed with SUM from the current units file.
overlay_record_set() {
  [ "${OVERLAY_RECORD_SUM[$1]:-}" = "$2" ] && [ "${OVERLAY_RECORD_FROM[$1]:-}" = "$OVERLAY_UNITS_FILE" ] && return 0
  OVERLAY_RECORD_SUM[$1]=$2
  OVERLAY_RECORD_FROM[$1]=$OVERLAY_UNITS_FILE
  OVERLAY_RECORD_DIRTY=1
}

# overlay_record_drop PATH: forget PATH.
overlay_record_drop() {
  [ -n "${OVERLAY_RECORD_SUM[$1]+set}" ] || return 0
  unset 'OVERLAY_RECORD_SUM[$1]' 'OVERLAY_RECORD_FROM[$1]'
  OVERLAY_RECORD_DIRTY=1
}

# overlay_record_save: write the record when it changed, through a temporary file renamed
# over the old one, so a reader never sees half of it.
overlay_record_save() {
  local file tmp path
  [ "${OVERLAY_RECORD_DIRTY:-0}" = 1 ] || return 0
  file=$(overlay_record_file)
  mkdir -p -- "$(dirname -- "$file")" || return 1
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if ! for path in "${!OVERLAY_RECORD_SUM[@]}"; do
      printf '%s\t%s\t%s\n' "$path" "${OVERLAY_RECORD_SUM[$path]}" "${OVERLAY_RECORD_FROM[$path]}"
    done | LC_ALL=C sort > "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  OVERLAY_RECORD_DIRTY=0
}
