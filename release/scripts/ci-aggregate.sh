#!/usr/bin/env bash
set -euo pipefail

failed=0
if ! jobs="$(jq -r 'if type == "object" then to_entries[] | [.key, .value.result] | @tsv
    else error("expected needs object") end' <<<"${NEEDS_JSON:-}")" || [ -z "${NEEDS_JSON:-}" ]; then
  printf '::error::cannot read needed jobs from NEEDS_JSON\n' >&2; exit 1
fi
while IFS=$'\t' read -r job result; do
  [ -n "$job" ] || continue
  case "$result" in
    success|skipped) printf 'ok - job %s %s\n' "$job" "$result" ;;
    *) printf '::error::job %s concluded %s\n' "$job" "$result" >&2; failed=1 ;;
  esac
done <<<"$jobs"
if [ "${EVENT_NAME:-}" = pull_request ] && [ "${PLUGINS_TOUCHED:-}" = true ] \
   && { [ "${HEAD_REPO_IS_FORK:-}" = true ] || [ "${HEAD_REPO:-}" != "${REPO:-}" ]; }; then
  printf '::error::plugin checks do not run for pull requests from forks; a maintainer pushes the branch to this repository\n' >&2
  failed=1
# Anywhere else a skipped plugin job with plugins changed means the job's `if:` left this
# event out, and a green aggregate would then stand for checks that never ran.
elif [ "${PLUGINS_TOUCHED:-}" = true ] && [ "$(jq -r '.plugin.result // ""' <<<"$NEEDS_JSON")" = skipped ]; then
  printf '::error::plugins changed but the plugin job was skipped on this %s run; its checks did not run\n' "${EVENT_NAME:-<unset>}" >&2
  failed=1
fi
exit "$failed"
