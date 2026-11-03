#!/usr/bin/env bash
# shellcheck shell=bash
#
# overlay.sh — the private overlay, as a script that runs outside a session sees it.
#
# The overlay holds what this tree cannot carry (README.md, "The private overlay"). A
# session gets <overlay>/env through claude-env.sh, but a systemd unit runs without it,
# and `sync.sh install` copies this repository's unit files over the live ones, so a
# value edited into a unit file does not survive the next install. A scheduled script
# that needs a host value reads it here instead.

# overlay_dir: print the overlay directory: $HOV_STACK_OVERLAY, else
# $XDG_CONFIG_HOME/hov-stack when that is absolute, else ~/.config/hov-stack, the
# resolution setup uses. A relative overlay is ignored: prints nothing, returns 1.
overlay_dir() {
  local xdg=${XDG_CONFIG_HOME:-} dir
  case $xdg in /*) ;; *) xdg=$HOME/.config ;; esac
  dir=${HOV_STACK_OVERLAY:-$xdg/hov-stack}
  case $dir in
    /*) printf '%s\n' "$dir" ;;
    *) return 1 ;;
  esac
}

# overlay_env_get NAME: print the value <overlay>/env gives NAME, without a newline.
# The file is sourced in a subshell, the way scripts/discord-notify.sh reads
# ~/.secrets: nothing else it sets reaches the caller, and an error or exit in it ends
# only the subshell. NAME is unset there first, so an inherited value never answers
# for the file. Prints nothing when the overlay, the file or the value is missing.
# Returns 2 for a NAME that is not a shell variable name, else 0.
overlay_env_get() {
  local name=${1:-} dir
  case $name in
    '' | [0-9]* | *[!A-Za-z0-9_]*) return 2 ;;
  esac
  dir=$(overlay_dir) || return 0
  [ -f "$dir/env" ] || return 0
  (
    set +eu
    unset "$name"
    # shellcheck disable=SC1091 # the host's own file, never in this tree
    . "$dir/env" >/dev/null 2>&1 </dev/null
    printf '%s' "${!name:-}"
  ) || :
}
