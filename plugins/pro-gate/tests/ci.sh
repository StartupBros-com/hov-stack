#!/usr/bin/env bash
# Plugin CI entry point (release/scripts/plugin-ci.sh runs this from the plugin root).
#
# Runs what the standalone repo's ci.yml and release.yml ran against the plugin's own code:
# source validation, a syntax pass over every shell file, then every tests/*.test.* suite.
# The suites took over 100 minutes back to back (the engine suite alone about 65, measured
# unsharded), past the 45-minute job limit, so they run as concurrent legs inside this one
# job on one runner: the engine suite as its three PG_TEST_SHARD shards plus balanced legs
# for the rest. The old repo spread the same legs over separate parallel runners.
#
# Dropped because they served the old repo's release train and workflow files, not this code:
# the customer-notes gate (plugin-ci.sh gates a VERSION bump on release notes), the
# require-trusted-ci / protected-branch / tag-identity gates, packaging, checksum verification
# and publishing (hov's release-stage, repin and publish chain does that; release/stage-assets.sh
# is its hook), the fork-PR manifest check, and the workflow-file shape checks.
#
# Needs on PATH: bash 4+, node (for `node --test`), python3, jq, yq, shellcheck, docker
# (scripts/validate-source.sh parses shell files under bash 3.2 in a pinned container).
set -euo pipefail
cd "$(dirname "$0")/.."

for tool in node python3 jq yq shellcheck docker; do
  command -v "$tool" >/dev/null 2>&1 || { echo "tests/ci.sh: missing required tool: $tool" >&2; exit 2; }
done

# One array per leg; the legs run at the same time. Longest-first so the slowest leg starts first.
leg_engine_1=("PG_TEST_SHARD=1 bash tests/engine.test.sh")
leg_engine_2=("PG_TEST_SHARD=2 bash tests/engine.test.sh")
leg_engine_3=("PG_TEST_SHARD=3 bash tests/engine.test.sh")
leg_daemon_a=(
  "bash tests/daemon-current-head-completion.test.sh"
  "node --test tests/cdp-salvage.test.mjs"
)
leg_daemon_b=(
  "bash tests/daemon-query-isolation.test.sh"
  "bash tests/daemon-reload.test.sh"
)
leg_review=(
  "bash tests/rejected-capture.test.sh"
  "bash tests/review-decision-adapters.test.sh"
  "bash tests/ci-assurance.test.sh"
  "bash tests/review-facts.test.sh"
)
leg_rest=(
  "bash tests/trusted-data.test.sh"
  "node --test tests/github-status.test.mjs"
  "node --test tests/github-base-fetch.test.mjs"
  "bash tests/memo-recovery.test.sh"
  "bash tests/round-continue.test.sh"
  "bash tests/delivery-disposition.test.sh"
  "bash tests/template-verdict.test.sh"
  "bash tests/autoupdate.test.sh"
  "bash tests/resolve-identity.test.sh"
  "bash tests/browser-launch.test.sh"
  "node --test tests/memo-recovery.test.mjs"
  "bash tests/distribution.test.sh"
  "bash tests/release-assets.test.sh"
)
leg_names=(engine_1 engine_2 engine_3 daemon_a daemon_b review rest)

# Replaces the old workflow's leg-coverage check: every tests/*.test.* file runs in exactly one
# leg, and a file declaring PG_TEST_SHARDS=N runs once per shard.
expected="$(
  for f in tests/*.test.sh; do
    shards="$(sed -n 's/^PG_TEST_SHARDS=\([1-9][0-9]*\)$/\1/p' "$f")"
    if [ -z "$shards" ]; then printf 'bash %s\n' "$f"; continue; fi
    for k in $(seq 1 "$shards"); do printf 'PG_TEST_SHARD=%s bash %s\n' "$k" "$f"; done
  done
  for f in tests/*.test.mjs; do printf 'node --test %s\n' "$f"; done
)"
invoked="$(for n in "${leg_names[@]}"; do declare -n leg="leg_$n"; printf '%s\n' "${leg[@]}"; unset -n leg; done)"
if [ "$(printf '%s\n' "$expected" | LC_ALL=C sort)" != "$(printf '%s\n' "$invoked" | LC_ALL=C sort)" ]; then
  echo 'tests/ci.sh: the legs do not run every test file exactly once' >&2
  diff <(printf '%s\n' "$expected" | LC_ALL=C sort) <(printf '%s\n' "$invoked" | LC_ALL=C sort) >&2 || true
  exit 1
fi

echo '== validate data and shell files =='
bash scripts/validate-source.sh

echo '== shell syntax =='
while IFS= read -r file; do bash -n "$file"; done < <(find . -type f -name '*.sh' -print)

logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT
run_leg() { # leg name; runs its suites in order, stops at the first failure
  local suite
  local -n suites="leg_$1"
  for suite in "${suites[@]}"; do
    echo "== $suite =="
    # shellcheck disable=SC2086 # each entry is a plain word list; `env` runs a leading VAR=value
    env $suite || { echo "FAILED: $suite"; return 1; }
  done
}
pids=()
for n in "${leg_names[@]}"; do
  ( run_leg "$n" ) > "$logs/$n.log" 2>&1 &
  pids+=("$!")
done
failed=0
for i in "${!leg_names[@]}"; do
  n="${leg_names[$i]}"
  if wait "${pids[$i]}"; then
    echo "ok - leg $n passed"
  else
    failed=1
    echo "::error::leg $n failed" >&2
    cat "$logs/$n.log" >&2
  fi
done
[ "$failed" = 0 ] || exit 1
echo 'ok - pro-gate suites passed'
