# shellcheck shell=bash
# Source only the production functions under test. Sourcing the whole script
# would attempt promotion; the caller supplies a fake binary and local say().
load_cass_smoke_functions() {
  local script=$1 extracted=$2 fn
  sed -n -e '/^smoke_fail() {/,/^}/p' \
         -e '/^candidate_smoke() {/,/^}/p' \
         -e '/^live_archive_advisory() {/,/^}/p' "$script" > "$extracted" || return 1
  # shellcheck source=/dev/null
  . "$extracted" || return 1
  for fn in smoke_fail candidate_smoke live_archive_advisory; do
    declare -F "$fn" >/dev/null || { echo "FAIL: could not extract $fn" >&2; return 1; }
  done
}
