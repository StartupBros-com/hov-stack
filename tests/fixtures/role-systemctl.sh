#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$HOME/systemctl.log"
[ "${1:-}" = --user ] || exit 98
shift
action=$1
shift
case "$action" in
  show-environment) exit "${MANAGER_EXIT:-0}" ;;
  daemon-reload) exit "${RELOAD_EXIT:-0}" ;;
  is-enabled) [ -f "$HOME/enabled/$1" ] ;;
  is-active) echo inactive; exit 3 ;;
  show) echo inactive ;;
  enable)
    [ "${1:-}" != --now ] || shift
    mkdir -p "$HOME/enabled"
    for unit in "$@"; do touch "$HOME/enabled/$unit"; done ;;
  disable)
    [ "${1:-}" != --now ] || shift
    for unit in "$@"; do rm -f -- "$HOME/enabled/$unit"; done ;;
  stop) : ;;
  *) echo "unexpected systemctl: $action $*" >&2; exit 98 ;;
esac
