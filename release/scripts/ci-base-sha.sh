#!/usr/bin/env bash
# Prints `base=<commit>`: the commit a CI run measures its changes from.
#
#   pull_request  The first parent of the test merge GitHub built (HEAD_SHA): the base branch
#                 as it stood when the run started. The event's own pull_request.base.sha is
#                 the base as of the pull request's last push, so once the base branch moves it
#                 counts that branch's later commits as the pull request's.
#   merge_group   The merge group's parent commit.
#   push          The commit the branch pointed at before the push.
#
# An empty base is not an error: ci-changed-plugins.sh then selects every plugin, and the
# warning here says why. Any other event fails, so a new trigger gets a base on purpose.
set -euo pipefail

event="${EVENT_NAME:-}"; head="${HEAD_SHA:-}"
case "$event" in
  pull_request)
    if [ -n "$head" ] && git rev-parse --verify --quiet "$head^2^{commit}" >/dev/null 2>&1; then
      base="$(git rev-parse --verify "$head^1^{commit}")"
    else
      printf '::warning::%s is not a merge commit in this checkout; using the base the pull request event names\n' "${head:-HEAD_SHA}" >&2
      base="${PR_BASE_SHA:-}"
    fi ;;
  merge_group) base="${MERGE_GROUP_BASE_SHA:-}" ;;
  push) base="${PUSH_BEFORE_SHA:-}" ;;
  *) printf '::error::no base commit is defined for the %s event\n' "${event:-<unset>}" >&2; exit 1 ;;
esac
# The value becomes a line of GITHUB_OUTPUT: anything but a commit id could add a line to it.
if [ -n "$base" ] && ! [[ "$base" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
  printf '::error::the %s base is not a commit id\n' "$event" >&2; exit 1
fi
[ -n "$base" ] || printf '::warning::this %s run has no base commit; every plugin is selected\n' "$event" >&2
printf 'base=%s\n' "$base"
