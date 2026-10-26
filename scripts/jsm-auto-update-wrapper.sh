#!/usr/bin/env bash
set -uo pipefail

[ "$#" -eq 0 ] || {
  echo "usage: ${0##*/}" >&2
  exit 64
}

# Nightly skill updates, one skill at a time.
#
# This ran `jsm sync` then `jsm upgrade`, and failed 13 of the 14 nights to
# 2026-10-17 without updating anything. jsm (0.3.36) refuses to update a skill
# whose installed files differ from what it installed, and prints "Local edits
# ... Nothing was changed" under Failed:. Every skill with a
# skills-patches overlay differs on purpose, so each overlay skill with a
# pending update failed the run, and `sync` stopped on the same skills as
# conflicts before `upgrade` ever started. Twelve overlay skills sat 1 to 6
# versions behind; choose-the-best sat at v1 of v4 because Python had left
# __pycache__ in its scripts directory.
#
# Now: list the pending updates once, clear bytecode caches from those skills,
# upgrade each plain skill by name, and decide each overlay skill from jsm's
# own file diff (update_overlay_skill). `sync` is gone: it installs only skills
# saved to the cloud list and not yet on this machine, and the only one was
# ubs, retired here, which it reinstalled every night for skills-localize.sh
# to remove again. Run `jsm sync` by hand after saving a new skill elsewhere.

JSM_BIN=${JSM_BIN:-$HOME/.local/bin/jsm}
# The tracked overlay set. Resolve through the ~/.claude/scripts symlink the
# unit runs, as skills-localize.sh does; tests point it at a fixture.
SELF=$(readlink -f "${BASH_SOURCE[0]}")
PATCHES=${JSM_SKILLS_PATCHES:-$(cd -P "$(dirname "$SELF")/.." && pwd)/skills-patches}
# Without the overlay set every pending skill upgrades plainly, over any local
# patch, so a missing directory is reported rather than taken quietly (#42).
[ -d "$PATCHES" ] || echo "jsm-auto-update: warning: no overlay directory at $PATCHES; every pending skill upgrades plainly and loses any local patch (set JSM_SKILLS_PATCHES to the overlay set)" >&2
work=$(mktemp -d "${TMPDIR:-/tmp}/jsm-auto-update.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
# Every streamed jsm call is appended here for the failure summary's scan.
output_file=$work/output
: >"$output_file"

failure_summary() {
  local stage=$1 cause=$2 skills=""
  [[ ${INVOCATION_ID:-} =~ ^[a-f0-9]{32}$ ]] || return 0
  # A separate journal record survives ExecStopPost cleanup output. Only this
  # invocation, a fixed cause, and validated skill names cross the alert boundary.
  if [ "$cause" != output-unavailable ]; then
    skills=$(awk '
      /^[[:space:]]*Failed:[[:space:]]*$/ { failed=1; next }
      failed { sub(/^[[:space:]]*•[[:space:]]*/, "  ") }
      failed && /^[[:space:]]*[a-z0-9][a-z0-9-]* - User prompt error: IO error: not a terminal[[:space:]]*$/ {
        sub(/^[[:space:]]+/, ""); sub(/ - .*/, "")
        if (length($0) <= 64) print
        next
      }
      /^[^[:space:]]/ { failed=0 }
    ' "$output_file" | LC_ALL=C sort -u | awk 'NR <= 8' | paste -sd, -) || skills=""
    [ -z "$skills" ] || cause=manual-attention
  fi
  printf '%s\n' \
    'MESSAGE_ID=8e4f3a61b7c24df0a9d6502e1384c5ab' \
    "JSM_INVOCATION_ID=$INVOCATION_ID" "JSM_STAGE=$stage" \
    "JSM_CAUSE=$cause" "JSM_SKILLS=$skills" \
    'MESSAGE=JSM maintenance failed; manual review is required.' \
    | timeout --kill-after=1 2 logger --journald >/dev/null 2>&1 \
    || echo 'jsm-auto-update: failure summary could not be written to journal' >&2
}

# The first failure sets the exit status and the summary's cause. The other
# skills are still attempted, and one journal summary covers the invocation.
status=0
fail_cause=""
note_failure() {
  [ "$status" -eq 0 ] || return 0
  status=$1
  fail_cause=$2
}

run_jsm() {
  local rc=0 replay_rc=0 scan_rc=0
  local -a st

  # STREAM, do not capture-then-replay (dotfiles#1215).
  #
  # This used to redirect the stage to $output_file and `cat` it once the stage
  # had finished, which emitted every line in a single burst as the process was
  # exiting. journald resolves a stdout record's originating unit from the
  # sending process's cgroup at the moment it DRAINS the pipe; by then the
  # process was gone, so the records carried no _SYSTEMD_USER_UNIT at all and
  # `journalctl -u jsm-auto-update.service` could not match them. Measured on the
  # 2026-09-19 run: 0 matches for "already up to date" under -u, 89 in the same
  # window without it, while skills-localize.sh from the SAME run -- which
  # streams while alive -- kept its attribution.
  #
  # The cost was not cosmetic. The unit failed five nights running (Sep 15-19)
  # and the one command anyone would run to ask why showed a bare
  # "status=1/FAILURE" with the reason stripped out. tee still writes the file
  # (the Failed: scan below reads it) while emitting each line as it is produced.
  "$JSM_BIN" "$@" 2>&1 | tee "$work/call"
  st=("${PIPESTATUS[@]}")
  rc=${st[0]}
  replay_rc=${st[1]:-0}
  if [ -f "$work/call" ]; then cat "$work/call" >>"$output_file"; fi

  # Incomplete capture cannot support a cause claim. Keep JSM's real exit ahead
  # of tee's status when both failed.
  if [ "$replay_rc" -ne 0 ]; then
    if [ "$rc" -ne 0 ]; then note_failure "$rc" output-unavailable
    else note_failure "$replay_rc" output-unavailable; fi
    return
  fi
  if [ "$rc" -ne 0 ]; then
    note_failure "$rc" stage-failed
    return
  fi
  grep -Eq '^[[:space:]]*Failed:[[:space:]]*$' "$work/call" || scan_rc=$?
  case $scan_rc in
    0) note_failure 1 reported-failure ;;
    1) ;;
    *) note_failure "$scan_rc" output-unavailable ;;
  esac
}

# Python leaves __pycache__ beside a skill's scripts when they run, and jsm
# reads it as an unmanaged local path and refuses the update. It is rebuilt on
# the next run. Only the skills about to be updated are touched, in every tree
# jsm installs into.
clear_bytecode() {
  local tree
  for tree in "${trees[@]}"; do
    [ -d "$tree/$1" ] || continue
    find "$tree/$1" -type d -name __pycache__ -prune -exec rm -rf -- {} +
  done
}

# An overlay skill carries our copies of some of its files, so jsm refuses to
# update it. Reinstall it over them only when the update leaves every overlaid
# file alone; skills-localize.sh (ExecStopPost) then puts the overlay back.
# When the update changes a file we overlay, putting our copy back would throw
# that change away, so the skill is held, not failed. Rebasing the overlay
# does not release it: jsm still lists the same changed files, so once the
# rebase lands the version it was rebased onto is installed by hand, as the
# held line says. On 2026-10-17 that was 10 of the 12 overlay skills with a
# pending update.
update_overlay_skill() {
  local name=$1 rc=0 touched versions to
  "$JSM_BIN" diff "$name" --json >"$work/diff.json" || rc=$?
  if [ "$rc" -ne 0 ]; then
    note_failure "$rc" stage-failed
    return
  fi
  # Anything but three arrays of path strings could hide an overlaid file and
  # force-install over it, so an unexpected shape fails instead.
  if ! jq -r '[.added, .removed, .modified]
      | if all(type == "array") and (map(.[]) | all(type == "string"))
        then .[][] else error("unexpected jsm diff shape") end' "$work/diff.json" \
      | LC_ALL=C sort -u >"$work/changed"; then
    note_failure 1 output-unavailable
    return
  fi
  (cd "$PATCHES/$name" && find . -type f -printf '%P\n') | LC_ALL=C sort -u >"$work/ours"
  touched=$(LC_ALL=C comm -12 "$work/changed" "$work/ours" | paste -sd' ' -)
  if [ -z "$touched" ]; then
    run_jsm install "$name" --force
    return
  fi
  versions=$(jq -r '"v\(.from_version) to v\(.to_version)"' "$work/diff.json")
  to=$(jq -r '.to_version' "$work/diff.json")
  echo "jsm-auto-update: held $name ($versions): the update changes $touched, which skills-patches/$name replaces; rebase the overlay onto v$to, merge it, then run jsm install $name --version $to --force and skills-localize.sh apply (the rebase alone never releases the hold), or retire the skill"
}

rc=0
"$JSM_BIN" upgrade --list --json >"$work/list.json" || rc=$?
if [ "$rc" -ne 0 ]; then
  failure_summary list stage-failed
  exit "$rc"
fi
if ! jq -e '.updates | type == "array"' "$work/list.json" >/dev/null; then
  failure_summary list output-unavailable
  exit 1
fi
pending=()
while IFS= read -r name; do
  # The name becomes a jsm argument and a path segment, so it must be a plain
  # skill name. Anything else is reported without echoing it.
  if [[ $name =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    pending+=("$name")
  else
    echo "jsm-auto-update: an update whose name is not a plain skill name was skipped" >&2
    note_failure 1 reported-failure
  fi
done < <(jq -r '.updates[] | select(.update_available == true and .pinned != true) | .name | strings' "$work/list.json")

# Every pinned skill is named every night, so a pin stays visible in the
# journal instead of silently freezing the skill. jsm caps a pinned skill's
# latest_version at the pin, so the list cannot say whether upstream moved on.
pinned=()
while IFS= read -r name; do
  if [[ $name =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then pinned+=("$name"); fi
done < <(jq -r '.updates[] | select(.pinned == true) | .name | strings' "$work/list.json")
if [ "${#pinned[@]}" -gt 0 ]; then
  echo "jsm-auto-update: pinned, not updated: ${pinned[*]} (unpin to update)"
fi

if [ "${#pending[@]}" -eq 0 ]; then
  echo "jsm-auto-update: no skill updates to apply"
else
  echo "jsm-auto-update: ${#pending[@]} skill update(s) available: ${pending[*]}"
  trees=()
  while IFS= read -r tree; do trees+=("$tree"); done < <(
    "$JSM_BIN" config show --json \
      | jq -r '.values.skills // {} | to_entries[] | select(.key | endswith("_dir")) | .value | strings | select(startswith("/"))')
  for name in "${pending[@]}"; do
    clear_bytecode "$name"
    if [ -d "$PATCHES/$name" ]; then
      update_overlay_skill "$name"
    else
      run_jsm upgrade "$name"
    fi
  done
fi

[ "$status" -eq 0 ] || failure_summary upgrade "$fail_cause"
exit "$status"
