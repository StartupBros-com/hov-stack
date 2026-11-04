#!/usr/bin/env bash
# shellcheck shell=bash
#
# hygiene-posture.sh — the host-declared posture of the four hygiene timers.
#
# The shipped units (systemd/wt-sweep.*, reclaim-sweep.*, docker-hygiene.*,
# pkg-cache-prune.*) are plan-only, and `sync.sh install` copies them over the live
# ones, so a host that runs one with deletion on lost that setting at the next install
# and kept a disabled timer. A host declares its posture in <overlay>/hygiene-posture
# instead, one setting per line; a # after optional leading whitespace starts a comment
# line and blank lines are skipped:
#
#   # <unit-stem> [<KEY>=<value>]
#   wt-sweep DRY_RUN=0
#   wt-sweep OnCalendar=daily
#   reclaim-sweep RECLAIM_SWEEP_APPLY=1
#   pkg-cache-prune
#
# A stem named on any line is DECLARED: install enables <stem>.timer. OnCalendar goes to
# a timer drop-in, every other key to a service drop-in as Environment=. Install writes
# the drop-ins as 50-hygiene-posture.conf, which sorts before a hand-written
# override.conf (`systemctl --user edit`), so a manual override still wins.
#
# The whole file is validated before anything is applied. An unknown stem or key (a
# typo such as DRYRUN) is an error, because a silently ignored key is the failure this
# file exists to remove. overlay_dir (lib/overlay.sh) finds the overlay. A relative
# overlay path is an error here, not "nothing declared": the posture is unknown, and an
# empty answer would let install remove the drop-ins the host did declare.

# Resolved through any symlink, so a fixture that links this file alone still finds
# its sibling.
# shellcheck source=lib/overlay.sh
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/overlay.sh"

# The drop-in file name, under <stem>.service.d/ and <stem>.timer.d/.
# shellcheck disable=SC2034 # read by sync.sh, which sources this file
HYGIENE_POSTURE_DROPIN=50-hygiene-posture.conf
# The stems a posture may name.
HYGIENE_POSTURE_STEMS="wt-sweep reclaim-sweep docker-hygiene pkg-cache-prune"

# hygiene_posture_file: print <overlay>/hygiene-posture; returns 1 without an overlay.
hygiene_posture_file() {
  local dir
  dir=$(overlay_dir) || return 1
  printf '%s/hygiene-posture\n' "$dir"
}

# hygiene_posture_keys STEM: the environment keys STEM accepts.
hygiene_posture_keys() {
  case $1 in
    wt-sweep) printf '%s\n' DRY_RUN PUSH ;;
    reclaim-sweep) printf '%s\n' RECLAIM_SWEEP_APPLY ;;
    docker-hygiene) printf '%s\n' DRY_RUN STOP_ORPHANS REAP_VOLUMES ;;
    pkg-cache-prune) printf '%s\n' DRY_RUN ;;
  esac
}

# hygiene_posture_load: validate <overlay>/hygiene-posture and print one row per setting,
# stem<TAB>key<TAB>value, a bare stem as stem<TAB><TAB>. A missing file prints nothing
# and returns 0. Every error prints "hygiene-posture: <reason>: <line>" on stderr and the
# result is 1 with no rows: a file is applied whole or not at all.
hygiene_posture_load() {
  local LC_ALL=C file line content stem rest key value bad=0 rows="" seen=$'\n' k allowed
  if ! file=$(hygiene_posture_file); then
    printf 'hygiene-posture: the overlay path is not absolute (HOV_STACK_OVERLAY or HOME), so the posture file cannot be read\n' >&2
    return 1
  fi
  [ -e "$file" ] || [ -L "$file" ] || return 0
  # Present but unreadable (or not a regular file) is invalid, never "nothing declared":
  # an empty answer would let install remove the drop-ins the host did declare.
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'hygiene-posture: cannot read the posture file: %s\n' "$file" >&2
    return 1
  fi
  # read drops NUL bytes without a word, so a file holding one would be parsed as some
  # other file. read -d '' succeeds only when it finds a NUL.
  if IFS= read -r -d '' _ <"$file"; then
    printf 'hygiene-posture: the posture file contains a NUL byte: %s\n' "$file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    content=${line#"${line%%[![:space:]]*}"}
    content=${content%"${content##*[![:space:]]}"}
    case $content in
      ''|'#'*) continue ;;
    esac
    stem=${content%%[[:space:]]*}
    rest=${content#"$stem"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    case " $HYGIENE_POSTURE_STEMS " in
      *" $stem "*) ;;
      *) printf 'hygiene-posture: unknown unit stem: %s\n' "$line" >&2; bad=1; continue ;;
    esac
    if [ -z "$rest" ]; then
      rows+="$stem"$'\t\t\n'
      continue
    fi
    case $rest in
      *=*) ;;
      *) printf 'hygiene-posture: expected KEY=value: %s\n' "$line" >&2; bad=1; continue ;;
    esac
    key=${rest%%=*}
    value=${rest#*=}
    if [ "$key" = OnCalendar ]; then
      case $value in
        '') printf 'hygiene-posture: empty OnCalendar: %s\n' "$line" >&2; bad=1; continue ;;
        *[!A-Za-z0-9*:/,.\ ~-]*)
          printf 'hygiene-posture: OnCalendar has a character outside [A-Za-z0-9*:/,. ~-]: %s\n' "$line" >&2
          bad=1; continue ;;
      esac
      if command -v systemd-analyze >/dev/null 2>&1 \
         && ! systemd-analyze calendar "$value" >/dev/null 2>&1; then
        printf 'hygiene-posture: OnCalendar is not a valid calendar expression: %s\n' "$line" >&2
        bad=1; continue
      fi
    else
      allowed=0
      while IFS= read -r k; do
        [ "$k" = "$key" ] && allowed=1
      done < <(hygiene_posture_keys "$stem")
      if [ "$allowed" = 0 ]; then
        printf 'hygiene-posture: unknown key for %s: %s\n' "$stem" "$line" >&2
        bad=1; continue
      fi
      case $value in
        0|1) ;;
        *) printf 'hygiene-posture: value must be 0 or 1: %s\n' "$line" >&2; bad=1; continue ;;
      esac
    fi
    case $seen in
      *$'\n'"$stem $key"$'\n'*)
        printf 'hygiene-posture: duplicate key for %s: %s\n' "$stem" "$line" >&2
        bad=1; continue ;;
    esac
    seen+="$stem $key"$'\n'
    rows+="$stem"$'\t'"$key"$'\t'"$value"$'\n'
  done < "$file"
  [ "$bad" = 0 ] || return 1
  printf '%s' "$rows"
}

# hygiene_posture_declared: print each declared stem once, in file order, from the rows
# in HYGIENE_POSTURE_ROWS (else from hygiene_posture_load).
hygiene_posture_declared() {
  local rows row stem seen=" "
  if [ -n "${HYGIENE_POSTURE_ROWS+x}" ]; then rows=$HYGIENE_POSTURE_ROWS
  else rows=$(hygiene_posture_load) || return 1; fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    stem=${row%%$'\t'*}
    case $seen in *" $stem "*) continue ;; esac
    seen+="$stem "
    printf '%s\n' "$stem"
  done <<< "$rows"
}

# hygiene_posture_render STEM service|timer: print the drop-in text for that stem and
# kind, or nothing when the kind has no settings. Settings in file order. Reads the rows
# in HYGIENE_POSTURE_ROWS when that is set (a caller that loaded them once), else loads.
hygiene_posture_render() {
  local stem=$1 kind=$2 rows row rest key value body="" header
  if [ -n "${HYGIENE_POSTURE_ROWS+x}" ]; then rows=$HYGIENE_POSTURE_ROWS
  else rows=$(hygiene_posture_load) || return 1; fi
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "${row%%$'\t'*}" = "$stem" ] || continue
    rest=${row#*$'\t'}
    key=${rest%%$'\t'*}
    value=${rest#*$'\t'}
    [ -n "$key" ] || continue
    case $kind:$key in
      timer:OnCalendar) body+="OnCalendar=$value"$'\n' ;;
      service:OnCalendar) ;;
      service:*) body+="Environment=$key=$value"$'\n' ;;
    esac
  done <<< "$rows"
  [ -n "$body" ] || return 0
  case $kind in
    timer) header="[Timer]"$'\n'"OnCalendar="$'\n' ;;
    service) header="[Service]"$'\n' ;;
    *) return 2 ;;
  esac
  printf '%s\n%s\n%s%s' \
    "# Written by sync.sh install from the overlay's hygiene-posture file." \
    "# Edit that file, not this one; install rewrites or removes this drop-in." \
    "$header" "$body"
}
