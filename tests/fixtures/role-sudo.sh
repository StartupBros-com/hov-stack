#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$HOME/sudo.log"
[ "${1:-}" != -n ] || shift
case "$1" in
  true) exit 0 ;;
  install)
    shift
    args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
    done
    exec /usr/bin/install "${args[@]}" ;;
  *) echo "unexpected sudo: $*" >&2; exit 98 ;;
esac
