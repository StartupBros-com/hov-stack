#!/usr/bin/env bash
# Hermetic tests for scripts/pipeline-mix-report.py (dotfiles#1045): the
# weekly read that says whether the review pipeline worked on the products or on
# itself, and what a gated issue cost in Pro rounds. Both feeds are stubbed
# through the script's env seams -- a PR fixture instead of the GitHub API, a
# ledger fixture instead of $PRO_GATE_HOME. No network, no gh, no ledger writes.
#
# Planted negatives, each false-passing against a report that counted rows
# without reading them:
#   G2 a window of product-only merges raises no self-referential flag
#   G4 a dead PR feed says so on its own line instead of reporting 0%
#   G5 harvest and recover rows are not charged rounds and never inflate a cost
#   G7 a fresh row that never reached the model is not a charged round
#   G8 ungated product merges never dilute the gated cohort's share
#   G9 a merge feed capped at the limit is partial, and a partial feed's share
#      is never compared against the threshold
#   G10 reservation redirects reusing one conversation's marker are one charge,
#       not four, and cannot drag an out-of-window charge into the window
#   G11 a ledger with unparseable or non-object rows is a PARTIAL feed, never
#       a confident zero
#   G12 a driver merged together with its OWN regression suite is still the
#       pipeline working on itself, and the surface is checked against the real
#       tests tree so the next suite added cannot fall off it silently
#   G13 only in-window gated merges get file-list reads; failed detail reads
#       leave the share partial instead of silently classifying them as product
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)  # repo root
SCRIPT="$HERE/scripts/pipeline-mix-report.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*" >&2; }

python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SCRIPT" \
  || { echo "FAIL: $SCRIPT does not parse" >&2; exit 1; }

# The window every case runs in: the audited weekend, pinned so the report is
# deterministic and the fixtures can sit at fixed timestamps.
export PIPELINE_MIX_NOW="2026-09-08T00:00:00+0000"
export PIPELINE_MIX_REPOS="StartupBros-com/hov-stack,acme-org/trading-app,StartupBros-com/pro-gate"

# A weekend-shaped fixture. The cohort is the GATED merges (issue #1045: "of the
# loop-run PRs merged in the window"), so provenance is part of every row:
#   dotfiles#1043, #1042  loop-only, gated by a pro-gate ledger round key
#   dotfiles#1034         loop-only, gated by the dispatcher's loop-run label
#                         and NO ledger row -- the arm the label exists to cover
#   dotfiles#1020         product docs merge, no gate provenance at all
#   trading-app#196/194 product merges the gate did handle
#   pro-gate#173          the runtime repo, self-referential by definition
cat > "$TMP/prs.json" <<'JSON'
{
  "StartupBros-com/hov-stack": [
    {"number": 1043, "mergedAt": "2026-09-07T12:18:22Z", "labels": [], "files": [{"path": "scripts/pro-gate-loop.sh"}, {"path": "tests/pro-gate-loop.test.sh"}]},
    {"number": 1042, "mergedAt": "2026-09-07T11:45:36Z", "labels": [], "files": [{"path": "scripts/pro-gate-loop.sh"}, {"path": "tests/pro-gate-loop.test.sh"}]},
    {"number": 1034, "mergedAt": "2026-09-06T17:29:42Z", "labels": [{"name": "loop-run"}], "files": [{"path": "scripts/pro-gate-loop.sh"}, {"path": "scripts/dispatcher-tick.sh"}]},
    {"number": 1020, "mergedAt": "2026-09-06T00:03:45Z", "labels": [], "files": [{"path": "docs/ideation/seo.md"}]}
  ],
  "acme-org/trading-app": [
    {"number": 196, "mergedAt": "2026-09-07T15:19:00Z", "labels": [], "files": [{"path": "src/trading/outcome_enrichment.py"}]},
    {"number": 194, "mergedAt": "2026-09-07T06:37:00Z", "labels": [], "files": [{"path": "src/research/underwriter/outcomes.py"}]}
  ],
  "StartupBros-com/pro-gate": [
    {"number": 173, "mergedAt": "2026-09-07T18:46:00Z", "labels": [], "files": [{"path": "bin/cdp-salvage.mjs"}]}
  ]
}
JSON

# Four charged rounds on one issue, one on another, plus two collect rows that
# are not charges. The trailing block establishes GATE PROVENANCE for merges
# that bought no review: a lock-timeout, a round-cap refusal and a refunded
# submission all prove the lane handled the PR while spending nothing, so they
# must put those PRs in the cohort without moving any round count.
#
# Every row carries a `marker`, as every real ledger row does: charges are
# deduplicated by the conversation they paid for (G10), so a fixture without
# markers would run the whole suite down the unmarked fallback and stop
# exercising the shipped path. The four dotfiles#1028 rounds carry FOUR
# DISTINCT markers because they are four real submissions -- this is the arm
# that proves dedup does not collapse genuine re-reviews -- while each harvest
# reuses the marker of the conversation it collects, as the producer does.
cat > "$TMP/ledger.jsonl" <<'JSON'
{"ts":"2026-09-06T08:11:29-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"clean","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600001-101"}
{"ts":"2026-09-06T08:53:48-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"clean","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600002-102"}
{"ts":"2026-09-06T09:29:35-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"clean","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600003-103"}
{"ts":"2026-09-06T10:02:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"clean","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600004-104"}
{"ts":"2026-09-06T11:00:00-0400","kind":"harvest","round_key":"StartupBros-com-hov-stack-1028","outcome":"clean","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600004-104"}
{"ts":"2026-09-07T06:00:00-0400","kind":"fresh","round_key":"acme-org-trading-app-194","outcome":"clean","marker":"pg-run-acme-org-trading-app-194-1788600005-105"}
{"ts":"2026-09-07T06:30:00-0400","kind":"harvest","round_key":"acme-org-trading-app-194","outcome":"clean","marker":"pg-run-acme-org-trading-app-194-1788600005-105"}
{"ts":"2026-08-01T06:00:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-900","outcome":"clean","marker":"pg-run-StartupBros-com-hov-stack-900-1786000006-106"}
{"ts":"2026-09-06T12:00:00-0400","kind":"fresh","round_key":"acme-org-announce-bot-2619","outcome":"clean","marker":"pg-run-acme-org-announce-bot-2619-1788600007-107"}
{"ts":"2026-09-06T12:30:00-0400","kind":"fresh","round_key":"acme-org-announce-bot-2619","outcome":"clean","marker":"pg-run-acme-org-announce-bot-2619-1788600008-108"}
{"ts":"2026-09-06T13:00:00-0400","kind":"fresh","round_key":"acme-org-announce-bot-2619","outcome":"clean","marker":"pg-run-acme-org-announce-bot-2619-1788600009-109"}
{"ts":"2026-09-06T13:30:00-0400","kind":"fresh","round_key":"acme-org-announce-bot-2619","outcome":"clean","marker":"pg-run-acme-org-announce-bot-2619-1788600010-110"}
{"ts":"2026-09-06T14:00:00-0400","kind":"fresh","round_key":"acme-org-announce-bot-2619","outcome":"clean","marker":"pg-run-acme-org-announce-bot-2619-1788600011-111"}
{"ts":"2026-09-07T09:00:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1043","outcome":"lock-timeout","attempts":0,"marker":"pg-run-StartupBros-com-hov-stack-1043-1788600012-112"}
{"ts":"2026-09-07T09:05:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1042","outcome":"lock-timeout","attempts":0,"marker":"pg-run-StartupBros-com-hov-stack-1042-1788600013-113"}
{"ts":"2026-09-07T09:10:00-0400","kind":"fresh","round_key":"acme-org-trading-app-196","outcome":"round-capped","attempts":0,"marker":"pg-run-acme-org-trading-app-196-1788600014-114"}
{"ts":"2026-09-07T09:15:00-0400","kind":"fresh","round_key":"StartupBros-com-pro-gate-173","outcome":"failed","reason":"refunded-unsubmitted","attempts":0,"marker":"pg-run-StartupBros-com-pro-gate-173-1788600015-115"}
JSON

run() { OUT=$(PIPELINE_MIX_PR_JSON="$1" PIPELINE_MIX_LEDGER="$2" python3 "$SCRIPT" --days 7 2>&1); RC=$?; }

echo "== G1: the audited weekend's shape reports its share, its per-repo split and its worst round count =="
run "$TMP/prs.json" "$TMP/ledger.jsonl"
[ "$RC" = 0 ] && ok || bad "G1 exit $RC: $OUT"
grep -q -F 'gated merges in 7d: 6, of which 4 touch only the pipeline itself (67%)' <<<"$OUT" && ok \
  || bad "G1 share line wrong: $OUT"
grep -q -E 'hov-stack +3 merged, +3 self-referential' <<<"$OUT" && ok || bad "G1 hov-stack split wrong: $OUT"
grep -q -E 'pro-gate +1 merged, +1 self-referential' <<<"$OUT" && ok || bad "G1 pro-gate counts as self: $OUT"
grep -q -F 'hov-stack#1028=4' <<<"$OUT" && ok || bad "G1 worst round count missing: $OUT"
grep -q -F '[WARN] pipeline-mix: 67% of merges were the pipeline working on itself' <<<"$OUT" && ok \
  || bad "G1 share flag missing: $OUT"
grep -q -F 'past 3 Pro rounds (hov-stack#1028)' <<<"$OUT" && ok || bad "G1 rounds flag missing: $OUT"
grep -q -F 'pipeline-mix-flagged:2' <<<"$OUT" && ok || bad "G1 counter wrong: $OUT"
# The label arm carries dotfiles#1034 on its own -- it has no ledger round key,
# so if only the ledger were consulted the cohort would be 5 and the split 2.
grep -q -F 'gated merges in 7d: 5' <<<"$OUT" && bad "G1 the loop-run label did not admit #1034: $OUT" || ok

echo "== G2 (PLANTED NEGATIVE): a product-only window raises no self-referential flag =="
cat > "$TMP/product.json" <<'JSON'
{
  "acme-org/trading-app": [
    {"number": 196, "mergedAt": "2026-09-07T15:19:00Z", "labels": [{"name": "loop-run"}], "files": [{"path": "src/trading/outcome_enrichment.py"}]},
    {"number": 194, "mergedAt": "2026-09-07T06:37:00Z", "labels": [{"name": "loop-run"}], "files": [{"path": "src/research/underwriter/outcomes.py"}]}
  ]
}
JSON
run "$TMP/product.json" "$TMP/ledger.jsonl"
if grep -q -F 'working on itself' <<<"$OUT"; then
  bad "G2 PLANTED NEGATIVE: a product-only window flagged self-reference: $OUT"
else ok; fi
grep -q -F 'of which 0 touch only the pipeline itself (0%)' <<<"$OUT" && ok || bad "G2 share not zero: $OUT"

echo "== G3: a missing ledger says so and still prints the counter =="
run "$TMP/prs.json" "$TMP/nope.jsonl"
[ "$RC" = 0 ] && ok || bad "G3 exit $RC on a missing ledger: $OUT"
grep -q -F 'WARN pipeline-mix: pro-gate ledger missing' <<<"$OUT" && ok || bad "G3 no dead-feed line: $OUT"
grep -q -E 'pipeline-mix-flagged:[0-9]+' <<<"$OUT" && ok || bad "G3 counter missing: $OUT"
# Without the ledger the cohort is whatever the loop-run label caught, which is
# one hov-stack PR -- a share off that alone is not a fleet number.
grep -q -F 'gated merges in 7d: 1' <<<"$OUT" && ok || bad "G3 label-only cohort wrong: $OUT"

echo "== G4 (PLANTED NEGATIVE): a dead PR feed says the share is partial, never reports 0% =="
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 4\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
OUT=$(PATH="$TMP/bin:$PATH" PIPELINE_MIX_LEDGER="$TMP/ledger.jsonl" python3 "$SCRIPT" --days 7 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "G4 exit $RC with a failing gh: $OUT"
grep -q -F 'could not read merges for' <<<"$OUT" && ok || bad "G4 partial-feed line missing: $OUT"
if grep -q -F 'working on itself' <<<"$OUT"; then
  bad "G4 PLANTED NEGATIVE: flagged a share computed from no data: $OUT"
else ok; fi

echo "== G5 (PLANTED NEGATIVE): harvest rows are not charged rounds =="
run "$TMP/prs.json" "$TMP/ledger.jsonl"
if grep -q -F 'hov-stack#1028=5' <<<"$OUT"; then
  bad "G5 PLANTED NEGATIVE: a harvest was counted as a charged round: $OUT"
else ok; fi
grep -q -F 'trading-app#194=1' <<<"$OUT" && ok \
  || bad "G5 a hyphenated repo's key must render in full, not as its last segment: $OUT"
grep -q -F 'median 2.5' <<<"$OUT" && ok \
  || bad "G5 median of a 4-round and a 1-round issue is 2.5, not either endpoint: $OUT"

echo "== G6b (PLANTED NEGATIVE): rounds from a repo outside the report's list are not counted =="
# The first live run counted merges in four repos while the cost line came from
# all five in the ledger, so announce-bot -- the heaviest consumer -- dominated the
# worst-cost list while contributing nothing to the share. Both halves must
# describe the same fleet: PIPELINE_MIX_REPOS above excludes announce-bot, so its
# five in-window rounds must not appear.
if grep -q -F 'announce-bot' <<<"$OUT"; then
  bad "G6b PLANTED NEGATIVE: a repo outside the report's list reached the cost line: $OUT"
else ok; fi

echo "== G6: a row outside the window is not counted =="
if grep -q -F 'hov-stack#900' <<<"$OUT"; then
  bad "G6 a round from 2026-08-01 leaked into a 7-day window: $OUT"
else ok; fi

echo "== G7 (PLANTED NEGATIVE, finding: uncharged invocations counted as charged Pro rounds) =="
# pg_finish() stamps kind=fresh before it knows the exit code, so a run that
# never reached the model is written with the same kind as a completed review.
# Counting on kind alone turned four lock-timeouts on one PR into "median 4,
# dotfiles#1028=4" and a non-convergence warning for a chain that had bought no
# reviews at all. This is that exact ledger.
cat > "$TMP/uncharged.jsonl" <<'JSON'
{"ts":"2026-09-06T08:11:29-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"lock-timeout","attempts":0}
{"ts":"2026-09-06T08:53:48-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"lock-timeout","attempts":0}
{"ts":"2026-09-06T09:29:35-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"round-capped","attempts":0}
{"ts":"2026-09-06T10:02:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"failed","reason":"refunded-unsubmitted","attempts":0}
{"ts":"2026-09-06T10:30:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"deferred","attempts":0}
{"ts":"2026-09-06T10:40:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"oversized","attempts":0}
{"ts":"2026-09-06T10:50:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"bad-repo","attempts":0}
{"ts":"2026-09-06T10:55:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"diff-fetch-failed","attempts":0}
{"ts":"2026-09-06T10:58:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"cloudflare","attempts":0}
{"ts":"2026-09-06T10:59:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"other","attempts":0}
{"ts":"2026-09-06T11:05:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"failed","reason":"pre-dispatch","attempts":0}
{"ts":"2026-09-07T07:00:00-0400","kind":"fresh","round_key":"acme-org-trading-app-194","outcome":"clean"}
{"ts":"2026-09-07T07:30:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1043","outcome":"lock-timeout","attempts":0}
JSON
run "$TMP/prs.json" "$TMP/uncharged.jsonl"
[ "$RC" = 0 ] && ok || bad "G7 exit $RC: $OUT"
if grep -q -E 'hov-stack#1028=[0-9]' <<<"$OUT"; then
  bad "G7 PLANTED NEGATIVE: a lock-timeout / round-cap / refunded round was billed to hov-stack#1028: $OUT"
else ok; fi
if grep -q -F 'past 3 Pro rounds' <<<"$OUT"; then
  bad "G7 PLANTED NEGATIVE: pre-dispatch congestion raised the non-convergence flag: $OUT"
else ok; fi
# The one genuinely charged row still counts: this must narrow the predicate,
# not disable it.
grep -q -F 'trading-app#194=1' <<<"$OUT" && ok || bad "G7 a clean fresh round stopped counting: $OUT"
grep -q -F 'median 1' <<<"$OUT" && ok || bad "G7 median should be the single charged round: $OUT"
# A never-charged PR is still a GATED PR: its ledger rows prove the lane handled
# it, so it stays in the cohort even though it bought nothing.
grep -q -F 'gated merges in 7d: 3' <<<"$OUT" && ok \
  || bad "G7 an uncharged ledger row must still establish gate provenance: $OUT"
if grep -q -F 'hov-stack#1043' <<<"$OUT"; then
  bad "G7 PLANTED NEGATIVE: a lock-timeout put hov-stack#1043 on the cost line: $OUT"
else ok; fi

echo "== G8 (PLANTED NEGATIVE, finding: ungated merges dilute the gated-PR share) =="
# Two gated pipeline-only merges beside eight ordinary product merges. Filtering
# on the merge timestamp alone reports 20%, comfortably under the 40% threshold,
# while the cohort issue #1045 actually asks about is 100% self-referential --
# ordinary work concealing exactly the workload this report exists to surface.
cat > "$TMP/diluted.json" <<'JSON'
{
  "StartupBros-com/hov-stack": [
    {"number": 1043, "mergedAt": "2026-09-07T12:18:22Z", "labels": [{"name": "loop-run"}], "files": [{"path": "scripts/pro-gate-loop.sh"}]},
    {"number": 1042, "mergedAt": "2026-09-07T11:45:36Z", "labels": [{"name": "loop-run"}], "files": [{"path": "bin/claude-loop.sh"}]},
    {"number": 1041, "mergedAt": "2026-09-07T11:00:00Z", "labels": [], "files": [{"path": "docs/a.md"}]},
    {"number": 1040, "mergedAt": "2026-09-07T10:00:00Z", "labels": [], "files": [{"path": "docs/b.md"}]},
    {"number": 1039, "mergedAt": "2026-09-07T09:00:00Z", "labels": [], "files": [{"path": "docs/c.md"}]},
    {"number": 1038, "mergedAt": "2026-09-07T08:00:00Z", "labels": [], "files": [{"path": "src/d.py"}]},
    {"number": 1037, "mergedAt": "2026-09-07T07:00:00Z", "labels": [], "files": [{"path": "src/e.py"}]},
    {"number": 1036, "mergedAt": "2026-09-07T06:00:00Z", "labels": [], "files": [{"path": "src/f.py"}]},
    {"number": 1035, "mergedAt": "2026-09-07T05:00:00Z", "labels": [], "files": [{"path": "src/g.py"}]},
    {"number": 1033, "mergedAt": "2026-09-07T04:00:00Z", "labels": [], "files": [{"path": "src/h.py"}]}
  ]
}
JSON
run "$TMP/diluted.json" "$TMP/ledger.jsonl"
[ "$RC" = 0 ] && ok || bad "G8 exit $RC: $OUT"
grep -q -F 'gated merges in 7d: 2, of which 2 touch only the pipeline itself (100%)' <<<"$OUT" && ok \
  || bad "G8 ungated merges reached the denominator: $OUT"
if grep -q -F '(20%)' <<<"$OUT"; then
  bad "G8 PLANTED NEGATIVE: eight ungated product merges diluted the gated share to 20%: $OUT"
else ok; fi
grep -q -F '[WARN] pipeline-mix: 100% of merges were the pipeline working on itself' <<<"$OUT" && ok \
  || bad "G8 the self-referential flag was hidden by ungated work: $OUT"

echo "== G9 (PLANTED NEGATIVE, finding: the merge limit silently truncates a normal week) =="
# `gh pr list --limit N` caps the WHOLE result and reports no truncation of its
# own, so a response of exactly N is indistinguishable from a complete one. At
# the shipped cap of 100 that silently dropped a third of a real week (announce-bot
# 163, hov-stack 172 in-window on 2026-09-07) and skewed the share it never
# warned about. This gh stub returns exactly $GH_STUB_ROWS rows, never more than
# --limit, so both sides of the boundary are exercised against the real code path.
mkdir -p "$TMP/bin2"
cat > "$TMP/bin2/gh" <<'STUB'
#!/usr/bin/env bash
# Fake `gh pr list` metadata and `gh pr view` details for the same merges.
if [ "$2" = view ]; then
  printf '{"files":[{"path":"scripts/pro-gate-loop.sh"}]}\n'
  exit 0
fi
limit=0
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) limit=$2; shift 2 ;;
    *) shift ;;
  esac
done
n=${GH_STUB_ROWS:-0}
[ "$n" -gt "$limit" ] && n=$limit
printf '['
i=0
while [ "$i" -lt "$n" ]; do
  [ "$i" -gt 0 ] && printf ','
  printf '{"number":%d,"mergedAt":"2026-09-07T10:00:00Z","labels":[{"name":"loop-run"}]}' "$((900 + i))"
  i=$((i + 1))
done
printf ']\n'
STUB
chmod +x "$TMP/bin2/gh"

# a) the feed comes back exactly at the cap -> partial, and no threshold verdict
OUT=$(PATH="$TMP/bin2:$PATH" GH_STUB_ROWS=9 PIPELINE_MIX_GH_LIMIT=4 \
      PIPELINE_MIX_LEDGER="$TMP/ledger.jsonl" python3 "$SCRIPT" --days 7 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "G9a exit $RC: $OUT"
grep -q -F 'WARN pipeline-mix: merge feed hit the 4-PR cap' <<<"$OUT" && ok \
  || bad "G9a a capped feed was reported as complete: $OUT"
if grep -q -F 'working on itself' <<<"$OUT"; then
  bad "G9a PLANTED NEGATIVE: a share from a truncated feed was compared against the threshold: $OUT"
else ok; fi
# The unbracketed WARN is what reaches harness-weekly's '^WARN' toast gate.
grep -q -E '^WARN pipeline-mix: merge feed hit' <<<"$OUT" && ok \
  || bad "G9a the partial-feed WARN is not at column 0, so the toast gate would miss it: $OUT"

# b) the same feed under the cap -> complete, and the verdict is issued
OUT=$(PATH="$TMP/bin2:$PATH" GH_STUB_ROWS=3 PIPELINE_MIX_GH_LIMIT=4 \
      PIPELINE_MIX_LEDGER="$TMP/ledger.jsonl" python3 "$SCRIPT" --days 7 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "G9b exit $RC: $OUT"
if grep -q -F 'merge feed hit the' <<<"$OUT"; then
  bad "G9b a complete feed was reported as truncated: $OUT"
else ok; fi
grep -q -F '[WARN] pipeline-mix: 100% of merges were the pipeline working on itself' <<<"$OUT" && ok \
  || bad "G9b the truncation guard suppressed a verdict on a complete feed: $OUT"

echo "== G10 (PLANTED NEGATIVE, finding: reservation redirects count one Pro conversation as several charged rounds) =="
# pro-gate round 2, pipeline-mix-report.py:210. oracle-review.sh's reservation
# redirect sets RUN_MARKER to the marker of the conversation ALREADY generating
# and exits 9 without submitting, but pg_finish() stamps kind=fresh (it assigns
# kind before it knows the exit code) and outcome=in-progress -- which passes
# charged(). Counted per row, one submitted-and-still-generating review plus
# three redirects reports "median 4, dotfiles#1028=4" and the past-3-rounds
# warning for a chain that bought exactly ONE review. This is that shape, taken
# from live ledger marker pg-run-acme-org-announce-bot-1962-1787612345-3354518,
# which carries three such rows under one round key on 2026-08-24..25.
cat > "$TMP/redirect.jsonl" <<'JSON'
{"ts":"2026-09-06T08:11:29-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","exit":9,"outcome":"in-progress","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600100-201"}
{"ts":"2026-09-06T09:11:29-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","exit":9,"outcome":"in-progress","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600100-201"}
{"ts":"2026-09-06T10:11:29-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","exit":9,"outcome":"in-progress","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600100-201"}
{"ts":"2026-09-06T11:11:29-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","exit":9,"outcome":"in-progress","marker":"pg-run-StartupBros-com-hov-stack-1028-1788600100-201"}
{"ts":"2026-09-07T06:00:00-0400","kind":"fresh","round_key":"acme-org-trading-app-194","outcome":"clean","marker":"pg-run-acme-org-trading-app-194-1788600200-202"}
{"ts":"2026-09-07T07:00:00-0400","kind":"fresh","round_key":"acme-org-trading-app-194","outcome":"clean","marker":"pg-run-acme-org-trading-app-194-1788600300-203"}
JSON
run "$TMP/prs.json" "$TMP/redirect.jsonl"
[ "$RC" = 0 ] && ok || bad "G10 exit $RC: $OUT"
if grep -q -E 'hov-stack#1028=(2|3|4)' <<<"$OUT"; then
  bad "G10 PLANTED NEGATIVE: three reservation redirects were billed as extra Pro rounds: $OUT"
else ok; fi
grep -q -F 'hov-stack#1028=1' <<<"$OUT" && ok \
  || bad "G10 the one conversation the redirects point at must still cost one round: $OUT"
if grep -q -F 'past 3 Pro rounds' <<<"$OUT"; then
  bad "G10 PLANTED NEGATIVE: redirect rows raised the non-convergence flag for a one-round chain: $OUT"
else ok; fi
# Dedup must narrow the count, not collapse genuine re-reviews: #194's two rows
# are two distinct submissions with two distinct markers.
grep -q -F 'trading-app#194=2' <<<"$OUT" && ok \
  || bad "G10 two separately-marked submissions were over-deduplicated into one: $OUT"
grep -q -F 'median 1.5' <<<"$OUT" && ok || bad "G10 median of a 1-round and a 2-round issue is 1.5: $OUT"
# Every row here is marked, so nothing is unresolved.
if grep -q -F 'carry no conversation marker' <<<"$OUT"; then
  bad "G10 a fully-marked ledger reported unresolved spend: $OUT"
else ok; fi

# b) a redirect must not drag an out-of-window charge INTO the window. The
# conversation was paid for on 2026-08-20, weeks before this 7d window; the
# redirects that point at it land inside it. Deduplicating after windowing
# would attribute the charge to the first redirect and bill last month's spend
# to this week, so dedup runs across the whole ledger and keeps the EARLIEST
# charged row's timestamp.
cat > "$TMP/redirect-window.jsonl" <<'JSON'
{"ts":"2026-08-20T08:00:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","exit":9,"outcome":"in-progress","marker":"pg-run-StartupBros-com-hov-stack-1028-1787200000-301"}
{"ts":"2026-09-06T08:00:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","exit":9,"outcome":"in-progress","marker":"pg-run-StartupBros-com-hov-stack-1028-1787200000-301"}
{"ts":"2026-09-06T09:00:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","exit":9,"outcome":"in-progress","marker":"pg-run-StartupBros-com-hov-stack-1028-1787200000-301"}
JSON
run "$TMP/prs.json" "$TMP/redirect-window.jsonl"
[ "$RC" = 0 ] && ok || bad "G10b exit $RC: $OUT"
if grep -q -F 'hov-stack#1028' <<<"$OUT"; then
  bad "G10b PLANTED NEGATIVE: a redirect moved an August charge into a September window: $OUT"
else ok; fi
grep -q -F 'Pro rounds per gated issue: median 0, worst none' <<<"$OUT" && ok \
  || bad "G10b no charge was paid for inside this window: $OUT"

# c) spend that names no conversation cannot be deduplicated, so it is counted
# and reported separately rather than vouched for.
cat > "$TMP/unmarked.jsonl" <<'JSON'
{"ts":"2026-09-06T08:00:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1028","outcome":"clean"}
JSON
run "$TMP/prs.json" "$TMP/unmarked.jsonl"
[ "$RC" = 0 ] && ok || bad "G10c exit $RC: $OUT"
grep -q -F 'hov-stack#1028=1' <<<"$OUT" && ok \
  || bad "G10c unmarked spend evidence must still be counted, not dropped: $OUT"
grep -q -E '^WARN pipeline-mix: 1 charged round\(s\) carry no conversation marker' <<<"$OUT" && ok \
  || bad "G10c undedupable spend was folded in silently: $OUT"

echo "== G11 (PLANTED NEGATIVE, finding: malformed ledger rows are treated as a complete feed) =="
# pro-gate round 2, pipeline-mix-report.py:408. read_ledger() counted parse
# failures and skipped those rows, and the human path threw the count away: a
# readable ledger holding only a truncated record printed "median 0, worst
# none" plus pipeline-mix-flagged:0 -- a confident zero off a feed that had
# been read in half, with nothing at column 0 for the weekly toast gate.
printf '{"ts":"2026-09-06T08:11:29-0400","kind":"fresh","round_key":"StartupBros-com-dotfil\n' \
  > "$TMP/torn.jsonl"
run "$TMP/prs.json" "$TMP/torn.jsonl"
[ "$RC" = 0 ] && ok || bad "G11 exit $RC on a torn ledger: $OUT"
grep -q -E '^WARN pipeline-mix: 1 unreadable ledger row\(s\) skipped' <<<"$OUT" && ok \
  || bad "G11 PLANTED NEGATIVE: an all-malformed ledger reported as a complete feed: $OUT"
grep -q -F 'Pro rounds per gated issue: median 0, worst none' <<<"$OUT" && ok \
  || bad "G11 the round line should still print its (empty) counts: $OUT"
# The cohort here collapses to the loop-run label alone (dotfiles#1034, wholly
# self-referential), so an unguarded threshold check reads 100% and flags it off
# a feed that lost an unknown number of rows.
if grep -q -F 'working on itself' <<<"$OUT"; then
  bad "G11 PLANTED NEGATIVE: a share from a half-read ledger was compared against the threshold: $OUT"
else ok; fi
grep -q -F 'pipeline-mix-flagged:0' <<<"$OUT" && ok || bad "G11 counter wrong: $OUT"

# b) mixed valid and malformed: the readable rows still feed the cost line, the
# torn one drops dotfiles#1042 out of the gated cohort, and the resulting share
# is reported without a verdict.
cat > "$TMP/mixed.jsonl" <<'JSON'
{"ts":"2026-09-07T08:00:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1043","outcome":"clean","marker":"pg-run-StartupBros-com-hov-stack-1043-1788700001-401"}
{"ts":"2026-09-07T08:30:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-104
{"ts":"2026-09-07T09:00:00-0400","kind":"fresh","round_key":"StartupBros-com-pro-gate-173","outcome":"clean","marker":"pg-run-StartupBros-com-pro-gate-173-1788700003-403"}
JSON
run "$TMP/prs.json" "$TMP/mixed.jsonl"
[ "$RC" = 0 ] && ok || bad "G11b exit $RC: $OUT"
grep -q -E '^WARN pipeline-mix: 1 unreadable ledger row\(s\) skipped' <<<"$OUT" && ok \
  || bad "G11b a mixed ledger was reported as complete: $OUT"
grep -q -F 'hov-stack#1043=1' <<<"$OUT" && ok \
  || bad "G11b the readable rows must still be counted, not discarded with the torn one: $OUT"
# 1043 and pro-gate#173 come from the ledger, 1034 from the loop-run label;
# 1042's provenance died with the torn row, which is exactly why the share below
# is not comparable to a threshold.
grep -q -F 'gated merges in 7d: 3' <<<"$OUT" && ok || bad "G11b cohort wrong: $OUT"
if grep -q -F 'working on itself' <<<"$OUT"; then
  bad "G11b PLANTED NEGATIVE: a cohort missing a member to a torn row was still graded: $OUT"
else ok; fi
grep -q -F 'pipeline-mix-flagged:0' <<<"$OUT" && ok || bad "G11b counter wrong: $OUT"

# c) valid JSON is not necessarily a ledger object (dotfiles#1057). Scalars
# used to raise AttributeError at row.get(), losing the report entirely.
cat > "$TMP/scalars.jsonl" <<'JSON'
42
3.14
"ledger row"
true
false
null
JSON
run "$TMP/prs.json" "$TMP/scalars.jsonl"
[ "$RC" = 0 ] && ok || bad "G11c exit $RC on an all-scalar ledger: $OUT"
grep -q -E '^WARN pipeline-mix: 6 unreadable ledger row\(s\) skipped' <<<"$OUT" && ok \
  || bad "G11c scalar rows must be counted as malformed: $OUT"
grep -q -F 'Pro rounds per gated issue: median 0, worst none' <<<"$OUT" && ok \
  || bad "G11c the empty round counts must still print: $OUT"
grep -q -F 'gated merges in 7d: 1, of which 1 touch only the pipeline itself (100%)' <<<"$OUT" && ok \
  || bad "G11c the label-only cohort must still print: $OUT"
if grep -q -F 'working on itself' <<<"$OUT"; then
  bad "G11c PLANTED NEGATIVE: an all-scalar ledger's partial cohort was still graded: $OUT"
else ok; fi
grep -q -F 'pipeline-mix-flagged:0' <<<"$OUT" && ok || bad "G11c counter wrong: $OUT"

# d) malformed shapes before, between and after valid rows must not discard
# their costs or provenance. An array wrapping an otherwise valid row is still
# malformed, not a batch to flatten into the ledger.
cat > "$TMP/mixed-shapes.jsonl" <<'JSON'
42
{"ts":"2026-09-07T08:00:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1043","outcome":"clean","marker":"m1"}
[]
[{"ts":"2026-09-07T08:30:00-0400","kind":"fresh","round_key":"StartupBros-com-hov-stack-1042","outcome":"clean","marker":"m2"}]
{"ts":"2026-09-07T09:00:00-0400","kind":"fresh","round_key":"StartupBros-com-pro-gate-173","outcome":"clean","marker":"m3"}
null
JSON
run "$TMP/prs.json" "$TMP/mixed-shapes.jsonl"
[ "$RC" = 0 ] && ok || bad "G11d exit $RC on a mixed-shape ledger: $OUT"
grep -q -E '^WARN pipeline-mix: 4 unreadable ledger row\(s\) skipped' <<<"$OUT" && ok \
  || bad "G11d scalars and arrays must be counted as malformed: $OUT"
grep -q -F 'Pro rounds per gated issue: median 1, worst hov-stack#1043=1, pro-gate#173=1' <<<"$OUT" && ok \
  || bad "G11d valid rows' costs were lost or the array was counted: $OUT"
grep -q -F 'gated merges in 7d: 3, of which 3 touch only the pipeline itself (100%)' <<<"$OUT" && ok \
  || bad "G11d valid rows must still establish gate provenance: $OUT"
if grep -q -F 'working on itself' <<<"$OUT"; then
  bad "G11d PLANTED NEGATIVE: a mixed-shape ledger's partial cohort was still graded: $OUT"
else ok; fi
grep -q -F 'pipeline-mix-flagged:0' <<<"$OUT" && ok || bad "G11d counter wrong: $OUT"

# Both fixtures must also produce parseable --json output with exact malformed
# counts; a human-only recovery would leave machine consumers broken.
python3 - "$SCRIPT" "$TMP" <<'PY' && ok || bad "G11e JSON shape-regression assertions failed"
import json
import os
import subprocess
import sys

script, tmp = sys.argv[1:]
for ledger, malformed, total, median, worst in (
    ("scalars.jsonl", 6, 1, 0, []),
    ("mixed-shapes.jsonl", 4, 3, 1,
     [["StartupBros-com-hov-stack-1043", 1], ["StartupBros-com-pro-gate-173", 1]]),
):
    env = dict(os.environ, PIPELINE_MIX_PR_JSON=f"{tmp}/prs.json", PIPELINE_MIX_LEDGER=f"{tmp}/{ledger}")
    result = subprocess.run([sys.executable, script, "--days", "7", "--json"],
                            env=env, capture_output=True, text=True)
    assert result.returncode == 0, (ledger, result.stderr)
    assert not result.stderr, (ledger, result.stderr)
    data = json.loads(result.stdout)
    assert data["malformed"] == malformed, (ledger, data)
    assert data["unresolved"] == 0, (ledger, data)
    assert data["summary"]["total"] == total, (ledger, data)
    assert data["summary"]["median"] == median, (ledger, data)
    assert data["summary"]["worst"] == worst, (ledger, data)
PY

echo "== G12 (PLANTED NEGATIVE, finding: a driver's own regression suite is off the pipeline surface) =="
# pro-gate round 3, pipeline-mix-report.py:48. SELF_PATHS enumerated three test
# files while the tree held three more for the SAME three drivers
# (claude-loop-budget-stop, claude-loop-cut-short, claude-loop-quality-mode all
# drive bin/claude-loop.sh). is_self() requires EVERY changed path to
# match, so one unlisted suite flipped a whole merge out of the self-referential
# count: hardening the driver and its own regression test read as product work.
# Two pipeline-only merges beside one product merge reported 33% -- under the
# 40% threshold, so the warning never fired.
cat > "$TMP/driver-plus-suite.json" <<'JSON'
{
  "StartupBros-com/hov-stack": [
    {"number": 1043, "mergedAt": "2026-09-07T12:18:22Z", "labels": [{"name": "loop-run"}], "files": [{"path": "bin/claude-loop.sh"}, {"path": "tests/claude-loop-cut-short.test.sh"}]},
    {"number": 1042, "mergedAt": "2026-09-07T11:45:36Z", "labels": [{"name": "loop-run"}], "files": [{"path": "bin/claude-loop.sh"}, {"path": "tests/claude-loop-budget-stop.test.sh"}]},
    {"number": 1041, "mergedAt": "2026-09-07T11:00:00Z", "labels": [{"name": "loop-run"}], "files": [{"path": "src/product.py"}]}
  ]
}
JSON
run "$TMP/driver-plus-suite.json" "$TMP/ledger.jsonl"
[ "$RC" = 0 ] && ok || bad "G12 exit $RC: $OUT"
grep -q -F 'gated merges in 7d: 3, of which 2 touch only the pipeline itself (67%)' <<<"$OUT" && ok \
  || bad "G12 PLANTED NEGATIVE: a driver merged with its own regression suite was counted as product work: $OUT"
grep -q -F '[WARN] pipeline-mix: 67% of merges were the pipeline working on itself' <<<"$OUT" && ok \
  || bad "G12 the excluded suites suppressed the 40% warning: $OUT"

# b) the suites widen the surface, they must not swallow the denominator: a
# merge that touches a driver, its suite AND a product file is product work.
cat > "$TMP/suite-plus-product.json" <<'JSON'
{
  "StartupBros-com/hov-stack": [
    {"number": 1044, "mergedAt": "2026-09-07T12:18:22Z", "labels": [{"name": "loop-run"}], "files": [{"path": "bin/claude-loop.sh"}, {"path": "tests/claude-loop-quality-mode.test.sh"}, {"path": "src/product.py"}]}
  ]
}
JSON
run "$TMP/suite-plus-product.json" "$TMP/ledger.jsonl"
[ "$RC" = 0 ] && ok || bad "G12b exit $RC: $OUT"
grep -q -F 'of which 0 touch only the pipeline itself (0%)' <<<"$OUT" && ok \
  || bad "G12b a merge carrying a product file was counted as pipeline-only: $OUT"

# c) the surface is a NAMING RULE, so check it against the real tests tree
# rather than against this suite's idea of it. Every `<driver>[-<aspect>]
# .test.sh` file that exists today must land on the surface -- that is what
# turns "add a claude-loop suite" from a silent misclassification into a
# no-op -- and the sibling suites for OTHER drivers must stay off it.
n=0
{
  printf '{\n  "StartupBros-com/hov-stack": [\n'
  for f in "$HERE"/tests/claude-loop*.test.sh "$HERE"/tests/pro-gate-loop*.test.sh \
           "$HERE"/tests/dispatcher-tick*.test.sh; do
    [ -e "$f" ] || continue
    [ "$n" -gt 0 ] && printf ',\n'
    printf '    {"number": %d, "mergedAt": "2026-09-07T10:00:00Z", "labels": [{"name": "loop-run"}], "files": [{"path": "tests/%s"}]}' \
      "$((2000 + n))" "${f##*/}"
    n=$((n + 1))
  done
  printf '\n  ]\n}\n'
} > "$TMP/real-suites.json"
# A glob that matched nothing would make the 100% assertion below vacuous. The
# floor is the live driver-suite count: three claude-loop suites and
# pro-gate-loop (the context-fence suite left in harness teardown move 5,
# claude-loop-quality-mode with loop_quality in #1914).
[ "$n" -ge 4 ] && ok || bad "G12c only $n driver suites found in $HERE/tests - the surface check is vacuous"
run "$TMP/real-suites.json" "$TMP/ledger.jsonl"
[ "$RC" = 0 ] && ok || bad "G12c exit $RC: $OUT"
grep -q -F "gated merges in 7d: $n, of which $n touch only the pipeline itself (100%)" <<<"$OUT" && ok \
  || bad "G12c a regression suite for one of the three drivers is not on the pipeline surface: $OUT"

# The over-match negative: these suites live beside the driver suites and test
# DIFFERENT drivers (dispatcher-ledger.sh, dispatcher-status.sh,
# loop-quality.py), so a prefix rule that swallowed them would report ordinary
# work as the pipeline working on itself.
cat > "$TMP/other-drivers.json" <<'JSON'
{
  "StartupBros-com/hov-stack": [
    {"number": 1051, "mergedAt": "2026-09-07T10:00:00Z", "labels": [{"name": "loop-run"}], "files": [{"path": "tests/dispatcher-ledger.test.sh"}]},
    {"number": 1052, "mergedAt": "2026-09-07T10:01:00Z", "labels": [{"name": "loop-run"}], "files": [{"path": "tests/dispatcher-status.test.sh"}]},
    {"number": 1053, "mergedAt": "2026-09-07T10:02:00Z", "labels": [{"name": "loop-run"}], "files": [{"path": "tests/loop-quality-integration.test.sh"}]},
    {"number": 1054, "mergedAt": "2026-09-07T10:03:00Z", "labels": [{"name": "loop-run"}], "files": [{"path": "tests/discord-notify.test.sh"}]}
  ]
}
JSON
run "$TMP/other-drivers.json" "$TMP/ledger.jsonl"
[ "$RC" = 0 ] && ok || bad "G12d exit $RC: $OUT"
grep -q -F 'of which 0 touch only the pipeline itself (0%)' <<<"$OUT" && ok \
  || bad "G12d a suite for a different driver was pulled onto the pipeline surface: $OUT"

echo "== G13 (PLANTED NEGATIVE): file-list reads scale with the gated cohort, not the merge population =="
# Exercise main() with the real ledger/window/cohort/render chain, replacing only
# the gh process boundary. The population carries NO files and the stub rejects
# a broad file request, so old eager fetching cannot pass on a generous fixture.
PYTHONDONTWRITEBYTECODE=1 python3 - "$SCRIPT" "$TMP" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("pipeline_mix", sys.argv[1])
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
tmp = Path(sys.argv[2])
repo = "StartupBros-com/hov-stack"
other = "acme-org/trading-app"


def merge(number, labels=(), stamp="2026-09-07T10:00:00Z"):
    return {"number": number, "mergedAt": stamp,
            "labels": [{"name": label} for label in labels]}


class CohortFetchTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.timeouts = []
        self.clock = 0
        self.latency = 0
        self.population = {
            repo: [merge(n) for n in range(3000, 3250)] + [
                merge(1043),                       # ledger only, never charged
                merge(900),                        # ledger before the window
                merge(1034, ["loop-run"]),          # label only
                merge(1042, ["loop-run"]),          # both, fetch only once
                merge(800, ["loop-run"], "2026-08-31T23:59:59Z"),
                merge(1100, ["loop-run"], "2026-09-08T00:00:01Z"),
            ],
            other: [merge(196)],
        }
        self.details = {
            (repo, "1043"): [{"path": "scripts/pro-gate-loop.sh"}],
            (repo, "900"): [{"path": "docs/product.md"}],
            (repo, "1034"): [{"path": "bin/claude-loop.sh"}],
            (repo, "1042"): [{"path": "bin/claude-loop.sh"}, {"path": "src/product.py"}],
            (other, "196"): [{"path": "src/product.py"}],
        }
        self.detail_failure = None
        self.env = {
            "PIPELINE_MIX_NOW": "2026-09-08T00:00:00+0000",
            "PIPELINE_MIX_REPOS": repo,
            "PIPELINE_MIX_LEDGER": str(tmp / "ledger.jsonl"),
            "PIPELINE_MIX_PR_JSON": "",
            "PIPELINE_MIX_GH_LIMIT": "500",
            "PIPELINE_MIX_GH_TIMEOUT": "17",
            "PIPELINE_MIX_SELF_SHARE_WARN": "0.4",
        }

    def gh(self, argv, **kwargs):
        self.calls.append(argv)
        timeout = kwargs["timeout"]
        self.timeouts.append(timeout)
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, 17)
        self.assertEqual(kwargs, {"capture_output": True, "text": True, "timeout": timeout})
        if self.latency > timeout:
            self.clock += timeout
            raise subprocess.TimeoutExpired(argv, timeout)
        self.clock += self.latency
        target = argv[argv.index("--repo") + 1]
        fields = argv[argv.index("--json") + 1]
        if argv[:3] == ["gh", "pr", "list"]:
            self.assertEqual(fields, "number,mergedAt,labels", "population fetch must not request files")
            self.assertEqual(argv[argv.index("--state") + 1], "merged")
            self.assertEqual(argv[argv.index("--search") + 1], "merged:>=2026-09-01")
            limit = int(argv[argv.index("--limit") + 1])
            value = self.population[target][:limit]
        else:
            self.assertEqual(argv[:3], ["gh", "pr", "view"])
            self.assertEqual(fields, "files")
            key = (target, argv[3])
            self.assertIn(key, self.details, "file read outside the in-window gated cohort")
            if key == (repo, "1034") and self.detail_failure is not None:
                if isinstance(self.detail_failure, Exception):
                    raise self.detail_failure
                return self.detail_failure
            value = {"files": self.details[key]}
        return subprocess.CompletedProcess(argv, 0, json.dumps(value), "")

    def run_report(self, as_json=True):
        output = io.StringIO()
        with patch.dict(os.environ, self.env), patch.object(report.subprocess, "run", side_effect=self.gh), \
                patch("time.monotonic", side_effect=lambda: self.clock):
            with contextlib.redirect_stdout(output):
                self.assertEqual(report.main(["--json"] if as_json else []), 0)
        return json.loads(output.getvalue()) if as_json else output.getvalue()

    def views(self):
        return [(a[a.index("--repo") + 1], a[3]) for a in self.calls if a[2] == "view"]

    def test_population_is_cheap_and_union_gets_exactly_one_detail_read_each(self):
        result = self.run_report()
        self.assertEqual(len(self.calls), 5)  # 256 metadata rows, only 4 detail reads
        self.assertCountEqual(self.views(), [(repo, str(n)) for n in (1043, 900, 1034, 1042)])
        self.assertEqual(result["summary"]["total"], 4)
        self.assertEqual(result["summary"]["self"], 2)
        self.assertEqual(result["summary"]["share"], 0.5)
        self.assertEqual(result["failed"], [])
        self.assertEqual(result["truncated"], [])
        self.assertIn("[WARN] pipeline-mix: 50% of merges", self.run_report(False))

    def test_no_cohort_means_no_detail_reads(self):
        self.population[repo] = [merge(n) for n in range(3000, 3250)]
        self.assertEqual(self.run_report()["summary"]["total"], 0)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.views(), [])

    def test_missing_ledger_preserves_label_only_fallback(self):
        self.env["PIPELINE_MIX_LEDGER"] = str(tmp / "missing-ledger")
        self.assertEqual(self.run_report()["summary"]["total"], 2)
        self.assertCountEqual(self.views(), [(repo, "1034"), (repo, "1042")])
        output = self.run_report(False)
        self.assertIn("WARN pipeline-mix: pro-gate ledger missing", output)
        self.assertNotIn("[WARN] pipeline-mix: 50%", output)

    def test_empty_file_list_is_valid_product_work(self):
        self.details[(repo, "1043")] = []
        result = self.run_report()
        self.assertEqual(result["failed"], [])
        self.assertEqual(result["summary"]["self"], 1)
        self.assertEqual(result["summary"]["total"], 4)

    def test_detail_failures_are_partial_and_other_repos_still_report(self):
        self.env["PIPELINE_MIX_REPOS"] = repo + "," + other
        failures = [
            subprocess.CompletedProcess([], 1, "", "API failure"),
            subprocess.TimeoutExpired("gh", 17), OSError("gh unavailable"),
        ] + [subprocess.CompletedProcess([], 0, body, "") for body in
             ("not json", "", "null", "[]", "{}", '{"files":null}',
              '{"files":{}}', '{"files":[{}]}', '{"files":[{"path":7}]}')]
        for failure in failures:
            with self.subTest(failure=str(failure)):
                self.detail_failure = failure
                result = self.run_report()
                self.assertEqual(result["failed"], [repo])
                self.assertNotIn(repo, result["summary"]["per_repo"])
                self.assertEqual(result["summary"]["per_repo"][other], [1, 0])
                output = self.run_report(False)
                self.assertIn("WARN pipeline-mix: could not read merges for " + repo, output)
                self.assertIn("the share is partial", output)
                self.assertNotIn("of merges were the pipeline working on itself", output)

    def test_slow_details_share_one_repo_budget(self):
        self.latency = 8  # every call fits under 17s; the full cohort does not
        result = self.run_report()
        self.assertEqual(result["failed"], [repo])
        self.assertNotIn(repo, result["summary"]["per_repo"])
        self.assertEqual(self.timeouts, [17, 9, 1])
        self.assertEqual(self.clock, 17)

    def test_exhausted_budget_launches_no_more_details(self):
        self.latency = 17  # population succeeds just as its budget expires
        result = self.run_report()
        self.assertEqual(result["failed"], [repo])
        self.assertEqual(self.views(), [])
        self.assertEqual(self.timeouts, [17])

    def test_each_repo_gets_its_own_budget(self):
        self.env["PIPELINE_MIX_REPOS"] = repo + "," + other
        self.population[repo] = [merge(1043)]
        self.latency = 8
        result = self.run_report()
        self.assertEqual(result["failed"], [])
        self.assertEqual(result["summary"]["total"], 2)
        self.assertEqual(self.timeouts, [17, 9, 17, 9])
        self.assertEqual(self.clock, 32)

    def test_fixture_mode_never_calls_gh(self):
        self.env["PIPELINE_MIX_PR_JSON"] = str(tmp / "prs.json")
        result = self.run_report()
        self.assertEqual(result["summary"]["total"], 3)
        self.assertEqual(result["summary"]["self"], 3)
        self.assertEqual(self.calls, [])


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
[ "$?" = 0 ] && ok || bad "G13 cohort-fetch regression tests failed"

echo
echo "pipeline-mix-report: $pass passed, $fail failed"
[ "$fail" = 0 ]
