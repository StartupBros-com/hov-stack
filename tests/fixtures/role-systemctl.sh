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
  is-enabled)
    unit_operands "$@"
    # Real is-enabled exits 0 for static, indirect and the like, not only for enabled:
    # a timer's static service "is enabled" by its status.
    if [ -f "$HOME/unit-state/${operands[0]}" ]; then
      state=$(sed -n 's/^UnitFileState=//p' "$HOME/unit-state/${operands[0]}")
      echo "$state"
      case $state in enabled|enabled-runtime|static|indirect|alias|generated|transient) exit 0 ;; *) exit 1 ;; esac
    fi
    [ -f "$HOME/enabled/${operands[0]}" ] ;;
  is-active) echo inactive; exit 3 ;;
  show)
    # The unit-state query sync.sh's removal of unlisted overlay units makes: a unit's
    # planted $HOME/unit-state/<unit> answers it, else enabled or disabled from the
    # enable record, inactive, triggered and wanted by nothing.
    case " $* " in
      *" -p UnitFileState "*)
        unit=${!#}
        # Real show refuses a template name (exit 1) and answers an unknown unit with an
        # empty UnitFileState=.
        case $unit in
          *@.*) echo "Failed to get properties: Unit name $unit is neither a valid invocation ID nor unit name." >&2; exit 1 ;;
        esac
        if [ -f "$HOME/unit-state/$unit" ]; then
          cat "$HOME/unit-state/$unit"
        else
          state=disabled
          [ ! -f "$HOME/enabled/$unit" ] || state=enabled
          printf 'UnitFileState=%s\nActiveState=inactive\nTriggeredBy=\n' "$state"
        fi ;;
      *) echo inactive ;;
    esac ;;
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
