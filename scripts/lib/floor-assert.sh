#!/usr/bin/env bash
# floor-assert.sh: sourced-only helper shared by checkers that report "clean".
# Not executable on its own. Bash side of the invariant; the python side is
# scripts/lib/floor_assert.py.
#
# THE INVARIANT
#   A checker must not report clean having examined zero items of the kind it
#   exists to examine. "I found nothing wrong" and "I looked at nothing" are
#   different answers, and every checker in this harness that conflated them
#   reported the second as the first.
#
# Why a shared function rather than an inline `[ "$n" -gt 0 ]` per site: this
# bug has been "fixed" twice in harness-doctor.sh (see its comments around the
# test-suite section), both times by adding a new discovery glob and never a
# floor. A new section copy-pasted from an existing one now inherits a floor
# call instead of a bare ok.
#
# floor <count> <min> <label>
#   0 when count >= min. Otherwise prints a WARN line and returns 1; the caller
#   decides whether that is fatal. WARN goes to stdout because that is where
#   this harness's report scrapers and the surrounding scripts already put it.
#   A non-numeric or empty count is treated as 0 — an unset variable is exactly
#   the silent-degradation case this exists to catch, so it must not pass.
floor() {
  local count="${1:-}" min="${2:-1}" label="${3:-check}"
  case "$count" in
    ''|*[!0-9]*) count=0 ;;
  esac
  case "$min" in
    ''|*[!0-9]*) min=1 ;;
  esac
  if [ "$count" -lt "$min" ]; then
    echo "WARN $label: examined $count item(s), expected at least $min — refusing to report clean"
    return 1
  fi
  return 0
}
