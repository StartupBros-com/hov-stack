#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$HOME/systemctl.log"
[ "${1:-}" = --user ] || exit 98
shift
action=$1
shift
# Real systemctl reads an operand that starts with - as an option unless -- comes
# before it, and refuses the unknown option ("invalid option -- 'x'", exit 1).
unit_operands() {
  local arg terminated=''
  operands=()
  for arg in "$@"; do
    if [ -z "$terminated" ]; then
      case $arg in
        --) terminated=1; continue ;;
        --now) continue ;;
        -*) echo "systemctl: invalid option -- '${arg:1:1}'" >&2; exit 1 ;;
      esac
    fi
    operands+=("$arg")
  done
}
case "$action" in
  show-environment) exit "${MANAGER_EXIT:-0}" ;;
  daemon-reload) exit "${RELOAD_EXIT:-0}" ;;
  is-enabled) unit_operands "$@"; [ -f "$HOME/enabled/${operands[0]}" ] ;;
  is-active) echo inactive; exit 3 ;;
  show) echo inactive ;;
  enable)
    unit_operands "$@"
    mkdir -p "$HOME/enabled"
    for unit in "${operands[@]}"; do touch "$HOME/enabled/$unit"; done ;;
  disable)
    unit_operands "$@"
    for unit in "${operands[@]}"; do rm -f -- "$HOME/enabled/$unit"; done ;;
  stop) : ;;
  *) echo "unexpected systemctl: $action $*" >&2; exit 98 ;;
esac
