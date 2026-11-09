#!/usr/bin/env bash
set -euo pipefail

# Print the conventional subject for the pins refresh's commit and PR from the plan file
# release-pins.sh refresh writes: one tab-separated line per program, "tool from to
# platforms". A line whose from and to match only gains platform rows; any other line
# moves the program to a newer release. The subject says only what the plan holds.
#
# Usage: pins-pr-title.sh PLAN_FILE
# Exit:  0 subject printed; 1 plan missing or empty; 2 usage

[ "$#" -eq 1 ] || { echo 'usage: pins-pr-title.sh PLAN_FILE' >&2; exit 2; }
plan="$1"
[ -s "$plan" ] || { printf 'pins-pr-title: plan %s is missing or empty\n' "$plan" >&2; exit 1; }

moved=0
added=0
while IFS=$'\t' read -r tool from to _platforms; do
  [ -n "$tool" ] || continue
  if [ "$from" = "$to" ]; then added=1; else moved=1; fi
done < "$plan"

if [ "$moved" -eq 1 ] && [ "$added" -eq 1 ]; then
  echo 'chore(hov-setup): move install-release pins to current releases and add missing platform rows'
elif [ "$moved" -eq 1 ]; then
  echo 'chore(hov-setup): move install-release pins to current releases'
elif [ "$added" -eq 1 ]; then
  echo 'chore(hov-setup): add missing platform rows to install-release pins'
else
  printf 'pins-pr-title: plan %s has no program lines\n' "$plan" >&2
  exit 1
fi
