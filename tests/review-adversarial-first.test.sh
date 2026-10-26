#!/usr/bin/env bash
# review-adversarial-first.test.sh — dry, agent-free unit tests for the
# review-adversarial-first Workflow script's pure pieces: the domain map, the
# lens-prompt builder, the findings schema, the collect check (validates
# Collect's file-backed diff, dotfiles #1307), the deterministic judge
# (dedup + verdict + lens-coverage gate) and the round decisions (ledger
# trust, RED selection and mapping, churn scoring, record bounds and confirm
# outcomes, cross-checked against U1 review-rounds.py). A second section runs
# the whole shipped script with stubbed agent()/parallel(), so the call ORDER
# of those gates is pinned too, not just the gates as callees. Real
# lens/collect agents are exercised only by live runs (first on a real PR:
# dotfiles #1337's own review, 2026-09-23).
#
# EXTRACTION APPROACH: same shape as skills-localize-names.test.sh and
# harness-weekly-tokscale.test.sh -- sed-extract the marked blocks out of the
# REAL shipped script (never a hand-copied reimplementation) into a scratch
# Node file, with a sanity check so a rename/restructure of the markers fails
# this suite loudly instead of silently testing stale code.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$REPO/workflows/review-adversarial-first.js"

if [ ! -f "$SRC" ]; then
  echo "FAIL: cannot find $SRC" >&2
  exit 1
fi

TMP=$(mktemp -d /tmp/review-adversarial-first-test.XXXXXX)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

extract() {
  sed -n "/=== $1:BEGIN ===/,/=== $1:END ===/p" "$SRC" | sed '1d;$d'
}

domain_map=$(extract DOMAIN_MAP)
lens_prompts=$(extract LENS_PROMPTS)
findings_schema=$(extract FINDINGS_SCHEMA)
collect_check=$(extract COLLECT_CHECK)
judge=$(extract JUDGE)
rounds=$(extract ROUNDS)

pass=0
fail=0

check_nonempty() {
  if [ -z "$2" ]; then
    echo "FAIL: extraction of $1 produced nothing -- its BEGIN/END markers in $SRC may have moved or been renamed" >&2
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
}

check_nonempty DOMAIN_MAP "$domain_map"
check_nonempty LENS_PROMPTS "$lens_prompts"
check_nonempty FINDINGS_SCHEMA "$findings_schema"
check_nonempty COLLECT_CHECK "$collect_check"
check_nonempty JUDGE "$judge"
check_nonempty ROUNDS "$rounds"

if [ "$fail" -gt 0 ]; then
  echo "FAIL: extraction sanity failed, aborting before running assertions ($fail failure(s))" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Assemble one Node script: the six extracted blocks (all plain top-level
# const/function declarations, no imports needed) followed by a static
# assertion harness. Extracted content is written byte-exact via printf, never
# interpolated into a heredoc, so nothing in it is re-parsed by the shell.
{
  printf '%s\n' "$domain_map"
  printf '%s\n' "$lens_prompts"
  printf '%s\n' "$findings_schema"
  printf '%s\n' "$collect_check"
  printf '%s\n' "$judge"
  printf '%s\n' "$rounds"
  cat <<'NODE'

let nodePass = 0
let nodeFail = 0
function assert(name, cond) {
  if (cond) {
    nodePass++
  } else {
    nodeFail++
    console.error(`FAIL: ${name}`)
  }
}
function assertThrows(name, fn, expectedSubstring) {
  try {
    fn()
    nodeFail++
    console.error(`FAIL: ${name} (expected a throw, none occurred)`)
  } catch (err) {
    if (expectedSubstring && !String(err.message).includes(expectedSubstring)) {
      nodeFail++
      console.error(`FAIL: ${name} (threw, but message missing "${expectedSubstring}": ${err.message})`)
    } else {
      nodePass++
    }
  }
}
function assertDoesNotThrow(name, fn) {
  try {
    fn()
    nodePass++
  } catch (err) {
    nodeFail++
    console.error(`FAIL: ${name} (unexpected throw: ${err.message})`)
  }
}
function deepEqSorted(a, b) {
  const x = JSON.stringify(Array.from(a).sort())
  const y = JSON.stringify(Array.from(b).sort())
  return x === y
}

const fs = require('fs')
const sha = (n) => n.toString(16).padStart(40, '0')
const emptyRed = { status: 'not-applicable', tests: [] }
const roundEntry = (n, count, lines, streak, extra = {}) => ({
  round: n, rerun: !!extra.rerun, comment_id: n, author_id: 12,
  created_at: '2026-09-24T00:00:00Z',
  record: { schema: 'review-adversarial-first/round/v1', round: n, head: extra.head || sha(n),
    patch_id: extra.patch || sha(n + 100), diff_lines: lines, verdict: extra.verdict || 'BORDERLINE',
    underlying_verdict: 'BORDERLINE', live: { P1: count, P2: 0, P3: 0 },
    findings: extra.findings || [], red_first: extra.red || emptyRed, streak,
    override: !!extra.override, rerun: !!extra.rerun, ledger_errors: [] },
})
const ledger = (rounds) => ({ target: { repo: 'o/r', pr: 1 }, rounds, ledger_errors: [], view: 'compact' })
// The Workflow runtime hands the caller only an error's message and stack, so a
// typed stop must carry its payload as exactly one trailing `payload=` line.
const payloadOf = (error) => {
  const lines = String(error).split('\n')
  if (lines.length !== 2 || !lines[1].startsWith('payload=')) return null
  try { return JSON.parse(lines[1].slice('payload='.length)) } catch { return null }
}
const candidate = (path, preFix, status, cases, reason = null, exempt = false) => ({
  path, pre_fix: preFix, status, command: 'bash test', reason, exempt,
  exempt_reason: exempt ? 'rename only' : null, cases,
})
const caseResult = (name, pf, hd, status) => ({ name, pre_fix: pf, head: hd, status })

// --- Domain map: security path detection ---------------------------------
assert('security: hooks path', deepEqSorted(matchDomains(['hooks/PreToolUse/git-guard.js']), ['security']))
assert('security: settings.json', deepEqSorted(matchDomains(['settings.json']), ['security']))
assert('security: credential in path', deepEqSorted(matchDomains(['scripts/rotate-credential.sh']), ['security']))
assert('security: guard in path', deepEqSorted(matchDomains(['scripts/dcg-guard-helpers.sh']), ['security']))
assert('security + ci: both match independently', deepEqSorted(matchDomains(['hooks/PreToolUse/x.js', '.github/workflows/y.yml']), ['ci', 'security']))

// --- Domain map: operational doctrine is not ordinary documentation -------
for (const file of [
  'CLAUDE.md', 'AGENTS.md', 'HARNESS.md',
  'CLAUDE.md', 'packages/service/AGENTS.md', 'docs/HARNESS.md',
  'claude.md', 'nested/Agents.MD', 'nested/hArNeSs.md',
  'harness/evidence-regime.md', 'nested/harness/routing.md',
  'harness/subdir/routing.md', 'nested/ClAuDe/HaRnEsS/routing.MD',
  'harness/README.md', 'harness/notes.md',
]) {
  assert(`security + docs: operational doctrine ${file}`,
    deepEqSorted(matchDomains([file]), ['docs', 'security']))
}
assert('security + docs: mixed ordinary docs and doctrine',
  deepEqSorted(matchDomains(['docs/notes/x.md', 'CLAUDE.md']), ['docs', 'security']))
assert('security + docs + ci: independent doctrine match and duplicate paths',
  deepEqSorted(matchDomains(['CLAUDE.md', 'CLAUDE.md', 'README.md', '.github/workflows/check.yml']),
    ['ci', 'docs', 'security']))
for (const file of [
  'MYCLAUDE.md', 'XAGENTS.md', 'docs/MYHARNESS.md', 'HARNESS-notes.md',
  'CLAUDE.md/notes.md', 'docs/harness-notes.md', 'harness-extra/notes.md',
  'xharness/notes.md', 'README.md', 'README.md',
  'memory/notes.md', 'docs/proposals/routing.md',
]) {
  assert(`docs-only: ordinary documentation or doctrine lookalike ${file}`,
    deepEqSorted(matchDomains([file]), ['docs']))
}
assert('no doctrine match: instruction backup and non-Markdown harness file',
  deepEqSorted(matchDomains(['CLAUDE.md.bak', 'harness/tool.js']), []))
assert('security + docs: existing permission rule still applies to ordinary docs',
  deepEqSorted(matchDomains(['docs/permission-guide.md']), ['docs', 'security']))

// --- Domain map: docs-only detection --------------------------------------
assert('docs-only: single md file', deepEqSorted(matchDomains(['docs/notes/x.md']), ['docs']))
assert('docs-only: multiple md files', deepEqSorted(matchDomains(['docs/notes/x.md', 'README.md']), ['docs']))
assert('not docs-only: md + ci path', deepEqSorted(matchDomains(['README.md', '.github/workflows/x.yml']), ['ci', 'docs']))
assert('ci-only: no docs, no security', deepEqSorted(matchDomains(['.github/workflows/harness-tests.yml', 'tests/foo.test.sh']), ['ci']))
assert('no domain match', deepEqSorted(matchDomains(['bin/unrelated-tool']), []))
assert('empty file list', deepEqSorted(matchDomains([]), []))

// --- Findings schema: shape sanity -----------------------------------------
assert('schema requires findings', FINDINGS_SCHEMA.required.includes('findings'))
assert('schema caps findings (no silent unbounded fan-out)', typeof FINDINGS_SCHEMA.properties.findings.maxItems === 'number' && FINDINGS_SCHEMA.properties.findings.maxItems > 0)
assert('schema severity enum is exactly P1/P2/P3', deepEqSorted(FINDINGS_SCHEMA.properties.findings.items.properties.severity.enum, ['P1', 'P2', 'P3']))
assert('schema item requires title/severity/refuted', ['title', 'severity', 'refuted'].every((k) => FINDINGS_SCHEMA.properties.findings.items.required.includes(k)))
assert('schema requires diff_lines_read (lens-coverage proof, #1307)', FINDINGS_SCHEMA.required.includes('diff_lines_read'))
assert('schema diff_lines_read is an integer', FINDINGS_SCHEMA.properties.diff_lines_read.type === 'integer')

// --- Lens prompts: diff-file reference, not inline diff text (#1307) -------
// The lens no longer receives the diff pasted into the prompt -- it gets the
// file path + line count and must Read the file itself. A fixture path/count
// stand in for a real Collect-written diff file.
const fixtureDiffPath = '/tmp/review-adversarial-first-fixture-abc123/diff.patch'
const fixtureDiffLineCount = 9

const noOpLens = LENSES.find((l) => l.id === 'no-op-or-regression')
assert('no-op-or-regression lens exists', !!noOpLens)
const prompt = buildLensPrompt(noOpLens, '148', 'StartupBros-com/hov-stack', fixtureDiffPath, fixtureDiffLineCount)
assert('prompt embeds the diff file path', prompt.includes(fixtureDiffPath))
assert('prompt embeds the diff line count', prompt.includes(String(fixtureDiffLineCount)))
assert('prompt instructs reading the whole file, not a partial read', prompt.includes('Read the ENTIRE file') && prompt.includes('partial read'))
assert('prompt no longer inlines diff text (no fenced diff block)', !prompt.includes('```diff'))
assert('prompt asks the lens to report diff_lines_read', prompt.includes('diff_lines_read'))
assert('prompt carries the refute-by-default directive', prompt.includes('Default to refuted=true when uncertain'))
assert('prompt carries the inert-guard hunt instruction', prompt.includes('guard whose condition can never fire'))
assert('prompt embeds target and repo', prompt.includes('148') && prompt.includes('StartupBros-com/hov-stack'))
assert('prompt cites evidence-regime.md', prompt.includes('evidence-regime.md'))

// --- Collect check: rejects a transcribed/partial diff, accepts a real file
// (dotfiles #1307 -- 11 of 33 real runs returned a path, prose, or a
// truncated diff into diff_text and the old schema silently accepted it).
assertDoesNotThrow('collect check accepts a valid file-backed diff', () =>
  validateCollected({ diff_path: '/tmp/review-abc123/diff.patch', diff_line_count: 42, first_line: 'diff --git a/foo.js b/foo.js' })
)
assertThrows(
  'collect check rejects a bare path string as first_line',
  () => validateCollected({ diff_path: '/tmp/review-abc123/diff.patch', diff_line_count: 42, first_line: '/tmp/review-abc123/diff.patch' }),
  "first_line does not start with 'diff --git'"
)
assertThrows(
  'collect check rejects a prose summary as first_line',
  () => validateCollected({ diff_path: '/tmp/review-abc123/diff.patch', diff_line_count: 42, first_line: 'This diff renames the auth helper and updates its callers.' }),
  "first_line does not start with 'diff --git'"
)
assertThrows(
  'collect check rejects an empty first_line',
  () => validateCollected({ diff_path: '/tmp/review-abc123/diff.patch', diff_line_count: 42, first_line: '' }),
  "first_line does not start with 'diff --git'"
)
assertThrows(
  'collect check rejects a truncated-comment first_line (the old truncation behavior)',
  () => validateCollected({ diff_path: '/tmp/review-abc123/diff.patch', diff_line_count: 4000, first_line: '# diff truncated at 4000 lines' }),
  "first_line does not start with 'diff --git'"
)
assertThrows(
  'collect check rejects a relative diff_path',
  () => validateCollected({ diff_path: 'review-abc123/diff.patch', diff_line_count: 10, first_line: 'diff --git a/x b/x' }),
  'absolute diff_path'
)
assertThrows(
  'collect check rejects a non-positive diff_line_count',
  () => validateCollected({ diff_path: '/tmp/review-abc123/diff.patch', diff_line_count: 0, first_line: 'diff --git a/x b/x' }),
  'positive integer diff_line_count'
)
assertThrows(
  'collect check rejects a non-integer diff_line_count',
  () => validateCollected({ diff_path: '/tmp/review-abc123/diff.patch', diff_line_count: 4.5, first_line: 'diff --git a/x b/x' }),
  'positive integer diff_line_count'
)

// --- Judge: lens coverage gate (dotfiles #1307) -----------------------------
// A verdict must not be computed on a partial read: every lens must have read
// at least the collected `wc -l` count. The Read tool's last line number equals
// that count for a newline-terminated file and exceeds it by one otherwise, so
// no downward tolerance is needed.
const expectedLensIds = LENSES.map((l) => l.id)

assertDoesNotThrow('full lens coverage passes', () =>
  checkLensCoverage(
    [
      { lens: 'own-doctrine', findings: [], diff_lines_read: 120 },
      { lens: 'strongest-lever', findings: [], diff_lines_read: 120 },
      { lens: 'no-op-or-regression', findings: [], diff_lines_read: 121 },
    ],
    expectedLensIds,
    120
  )
)

assertThrows(
  'a lens that skipped only the final line fails coverage',
  () =>
    checkLensCoverage(
      [
        { lens: 'own-doctrine', findings: [], diff_lines_read: 120 },
        { lens: 'strongest-lever', findings: [], diff_lines_read: 120 },
        { lens: 'no-op-or-regression', findings: [], diff_lines_read: 119 },
      ],
      expectedLensIds,
      120
    ),
  'no-op-or-regression'
)

assertThrows(
  'one under-read lens fails coverage and is named in the error',
  () =>
    checkLensCoverage(
      [
        { lens: 'own-doctrine', findings: [], diff_lines_read: 120 },
        { lens: 'strongest-lever', findings: [], diff_lines_read: 40 },
        { lens: 'no-op-or-regression', findings: [], diff_lines_read: 120 },
      ],
      expectedLensIds,
      120
    ),
  'strongest-lever'
)

assertThrows(
  'a missing lens fails coverage and is named (a dead lens must not yield CLEAN)',
  () =>
    checkLensCoverage(
      [
        { lens: 'own-doctrine', findings: [], diff_lines_read: 120 },
        { lens: 'no-op-or-regression', findings: [], diff_lines_read: 120 },
      ],
      expectedLensIds,
      120
    ),
  'strongest-lever'
)

assertThrows(
  'a lens with a null diff_lines_read (agent() returned null) fails coverage',
  () =>
    checkLensCoverage(
      [
        { lens: 'own-doctrine', findings: [], diff_lines_read: 120 },
        { lens: 'strongest-lever', findings: [], diff_lines_read: null },
        { lens: 'no-op-or-regression', findings: [], diff_lines_read: 120 },
      ],
      expectedLensIds,
      120
    ),
  'strongest-lever'
)

// --- Judge: inert-guard finding corroborated by 2 lenses, unrefuted -> DIRTY, deduped to 1
const inertGuardResults = [
  { lens: 'own-doctrine', findings: [] },
  {
    lens: 'strongest-lever',
    findings: [{ title: 'Inert guard: timeout regex requires unit suffix, pg_dur_secs accepts bare digits', file: 'scripts/pg-dur-check.sh', line: 12, severity: 'P1', refuted: false, rationale: 'valid input misjudged' }],
  },
  {
    lens: 'no-op-or-regression',
    findings: [{ title: 'inert guard: timeout regex requires a unit suffix, but pg_dur_secs also accepts bare digits', file: 'scripts/pg-dur-check.sh', line: 12, severity: 'P1', refuted: false, rationale: 'duplicate report' }],
  },
]
const dirtyJudged = judgeFindings(inertGuardResults, [])
assert('inert-guard fixture judged DIRTY', dirtyJudged.verdict === 'DIRTY')
assert('inert-guard fixture deduped to 1 finding', dirtyJudged.findings.length === 1)
assert('inert-guard dedup recorded both lenses', dirtyJudged.findings[0].lenses.length === 2)

// --- Judge: same finding, all lenses refute -> CLEAN
const cleanResults = [
  { lens: 'own-doctrine', findings: [] },
  { lens: 'strongest-lever', findings: [{ title: 'looked risky but is fine', file: 'a.js', line: 1, severity: 'P1', refuted: true }] },
  { lens: 'no-op-or-regression', findings: [] },
]
assert('all-refuted P1 fixture judged CLEAN', judgeFindings(cleanResults, []).verdict === 'CLEAN')

// --- Judge: only an unrefuted P2 present -> BORDERLINE
const borderlineResults = [
  { lens: 'own-doctrine', findings: [{ title: 'minor doctrine drift', file: 'b.md', line: 3, severity: 'P2', refuted: false }] },
]
assert('unrefuted P2 fixture judged BORDERLINE', judgeFindings(borderlineResults, []).verdict === 'BORDERLINE')

// --- Judge: refuted is AND-ed across duplicates, not OR-ed --
// one lens refutes, the other does not -> the finding stays LIVE (still DIRTY)
const splitRefutedResults = [
  { lens: 'own-doctrine', findings: [{ title: 'disputed finding', file: 'c.js', line: 5, severity: 'P1', refuted: true }] },
  { lens: 'strongest-lever', findings: [{ title: 'disputed finding', file: 'c.js', line: 5, severity: 'P1', refuted: false }] },
]
const splitJudged = judgeFindings(splitRefutedResults, [])
assert('split-refuted duplicate stays live (AND, not OR)', splitJudged.findings.length === 1 && splitJudged.findings[0].refuted === false)
assert('split-refuted duplicate keeps verdict DIRTY', splitJudged.verdict === 'DIRTY')

// --- Judge: the strictest unrefuted report at a shared file:line sets the
// severity, in either lens order (refute lens at 6f6f3082: the first lens's won)
const sharedLine = (first, second) => [
  { lens: 'own-doctrine', findings: [{ title: 'shared line', file: 'd.js', line: 5, rationale: 'first', ...first }] },
  { lens: 'strongest-lever', findings: [{ title: 'shared line, stricter', file: 'd.js', line: 5, rationale: 'second', ...second }] },
]
const laterStricter = judgeFindings(sharedLine({ severity: 'P3', refuted: false }, { severity: 'P1', refuted: false }), [])
assert('a live P1 reported after a live P3 at the same line stays P1 (DIRTY)',
  laterStricter.findings.length === 1 && laterStricter.findings[0].severity === 'P1' &&
  laterStricter.findings[0].title === 'shared line, stricter' && laterStricter.findings[0].rationale === 'second' &&
  laterStricter.verdict === 'DIRTY')
const refutedFirst = judgeFindings(sharedLine({ severity: 'P1', refuted: true }, { severity: 'P3', refuted: false }), [])
assert('a refuted P1 reported first does not revive at P1 over a live P3',
  refutedFirst.findings.length === 1 && refutedFirst.findings[0].severity === 'P3' &&
  !refutedFirst.findings[0].refuted && refutedFirst.verdict === 'BORDERLINE')
const laterWeaker = judgeFindings(sharedLine({ severity: 'P1', refuted: false }, { severity: 'P3', refuted: false }), [])
assert('a live P3 reported after a live P1 does not lower it',
  laterWeaker.findings[0].severity === 'P1' && laterWeaker.findings[0].title === 'shared line')
const refutedStricter = judgeFindings(sharedLine({ severity: 'P3', refuted: false }, { severity: 'P1', refuted: true }), [])
assert('a refuted stricter report does not raise a live one',
  refutedStricter.findings[0].severity === 'P3' && !refutedStricter.findings[0].refuted &&
  refutedStricter.verdict === 'BORDERLINE')
// A title-keyed merge (no line) takes the file of the report it adopts (refute lens at 1c74d45a).
const titleKeyed = judgeFindings([
  { lens: 'own-doctrine', findings: [{ title: 'Missing guard', line: 3, severity: 'P3', refuted: false }] },
  { lens: 'strongest-lever', findings: [{ title: 'missing guard', file: 'b.js', severity: 'P1', refuted: false }] },
  { lens: 'no-op-or-regression', findings: [{ title: 'missing guard!', file: 'a.js', severity: 'P1', refuted: false }] },
], [])
assert('a title-keyed merge records the adopted report\'s file and line, not the first report\'s',
  titleKeyed.findings.length === 1 && titleKeyed.findings[0].severity === 'P1' &&
  titleKeyed.findings[0].file === 'b.js' && titleKeyed.findings[0].line === null)

// --- Judge: touched_domains passes through untouched
assert('touched_domains passthrough', deepEqSorted(judgeFindings([], ['security', 'ci']).touched_domains, ['ci', 'security']))

// --- Judge: no lens results at all -> CLEAN, empty findings
const emptyJudged = judgeFindings([], [])
assert('empty lens results judged CLEAN', emptyJudged.verdict === 'CLEAN')
assert('empty lens results produce no findings', emptyJudged.findings.length === 0)

// --- Rounds: all-history identities, sticky baselines, scoring and RED ----
const one = [roundEntry(1, 3, 400, 0)]
const two = [...one, roundEntry(2, 3, 460, 1)]
const historyErrors = [
  { comment_id: 11, kind: 'invalid-record', reason: 'untrusted author in fenced JSON' },
  { comment_id: 12, kind: 'invalid-author', reason: 'missing or invalid author user.id' },
  { comment_id: 13, reason: 'untrusted author ID 999' }, // legacy missing kind is not evidence of trust
]
for (const problem of historyErrors) {
  try {
    validateLedger({ ...ledger([]), ledger_errors: [problem] }, 'o/r', 1)
    assert(`ledger refuses ${JSON.stringify(problem)} instead of treating it as round one`, false)
  } catch (error) {
    assert(`ledger refuses ${JSON.stringify(problem)} with exact typed error`,
      error.code === 'ledger-history-incomplete' && sameData(error.errors, [problem]))
    assert(`ledger-history-incomplete for ${JSON.stringify(problem)} carries its payload in the message`,
      String(error).split('\n')[0] ===
        'Error: ledger-history-incomplete: marker history has invalid or unknown trust' &&
      sameData(payloadOf(error), { code: 'ledger-history-incomplete', ledger_errors: [problem] }))
  }
}
assert('workflow builds typed stops with a payload line', typeof typedStop === 'function')
if (typeof typedStop === 'function') {
  const stop = typedStop('summary\nwith break', { code: 'x', title: 'a\u2028b\u0085c\nd' }, { extra: 1 })
  assert('a typed stop stays one summary line plus one payload line for any line splitter',
    String(stop).split(/\r\n|[\n\r\v\f\x1c-\x1e\u0085\u2028\u2029]/).length === 2 &&
    sameData(payloadOf(stop), { code: 'x', title: 'a\u2028b\u0085c\nd' }) && stop.code === 'x' && stop.extra === 1)
}
const untrustedNoise = { comment_id: 14, kind: 'untrusted-author', reason: 'untrusted author ID 999' }
assertDoesNotThrow('known untrusted numeric author noise is nonblocking', () =>
  validateLedger({ ...ledger([]), ledger_errors: [untrustedNoise] }, 'o/r', 1))
const live = [{ file: 'a.js', title: 'defect', severity: 'P1', refuted: false },
  { file: 'a.js', title: 'second defect', severity: 'P2', refuted: false },
  { file: 'b.js', title: 'another defect', severity: 'P1', refuted: false },
  { file: 'c.js', title: 'nit', severity: 'P3', refuted: false }]
let score = scoreRound(two, sha(3), sha(103), 520, live)
assert('third non-shrinking scored round freezes', score.frozen && score.streak === 2)
assert('residuals group by file with highest severity and titles',
  score.residual_classes.length === 2 && score.residual_classes[0].severity === 'P1' &&
  score.residual_classes[0].titles.length === 2)
assert('diff shrink resets streak even when count grows',
  scoreRound(two, sha(3), sha(103), 459, live).streak === 0)
// R6/KTD4: an equal diff size is non-shrinking churn, the boundary side of 459.
assert('equal diff size is non-shrinking churn',
  scoreRound(two, sha(3), sha(103), 460, live).frozen && scoreRound(two, sha(3), sha(103), 460, live).streak === 2)
assert('count shrink resets streak even when diff grows',
  scoreRound(two, sha(3), sha(103), 520, live.slice(0, 2)).streak === 0)
assert('count-only churn with growing diff freezes',
  scoreRound([...one, roundEntry(2, 3, 460, 1)], sha(3), sha(103), 520, live).frozen)
assert('zero live count clears the streak', scoreRound(two, sha(3), sha(103), 520, []).streak === 0)
// PN3 (#1362): a converging history (stable diff, live P1+P2 falling to zero and
// staying there) never freezes at any round. Only the zero-to-zero rounds need
// scoreRound's `count > 0` guard; the fall-to-zero case above resets on
// `count >= previousCount` alone, so it cannot catch that guard's removal.
{
  const converging = [3, 1, 0, 0, 0]
  const liveOf = (count) => live.filter((f) => f.severity !== 'P3').slice(0, count)
  let convergingHistory = []
  const convergingScores = converging.map((count, i) => {
    const s = scoreRound(convergingHistory, sha(i + 1), sha(i + 101), 400, liveOf(count))
    convergingHistory = [...convergingHistory, roundEntry(i + 1, count, 400, s.streak)]
    return s
  })
  assert('PN3: a converging history with a stable diff never freezes at any round',
    convergingScores.every((s) => !s.frozen && s.streak === 0))
  assert('PN3: zero-to-zero rounds with a stable diff are not churn',
    convergingScores.slice(3).every((s) => s.streak === 0 && s.residual_classes.length === 0))
}
assert('P3-only findings cannot score churn',
  scoreRound(two, sha(3), sha(103), 520, live.slice(-1)).streak === 0)
assert('same head reruns without scoring', scoreRound(two, sha(1), sha(199), 700, live).streak === 1)
assert('same previous scored patch reruns without scoring',
  scoreRound(two, sha(9), sha(102), 700, live).rerun)
assert('historical patch recurrence after another scored patch is NOT a rerun',
  !scoreRound(two, sha(9), sha(101), 700, live).rerun)
// Round 2 (outside the last 32) first ran the test against round 1's head; a
// carried baseline is always some prior trusted head (review finding #1).
const over32 = Array.from({ length: 35 }, (_, i) => roundEntry(i + 1, 2, 100 + i, 0,
  { red: i === 1 ? { status: 'verified', tests: [candidate('tests/sticky.test.sh', sha(1),
    'ran', [caseResult('test_sticky', 'fail', 'pass', 'verified')])] } : emptyRed }))
const selected = { previous_head: sha(35), head_sha: sha(36), base_sha: sha(90),
  changed_paths: ['tests/sticky.test.sh'], blob_facts: [{ path: 'tests/sticky.test.sh',
    previous_blob: 'blob old', head_blob: 'blob new' }], error: null }
assert('older-than-32 baseline survives without resetting on rebase',
  buildManifest(['tests/sticky.test.sh'], over32, selected, sha(36), sha(90))
    .manifest[0].pre_fix === sha(1))
assert('all 35 heads matter to any-seen-head reruns', scoreRound(over32, sha(1), sha(201), 900, live).rerun)
assert('first-round tests remain outside RED', buildManifest(['tests/sticky.test.sh'], [], selected,
  sha(36), sha(90)).manifest.length === 0)
assertThrows('missing blob evidence cannot fabricate selection', () =>
  buildManifest(['tests/sticky.test.sh'], over32, { ...selected, blob_facts: [] }, sha(36), sha(90)), 'blob facts')
// Live PR #1390 round 2: Collect also returned a fact for a changed non-test
// file under tests, which is not a RED candidate.
const withNonTestFact = { ...selected, changed_paths: ['tests/sticky.test.sh', 'tests/suite-paths.yml'],
  blob_facts: [...selected.blob_facts, { path: 'tests/suite-paths.yml',
    previous_blob: 'blob yml-old', head_blob: 'blob yml-new' }] }
assert('extra blob fact for a changed non-test path does not block RED selection',
  sameData(buildManifest(['tests/sticky.test.sh', 'tests/suite-paths.yml'], over32, withNonTestFact,
    sha(36), sha(90)).manifest, [{ path: 'tests/sticky.test.sh', pre_fix: sha(1) }]))
assertThrows('duplicate blob facts remain contradictory', () =>
  buildManifest(['tests/sticky.test.sh'], over32, { ...selected,
    blob_facts: [...selected.blob_facts, ...selected.blob_facts] }, sha(36), sha(90)), 'blob facts')
assertThrows('a blob fact for a path outside changed_paths is contradictory', () =>
  buildManifest(['tests/sticky.test.sh'], over32, { ...selected, blob_facts: [...selected.blob_facts,
    { path: 'tests/suite-paths.yml', previous_blob: 'blob a', head_blob: 'blob b' }] },
  sha(36), sha(90)), 'blob facts')
assertThrows('unchanged blob for a selected test cannot fabricate selection', () =>
  buildManifest(['tests/sticky.test.sh'], over32, { ...selected, blob_facts: [{ path: 'tests/sticky.test.sh',
    previous_blob: 'blob same', head_blob: 'blob same' }] }, sha(36), sha(90)), 'blob facts')
assertThrows('mixed selection head rejected', () =>
  buildManifest(['tests/sticky.test.sh'], over32, { ...selected, head_sha: sha(5) }, sha(36), sha(90)), 'mixed')
assertThrows('selection diffed from a head other than the last recorded one is rejected', () =>
  buildManifest(['tests/sticky.test.sh'], over32, { ...selected, previous_head: sha(34) }, sha(36), sha(90)), 'mixed')
assertThrows('selection captured against a different base is rejected', () =>
  buildManifest(['tests/sticky.test.sh'], over32, { ...selected, base_sha: sha(91) }, sha(36), sha(90)), 'mixed')
// Review finding #1: anyone with write access can edit a trusted marker comment,
// so a carried baseline is only ever a prior trusted head (red-first.sh
// re-derives Red-first-base trailers itself on every run).
const carriedPath = 'tests/x.test.sh'
const carriedManifest = (rounds) => {
  const previous = rounds.at(-1).record.head
  const head = sha(rounds.length + 1)
  return buildManifest([carriedPath], rounds, { previous_head: previous, head_sha: head, base_sha: sha(90),
    changed_paths: [carriedPath], blob_facts: [{ path: carriedPath, previous_blob: 'blob a', head_blob: 'blob b' }],
    error: null }, head, sha(90)).manifest
}
const carriedRed = (tests, unchanged) => ({ status: 'verified', tests, unchanged })
const carriedRan = (preFix) => candidate(carriedPath, preFix, 'ran', [caseResult('c', 'fail', 'pass', 'verified')])
assert('a carried unchanged ref name is never a pre-fix tree; the latest recorded head is used',
  sameData(carriedManifest([roundEntry(1, 0, 10, 0), roundEntry(2, 0, 20, 0, { red: carriedRed([],
    [{ path: carriedPath, pre_fix: 'refs/remotes/origin/attacker-branch' }]) })]),
  [{ path: carriedPath, pre_fix: sha(2) }]))
assert('a carried 40-hex pre-fix that is no prior head falls back to the earlier legitimate carried head',
  sameData(carriedManifest([roundEntry(1, 0, 10, 0), roundEntry(2, 0, 20, 0, { red: carriedRed([carriedRan(sha(1))], []) }),
    roundEntry(3, 0, 30, 0, { red: carriedRed([carriedRan(sha(77))], []) })]), [{ path: carriedPath, pre_fix: sha(1) }]))
assert('a legitimate unchanged carry of an earlier prior head is honored',
  sameData(carriedManifest([roundEntry(1, 0, 10, 0), roundEntry(2, 0, 20, 0, { red: carriedRed([],
    [{ path: carriedPath, pre_fix: sha(1) }]) }), roundEntry(3, 0, 30, 0)]), [{ path: carriedPath, pre_fix: sha(1) }]))
// Review finding #4: a selection-error round records its unverified previous
// head as the pre-fix of every PR test path, changed or not.
const beforeError = [roundEntry(1, 0, 10, 0), roundEntry(2, 0, 20, 0)]
const errorReport = selectionUnverifiable([carriedPath], beforeError, sha(3), sha(90), 'git fetch: unavailable')
const errorRound = roundEntry(3, 0, 30, 0, { red: composeRedFirst(errorReport, redFirstFindings(errorReport), true) })
assert('selection-error fixture records its previous head for an unchanged PR test path',
  !!errorRound.record.red_first.selection_error && errorRound.record.red_first.tests[0].pre_fix === sha(2))
assert('a test first changed after a selection-error round baselines on the latest recorded head',
  sameData(carriedManifest([...beforeError, errorRound]), [{ path: carriedPath, pre_fix: sha(3) }]))
// Inward re-vet at b137793b: a first sight that came back unverifiable (round 1's
// head rebased away) keeps the baseline. The latest head would start past the
// round that added the test, and its never-red cases would go unattributed.
const unverifiedFirst = [roundEntry(1, 0, 10, 0), roundEntry(2, 0, 20, 0, { red: { status: 'unverifiable',
  unchanged: [], tests: [candidate(carriedPath, sha(1), 'unverifiable', [],
    `pre-fix ${sha(1)} is not an ancestor of head ${sha(2)}`)] } })]
assert('an unverifiable first sight keeps the baseline instead of falling back to the latest head',
  sameData(carriedManifest(unverifiedFirst), [{ path: carriedPath, pre_fix: sha(1) }]))
const trailerAfterUnverified = [...unverifiedFirst,
  roundEntry(3, 0, 30, 0, { red: carriedRed([carriedRan(sha(2))], []) })]
assert('a later trailer run never replaces an unverifiable first sight',
  sameData(carriedManifest(trailerAfterUnverified), [{ path: carriedPath, pre_fix: sha(1) }]))
const lost = selectionUnverifiable(['docs/a.md'], one, sha(5), sha(90), 'git fetch origin HEAD: unavailable')
assert('unfetchable history creates P2 even without known test candidates',
  lost.selection_error.includes('git fetch') && redFirstFindings(lost).some((f) => f.severity === 'P2'))
// AE8/R3: a failed RED selection is recorded as such, never a silent not-applicable skip.
assert('selection failure is recorded unverifiable',
  composeRedFirst(lost, redFirstFindings(lost), true).status === 'unverifiable')
const testPath = 'tests/suite.test.sh'
const report = { head: sha(4), base_branch: sha(90), overlay: [testPath], exempt: [], unchanged: [],
  requested: [{ path: testPath, pre_fix: sha(1) }],
  tests: [candidate(testPath, sha(1), 'ran', [
    caseResult('red_case', 'fail', 'pass', 'verified'),
    caseResult('unreached_case', 'pass', 'pass', 'never-red')])] }
assertDoesNotThrow('actual runner report shape partitions manifest', () =>
  checkRedReport(report, [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)))
assertThrows('missing requested baseline cannot satisfy manifest', () =>
  checkRedReport({ ...report, requested: undefined }, [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)),
  'requested')
assertThrows('wrong requested baseline cannot satisfy manifest even if effective test matches', () =>
  checkRedReport({ ...report, requested: [{ path: testPath, pre_fix: sha(4) }] },
    [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)), 'requested')
assertThrows('wrong manifest pinned to head cannot disappear into unchanged with no finding', () =>
  checkRedReport({ ...report, requested: [{ path: testPath, pre_fix: sha(4) }], tests: [],
    unchanged: [{ path: testPath, pre_fix: sha(4) }] },
    [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)), 'requested')
for (const requested of [[], [...report.requested, ...report.requested],
  [...report.requested, { path: 'tests/extra.test.sh', pre_fix: sha(1) }],
  [{ path: testPath, pre_fix: null }]]) {
  assertThrows(`incomplete, duplicate, extra or malformed requested baseline ${JSON.stringify(requested)} fails`, () =>
    checkRedReport({ ...report, requested }, [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)),
  'requested')
}
assertDoesNotThrow('requested baseline remains distinct from corrected effective baseline', () =>
  checkRedReport({ ...report, tests: [candidate(testPath, sha(2), 'ran',
    [caseResult('red_case', 'fail', 'pass', 'verified')])] },
  [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)))
assertDoesNotThrow('unchanged effective baseline may be corrected without losing requested binding', () =>
  checkRedReport({ ...report, tests: [], unchanged: [{ path: testPath, pre_fix: sha(2) }] },
    [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)))
assertDoesNotThrow('requested order does not affect manifest correspondence', () => {
  const other = 'tests/second.test.sh'
  checkRedReport({ ...report, requested: [{ path: other, pre_fix: sha(3) }, ...report.requested],
    unchanged: [{ path: other, pre_fix: sha(3) }] },
    [{ path: testPath, pre_fix: sha(1) }, { path: other, pre_fix: sha(3) }], sha(4), sha(90))
})
assertThrows('unexplained missing candidate is a stage failure', () =>
  checkRedReport({ ...report, tests: [], unchanged: [] }, [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)), 'partition')
assertThrows('unexpected runner path is a stage failure', () =>
  checkRedReport({ ...report, requested: [] }, [], sha(4), sha(90)), 'partition')
assertThrows('contradictory case status fails visibly', () =>
  checkRedReport({ ...report, tests: [candidate(testPath, sha(1), 'ran',
    [caseResult('x', 'pass', 'pass', 'verified')])] }, [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90)), 'contradicts')
// U1 validate_record accepts `cases: []` for a ran path, so these guards are
// the only barrier between a runner or transport regression and "verified".
const redCheck = (tests, extra = {}) => () =>
  checkRedReport({ ...report, tests, ...extra }, [{ path: testPath, pre_fix: sha(1) }], sha(4), sha(90))
assertThrows('a ran path with no named cases is not RED proof', redCheck([candidate(testPath, sha(1), 'ran', [])]),
  `RedFirst ${testPath} has no named cases`)
assertThrows('a whole-file result presented as a named ran case contradicts its path status',
  redCheck([candidate(testPath, sha(1), 'ran', [caseResult(testPath, 'fail', 'pass', 'verified')])]),
  `RedFirst ${testPath}::${testPath} contradicts path/revision statuses`)
assertThrows('an exemption without a reason is malformed',
  redCheck([{ ...candidate(testPath, sha(1), 'ran', [caseResult('red_case', 'fail', 'pass', 'verified')], null, true),
    exempt_reason: null }], { exempt: [{ path: testPath, reason: null }] }),
  'RedFirst returned a malformed test result')
assertThrows('an unsupported path without a reason fails',
  redCheck([candidate(testPath, sha(1), 'unsupported', [caseResult(testPath, 'unsupported', 'unsupported', 'unsupported')])]),
  `RedFirst ${testPath} lacks a failure reason`)
assertThrows('an unverifiable path without a reason fails',
  redCheck([candidate(testPath, sha(1), 'unverifiable', [])]), `RedFirst ${testPath} lacks a failure reason`)
assertThrows('an unverifiable path cannot carry case results',
  redCheck([candidate(testPath, sha(1), 'unverifiable', [caseResult('c', 'unresolved', 'unresolved', 'inconclusive')],
    'pre-fix fetch failed')]), `RedFirst ${testPath} has cases for an unverifiable path`)
assertThrows('a per-path exemption missing from the exemption list conflicts',
  redCheck([candidate(testPath, sha(1), 'ran', [caseResult('red_case', 'fail', 'pass', 'verified')], null, true)]),
  'RedFirst exemption list conflicts with per-path evidence')
const red = redFirstFindings(report)
const verifiedOnly = { ...report, tests: [candidate(testPath, sha(1), 'ran',
  [caseResult('red_case', 'fail', 'pass', 'verified')])] }
assert('all runnable cases verified yields verified aggregate',
  composeRedFirst(verifiedOnly, redFirstFindings(verifiedOnly), true).status === 'verified')
assert('named verified case generates no finding', red.length === 1)
assert('named never-red carries case and exact revisions in P1 finding',
  red[0].severity === 'P1' && red[0].title.includes('::unreached_case') &&
  red[0].rationale.includes(sha(1)) && red[0].rationale.includes(sha(4)))
assert('RED P1 makes clean lenses DIRTY before verdict',
  computeVerdict(mergeRedFindings(judgeFindings([], []).findings, red)) === 'DIRTY')
assert('non-exempt never-red is aggregate never-red', composeRedFirst(report, red, true).status === 'never-red')
assert('no runnable paths is not proof of verified RED',
  composeRedFirst({ ...report, tests: [], unchanged: [] }, [], true).status === 'not-applicable' &&
  composeRedFirst({ ...report, tests: [], unchanged: [{ path: testPath, pre_fix: sha(1) }] }, [], true)
    .status === 'not-applicable')
const refutedLens = [{ ...red[0], severity: 'P3', refuted: true, lenses: ['own-doctrine'] }]
assert('refuted lower-severity lens duplicate cannot suppress RED P1',
  computeVerdict(mergeRedFindings(refutedLens, red)) === 'DIRTY')
const outcomes = [
  ['inconclusive', 'unresolved', 'pass', 'P2'], ['fails-at-head', 'pass', 'fail', 'P2'],
  ['never-red', 'pass', 'pass', 'P3'],
]
for (const [status, pf, hd, severity] of outcomes) {
  const test = candidate(testPath, sha(1), 'ran', [caseResult('c', pf, hd, status)],
    status === 'inconclusive' ? 'suite aborted' : null, true)
  const findings = redFirstFindings({ ...report, tests: [test] })
  assert(`exempt ${status} maps to ${severity}`, findings.length === 1 &&
    findings[0].severity === severity && findings[0].rationale.includes('rename only'))
  if (status === 'never-red') assert('exempt-only never-red remains aggregate verified',
    composeRedFirst({ ...report, tests: [test] }, findings, true).status === 'verified')
}
for (const status of ['unsupported', 'unverifiable']) {
  assert(`${status} path maps to P2 even exempt`, redFirstFindings({ ...report,
    tests: [candidate(testPath, sha(1), status, [], 'source unavailable', true)]
  })[0].severity === 'P2')
}
const synthetic = candidate(testPath, sha(1), 'file-level',
  [caseResult(testPath, 'pass', 'pass', 'never-red')], 'case names missing', true)
assert('file-level synthetic never-red is P2 rather than P3/P1',
  redFirstFindings({ ...report, tests: [synthetic] }).length === 1 &&
  redFirstFindings({ ...report, tests: [synthetic] })[0].severity === 'P2')
const mixed = candidate(testPath, sha(1), 'file-level', [
  caseResult('real', 'pass', 'pass', 'never-red'),
  caseResult(testPath, 'unresolved', 'unresolved', 'inconclusive')], 'dynamic remainder')
assert('mixed file-level keeps named-case P1 and one fallback P2',
  deepEqSorted(redFirstFindings({ ...report, tests: [mixed] }).map((f) => f.severity), ['P1', 'P2']))
const collected = { head_sha: sha(4), patch_id: sha(104), diff_lines: 520,
  ledger: ledger(two) }
const combined = mergeRedFindings(live.map((f) => ({ ...f, lenses: ['lens'] })), red)
const recordFrozen = composeRecord(two, collected, combined, 'DIRTY',
  composeRedFirst(report, red, true), false).record
const recordOverride = composeRecord(two, collected, combined, 'DIRTY',
  composeRedFirst(report, red, true), true).record
assert('frozen stores residuals and underlying verdict', recordFrozen.verdict === 'FROZEN' &&
  recordFrozen.underlying_verdict === 'DIRTY' && recordFrozen.residual_classes.length >= 1)
assert('override stores underlying verdict WITHOUT residual_classes', recordOverride.verdict === 'DIRTY' &&
  recordOverride.override && !Object.hasOwn(recordOverride, 'residual_classes'))
const proseCollected = { ...collected, base_sha: sha(1), patch_sha256: 'ab'.repeat(32),
  diff_line_count: 20, ledger: ledger([]) }
const proseLenses = LENSES.map(({ id }) => ({ lens: id, diff_lines_read: 20, findings: [],
  ordinary_prose: { eligible: true, evidence: 'Inspected package scripts and docs renderer at captured head: guide is human-only, no input consumers.' } }))
const proseRecord = (lenses = proseLenses, override = false, c = proseCollected, verdict = 'CLEAN') =>
  composeRecord([], c, [], verdict, emptyRed, override, [], lenses).record
assert('all existing lenses attest ordinary prose with revision binding',
  proseRecord().ordinary_prose?.base === sha(1) && proseRecord().ordinary_prose?.head === collected.head_sha &&
  proseRecord().ordinary_prose?.evidence.length === 3)
assert('ordinary prose binds the exact collected patch digest and preserves the existing patch_id',
  proseRecord().ordinary_prose?.patch_sha256 === proseCollected.patch_sha256 &&
  proseRecord().patch_id === proseCollected.patch_id)
for (const digest of [undefined, null, '', 'a'.repeat(63), 'a'.repeat(65), 'A'.repeat(64), 'g'.repeat(64),
  'a'.repeat(64) + '\n', 42, ['a'.repeat(64)]]) {
  assert(`missing/malformed collected digest never grants exemption: ${JSON.stringify(digest)}`,
    !proseRecord(proseLenses, false, { ...proseCollected, patch_sha256: digest }).ordinary_prose)
}
assert('legacy lens omission is nonexempt', !proseRecord([]).ordinary_prose)
assert('one negative semantic assessment is nonexempt', !proseRecord([
  ...proseLenses.slice(0, 2), { ...proseLenses[2], ordinary_prose: { eligible: false, evidence: 'custom machine consumer' } },
]).ordinary_prose)
assert('missing lens is nonexempt', !proseRecord(proseLenses.slice(0, 2)).ordinary_prose)
assert('underread is nonexempt', !proseRecord(proseLenses.map(r => ({ ...r, diff_lines_read: 19 }))).ordinary_prose)
assert('empty consumer evidence is nonexempt', !proseRecord(proseLenses.map(r => ({ ...r,
  ordinary_prose: { eligible: true, evidence: ' ' } }))).ordinary_prose)
assert('override never grants exemption', !proseRecord(proseLenses, true).ordinary_prose)
assert('missing base never grants exemption', !proseRecord(proseLenses, false,
  { ...proseCollected, base_sha: undefined }).ordinary_prose)
assert('non-CLEAN never grants exemption', !proseRecord(proseLenses, false, proseCollected, 'DIRTY').ordinary_prose)
assert('lens schema assessment stays optional', !!FINDINGS_SCHEMA.properties.ordinary_prose &&
  !FINDINGS_SCHEMA.required.includes('ordinary_prose'))
const firstRecord = composeRecord([], { ...collected, ledger: ledger([]) }, [], 'CLEAN', emptyRed, false).record
assert('first round initializes streak zero and no RED', firstRecord.round === 1 && firstRecord.streak === 0)
const variants = { recordFrozen, recordOverride, firstRecord, ordinaryProse: proseRecord() }
for (const [name, test] of Object.entries({
  inconclusive: candidate(testPath, sha(1), 'ran',
    [caseResult('bad', 'unresolved', 'pass', 'inconclusive')], 'suite aborted'),
  unsupported: candidate(testPath, sha(1), 'unsupported',
    [caseResult(testPath, 'unsupported', 'unsupported', 'unsupported')], 'no runner family'),
  unverifiable: candidate(testPath, sha(1), 'unverifiable', [], 'pre-fix fetch failed'),
  fileLevel: candidate(testPath, sha(1), 'file-level',
    [caseResult(testPath, 'pass', 'pass', 'never-red')], null),
})) {
  const raw = { ...report, tests: [test] }
  const mapped = redFirstFindings(raw)
  variants[name] = composeRecord(one, collected, mapped, computeVerdict(mapped),
    composeRedFirst(raw, mapped, true), false).record
}

// Contract C (plan R2): a never-red P1 stays live until its path is re-executed,
// proven unchanged, or leaves the PR -- not silently dropped by a same-head
// re-run or a source-only round whose manifest is empty.
const neverTitle = `never-red regression test: ${carriedPath}::missed`
const exemptPath = 'tests/y.test.sh'
// Round 2's RED run names the case, as every recorded never-red P1's run does.
const neverPrior = [roundEntry(1, 0, 10, 0), roundEntry(2, 1, 20, 0, { findings: [
  { file: carriedPath, severity: 'P1', title: neverTitle },
  { file: exemptPath, severity: 'P3', title: `never-red regression test: ${exemptPath}::old` },
  { file: 'a.js', severity: 'P1', title: 'lens defect' }],
red: { status: 'never-red', unchanged: [], tests: [candidate(carriedPath, sha(1), 'ran',
  [caseResult('missed', 'pass', 'pass', 'never-red')])] } })]
const prFiles = [carriedPath, exemptPath, 'a.js']
const emptyRun = (head) => ({ head, base_branch: sha(90), overlay: [], exempt: [], unchanged: [],
  requested: [], tests: [] })
assert('workflow carries never-red findings forward', typeof carriedNeverRed === 'function')
if (typeof carriedNeverRed === 'function') {
  const carriedFor = (report, files = prFiles, prior = neverPrior, removedAtHead = new Set()) =>
    carriedNeverRed(prior, report, files, removedAtHead)
  const expectedCarry = [{ file: carriedPath, severity: 'P1', title: neverTitle,
    rationale: `carried from round 2 (head ${sha(2)}): no evidence about the case this round`,
    refuted: false, lenses: ['red-first'] }]
  // Mirrors the workflow's Judge glue: carried findings join the RED findings.
  const roundFrom = (report) => {
    const redFindings = [...redFirstFindings(report), ...carriedFor(report)]
    const merged = mergeRedFindings([], redFindings)
    return composeRecord(neverPrior, { head_sha: report.head, patch_id: sha(150), diff_lines: 20,
      ledger: ledger(neverPrior) }, merged, computeVerdict(merged),
    composeRedFirst(report, redFindings, true), false).record
  }
  const rerun = roundFrom(emptyRun(sha(2)))
  assert('a same-head re-run with an empty manifest keeps the never-red P1 live',
    sameData(carriedFor(emptyRun(sha(2))), expectedCarry) && rerun.verdict === 'DIRTY' &&
    rerun.live.P1 === 1 && rerun.red_first.status === 'never-red' &&
    rerun.findings.some((f) => f.title === neverTitle))
  const sourceOnly = roundFrom(emptyRun(sha(3)))
  assert('a source-only next round keeps the never-red P1 live',
    sameData(carriedFor(emptyRun(sha(3))), expectedCarry) && sourceOnly.verdict === 'DIRTY' &&
    sourceOnly.live.P1 === 1 && sourceOnly.red_first.status === 'never-red')
  const reverified = { ...emptyRun(sha(3)), requested: [{ path: carriedPath, pre_fix: sha(1) }],
    overlay: [carriedPath], tests: [candidate(carriedPath, sha(1), 'ran',
      [caseResult('missed', 'fail', 'pass', 'verified')])] }
  assert('re-execution with a verified case clears the carried never-red P1',
    carriedFor(reverified).length === 0 && roundFrom(reverified).verdict === 'CLEAN' &&
    roundFrom(reverified).red_first.status === 'verified')
  // Contract C2: only evidence about the carried case clears it. A file-level
  // run's synthetic whole-file result says nothing about `missed`.
  const fileLevel = { ...reverified, tests: [candidate(carriedPath, sha(1), 'file-level',
    [caseResult(carriedPath, 'fail', 'pass', 'verified')], 'case names missing')] }
  assert('a file-level re-execution with only the synthetic whole-file case keeps the carry',
    sameData(carriedFor(fileLevel), expectedCarry))
  const fileLevelNamed = { ...reverified, tests: [candidate(carriedPath, sha(1), 'file-level', [
    caseResult('missed', 'fail', 'pass', 'verified'),
    caseResult(carriedPath, 'unresolved', 'unresolved', 'inconclusive')], 'dynamic remainder')] }
  assert('a file-level re-execution that names the carried case clears it', carriedFor(fileLevelNamed).length === 0)
  const fileLevelOther = { ...reverified, tests: [candidate(carriedPath, sha(1), 'file-level', [
    caseResult('other', 'fail', 'pass', 'verified'),
    caseResult(carriedPath, 'unresolved', 'unresolved', 'inconclusive')], 'dynamic remainder')] }
  assert('a file-level re-execution naming only other cases keeps the carry',
    sameData(carriedFor(fileLevelOther), expectedCarry))
  const ranStillNever = { ...reverified, tests: [candidate(carriedPath, sha(1), 'ran',
    [caseResult('missed', 'pass', 'pass', 'never-red')])] }
  const ranStillNeverRound = roundFrom(ranStillNever)
  assert('a case-level run clears the carry and its fresh never-red evidence keeps the round DIRTY',
    carriedFor(ranStillNever).length === 0 && ranStillNeverRound.verdict === 'DIRTY' &&
    ranStillNeverRound.live.P1 === 1 &&
    redFirstFindings(ranStillNever).some((f) => f.title === neverTitle && !f.rationale.startsWith('carried from')))
  // The runner report always lists an unchanged path in requested (checkRedReport).
  const unchangedAt = (preFix, requestedPreFix = sha(1)) => ({ ...emptyRun(sha(3)),
    requested: [{ path: carriedPath, pre_fix: requestedPreFix }], unchanged: [{ path: carriedPath, pre_fix: preFix }] })
  assert('a path proven unchanged against the requested baseline clears the carried never-red P1',
    carriedFor(unchangedAt(sha(1))).length === 0)
  assert('a path unchanged against a revision other than the requested baseline keeps the carry',
    sameData(carriedFor(unchangedAt(sha(2))), expectedCarry))
  assert('an unchanged entry with no requested baseline for its path keeps the carry',
    sameData(carriedFor({ ...emptyRun(sha(3)), unchanged: [{ path: carriedPath, pre_fix: sha(1) }] }), expectedCarry))
  assert('a path absent at head clears the carried never-red P1',
    carriedFor(emptyRun(sha(3)), prFiles, neverPrior, new Set([carriedPath])).length === 0)
  assert('a different path absent at head does not clear the carry',
    sameData(carriedFor(emptyRun(sha(3)), prFiles, neverPrior, new Set([exemptPath])), expectedCarry))
  assert('an exempt never-red P3 is not carried',
    !carriedFor(emptyRun(sha(3))).some((f) => f.file === exemptPath))
  assert('a path no longer in the PR files is not carried',
    carriedFor(emptyRun(sha(3)), [exemptPath, 'a.js']).length === 0)
  const lostSelection = selectionUnverifiable(prFiles, neverPrior, sha(3), sha(90), 'git fetch: unavailable')
  const lostRound = roundFrom(lostSelection)
  assert('a selection-error round keeps the never-red P1 and stays unverifiable',
    sameData(carriedFor(lostSelection), expectedCarry) && lostRound.verdict === 'DIRTY' &&
    lostRound.live.P1 === 1 && lostRound.red_first.status === 'unverifiable')
  assert('a re-selected path that could not run keeps the never-red P1',
    sameData(carriedFor({ ...emptyRun(sha(3)), tests: [candidate(carriedPath, sha(1), 'unverifiable', [],
      'pre-fix fetch failed')] }), expectedCarry))
  assert('no prior round carries nothing', carriedNeverRed([], emptyRun(sha(1)), prFiles, new Set()).length === 0)
  const chained = [...neverPrior, { round: 3, rerun: true, comment_id: 3, author_id: 12,
    created_at: '2026-09-24T00:00:00Z', record: rerun }]
  assert('the carry chains through the next stored record',
    carriedFor(emptyRun(sha(4)), prFiles, chained)[0]?.rationale ===
      `carried from round 3 (head ${sha(2)}): no evidence about the case this round`)
  // Contract C3 (inward re-vet at 01d60f20): a case-level run is evidence about a
  // carried case only when it names the case, or when its effective pre-fix is the
  // revision that flagged the live P1: that run's diff to head attributes every
  // case changed since, so an absent case was reverted, renamed or deleted. A Red-first-base trailer that moves the baseline past the case
  // leaves it unattributed and must not clear it.
  const flaggedRed = { status: 'never-red', tests: [candidate(carriedPath, sha(1), 'ran',
    [caseResult('missed', 'pass', 'pass', 'never-red')])], unchanged: [] }
  const flaggedPrior = [roundEntry(1, 0, 10, 0),
    roundEntry(2, 1, 20, 0, { findings: neverPrior[1].record.findings, red: flaggedRed })]
  const ranOther = (preFix, head = sha(3), requestedPreFix = sha(1)) => ({ ...emptyRun(head),
    overlay: [carriedPath], requested: [{ path: carriedPath, pre_fix: requestedPreFix }],
    tests: [candidate(carriedPath, preFix, 'ran', [caseResult('other', 'fail', 'pass', 'verified')])] })
  assert('a case-level run from the flagging baseline that no longer names the case clears it',
    carriedFor(ranOther(sha(1)), prFiles, flaggedPrior).length === 0)
  assert('a case-level run from a trailer-moved baseline that does not name the case keeps the carry',
    sameData(carriedFor(ranOther(sha(2)), prFiles, flaggedPrior), expectedCarry))
  assert('a case-level run from a trailer-moved baseline that names the case clears it',
    carriedFor({ ...ranOther(sha(2)), tests: [candidate(carriedPath, sha(2), 'ran',
      [caseResult('missed', 'fail', 'pass', 'verified')])] }, prFiles, flaggedPrior).length === 0)
  // Refute lens at 6f6f3082: the history is the Collect agent's copy, so a case
  // list it shortened must not drop the P1. Without the attribution the P1 stays
  // carried, a lens title copying the prefix included; the carry errs toward keeping.
  const shortenedPrior = [roundEntry(1, 0, 10, 0), roundEntry(2, 1, 20, 0, {
    findings: neverPrior[1].record.findings, red: { ...flaggedRed, tests: [candidate(carriedPath, sha(1), 'ran',
      [caseResult('first', 'fail', 'pass', 'verified'), caseResult('second', 'fail', 'pass', 'verified')])] } })]
  assert('a never-red P1 whose attributing case list the copy shortened stays carried',
    sameData(carriedFor(emptyRun(sha(3)), prFiles, shortenedPrior), expectedCarry))
  assert('with the attribution lost a case-level run that does not name the case keeps the carry',
    sameData(carriedFor(ranOther(sha(1)), prFiles, shortenedPrior), expectedCarry))
  const unattributedPrior = [roundEntry(1, 0, 10, 0), roundEntry(2, 1, 20, 0, { findings: [
    { file: carriedPath, severity: 'P1', title: neverTitle },
    { file: 'a.js', severity: 'P1', title: 'never-red regression test: carry clears on any run' }] })]
  assert('a never-red-titled P1 whose case no recorded RED test names stays carried',
    sameData(carriedFor(emptyRun(sha(3)), prFiles, unattributedPrior).map((f) => f.title),
      [neverTitle, 'never-red regression test: carry clears on any run']))
  // The flagging revision decides, not the path's first sight: a case flagged
  // against an earlier trailer revision stays live through a run from first sight.
  const earlyFlagPrior = [roundEntry(1, 0, 10, 0), roundEntry(2, 0, 10, 0),
    roundEntry(3, 0, 20, 0, { red: { status: 'verified', unchanged: [], tests: [candidate(carriedPath, sha(2), 'ran',
      [caseResult('other', 'fail', 'pass', 'verified')])] } }),
    roundEntry(4, 1, 20, 0, { findings: [{ file: carriedPath, severity: 'P1', title: neverTitle }],
      red: { status: 'never-red', unchanged: [], tests: [candidate(carriedPath, sha(1), 'ran',
        [caseResult('missed', 'pass', 'pass', 'never-red')])] } })]
  assert('a run from the first-sight baseline keeps a case flagged against an earlier revision',
    sameData(carriedManifest(earlyFlagPrior), [{ path: carriedPath, pre_fix: sha(2) }]) &&
    sameData(carriedFor(ranOther(sha(2), sha(5), sha(2)), prFiles, earlyFlagPrior).map((f) => f.title), [neverTitle]))
  // The earliest flagging run in the P1's chain anchors it: a case re-flagged
  // against a later trailer revision, then reverted to that revision's version,
  // was already judged never-red against the first, so a run from the later
  // revision clears nothing.
  const reflaggedPrior = [...flaggedPrior, roundEntry(3, 1, 20, 0, {
    findings: [{ file: carriedPath, severity: 'P1', title: neverTitle }],
    red: { status: 'never-red', unchanged: [], tests: [candidate(carriedPath, sha(2), 'ran',
      [caseResult('missed', 'pass', 'pass', 'never-red')])] } })]
  assert('a case re-flagged against a later revision is not cleared by a run from that revision',
    sameData(carriedFor(ranOther(sha(2), sha(4)), prFiles, reflaggedPrior).map((f) => f.title), [neverTitle]))
  // A trailer-moved round is recorded with its effective pre-fix; that must not
  // become the path's baseline on the next round (KTD2: fixed on first sight).
  const movedPrior = [...flaggedPrior, roundEntry(3, 1, 20, 0, {
    findings: [{ file: carriedPath, severity: 'P1', title: neverTitle }],
    red: { status: 'verified', unchanged: [], tests: [candidate(carriedPath, sha(2), 'ran',
      [caseResult('other', 'fail', 'pass', 'verified')])] } })]
  assert('a trailer-moved record never replaces the first-sight baseline',
    sameData(carriedManifest(movedPrior), [{ path: carriedPath, pre_fix: sha(1) }]))
  assert('a trailer-moved baseline recorded one round earlier still cannot clear the carry',
    sameData(carriedFor(ranOther(sha(2), sha(4)), prFiles, movedPrior).map((f) => f.rationale),
      [`carried from round 3 (head ${sha(3)}): no evidence about the case this round`]))
  // Pro gate round 4 at b30807d2: the run that flagged the live P1 anchors it,
  // not the first run naming the case. Verified against sha(1), then weakened
  // and flagged against an older trailer revision sha(5), the case stays live
  // through a run from sha(1) that omits it: its version at head is sha(1)'s,
  // which no run judged RED.
  const neverRedAt = (preFix) => ({ status: 'never-red', unchanged: [], tests: [candidate(carriedPath, preFix, 'ran',
    [caseResult('missed', 'pass', 'pass', 'never-red')])] })
  const verifiedAt = (preFix) => ({ status: 'verified', unchanged: [], tests: [candidate(carriedPath, preFix, 'ran',
    [caseResult('missed', 'fail', 'pass', 'verified')])] })
  const liveNever = [{ file: carriedPath, severity: 'P1', title: neverTitle }]
  const verifiedThenFlagged = [roundEntry(1, 0, 10, 0), roundEntry(2, 0, 20, 0, { red: verifiedAt(sha(1)) }),
    roundEntry(3, 1, 20, 0, { findings: liveNever, red: neverRedAt(sha(5)) })]
  assert('a run from an earlier verified baseline that omits the case keeps its later never-red P1',
    sameData(carriedFor(ranOther(sha(1), sha(4)), prFiles, verifiedThenFlagged).map((f) => f.title), [neverTitle]))
  assert('a run from the revision that flagged the case, omitting it, clears the P1',
    carriedFor(ranOther(sha(5), sha(4)), prFiles, verifiedThenFlagged).length === 0)
  const omittingRun = ranOther(sha(1), sha(4))
  const omittingRed = [...redFirstFindings(omittingRun), ...carriedFor(omittingRun, prFiles, verifiedThenFlagged)]
  const omittingMerged = mergeRedFindings([], omittingRed)
  const omittingRecord = composeRecord(verifiedThenFlagged, { head_sha: sha(4), patch_id: sha(156), diff_lines: 20,
    ledger: ledger(verifiedThenFlagged) }, omittingMerged, computeVerdict(omittingMerged),
  composeRedFirst(omittingRun, omittingRed, true), false).record
  assert('that omitting run composes a DIRTY record with the never-red P1 live, not CLEAN',
    omittingRecord.verdict === 'DIRTY' && omittingRecord.live.P1 === 1 &&
    omittingRecord.findings.some((f) => f.severity === 'P1' && f.title === neverTitle))
  // A P1 cleared in between starts a new chain: the earlier flagging run does not anchor it.
  const reflaggedAfterClear = [roundEntry(1, 0, 10, 0),
    roundEntry(2, 1, 20, 0, { findings: liveNever, red: neverRedAt(sha(1)) }),
    roundEntry(3, 0, 20, 0, { red: verifiedAt(sha(1)) }),
    roundEntry(4, 1, 20, 0, { findings: liveNever, red: neverRedAt(sha(2)) })]
  assert('a never-red P1 cleared and flagged again is not cleared from the earlier flagging baseline',
    sameData(carriedFor(ranOther(sha(1), sha(5)), prFiles, reflaggedAfterClear).map((f) => f.title), [neverTitle]))
  assert('a never-red P1 cleared and flagged again clears from its new flagging baseline',
    carriedFor(ranOther(sha(2), sha(5)), prFiles, reflaggedAfterClear).length === 0)
  // The chain follows this P1's own title: another never-red case in the same
  // file staying live does not extend it back to the earlier flagging run.
  const siblingNever = { file: carriedPath, severity: 'P1', title: `never-red regression test: ${carriedPath}::sibling` }
  const withSibling = [roundEntry(1, 0, 10, 0),
    roundEntry(2, 2, 20, 0, { findings: [...liveNever, siblingNever], red: { status: 'never-red', unchanged: [],
      tests: [candidate(carriedPath, sha(1), 'ran', [caseResult('missed', 'pass', 'pass', 'never-red'),
        caseResult('sibling', 'pass', 'pass', 'never-red')])] } }),
    roundEntry(3, 1, 20, 0, { findings: [siblingNever], red: verifiedAt(sha(1)) }),
    roundEntry(4, 2, 20, 0, { findings: [...liveNever, siblingNever], red: neverRedAt(sha(2)) })]
  assert('another live never-red case in the same file does not extend this case\'s chain',
    carriedFor(ranOther(sha(1), sha(5)), prFiles, withSibling).some((f) => f.title === neverTitle))
  // An exempt round records the same case as a P3, which ends the P1's chain.
  const exemptBetween = [roundEntry(1, 0, 10, 0),
    roundEntry(2, 1, 20, 0, { findings: liveNever, red: neverRedAt(sha(1)) }),
    roundEntry(3, 0, 20, 0, { findings: [{ ...liveNever[0], severity: 'P3' }], red: neverRedAt(sha(1)) }),
    roundEntry(4, 1, 20, 0, { findings: liveNever, red: neverRedAt(sha(2)) })]
  assert('an exempt round between two flaggings ends the earlier chain',
    carriedFor(ranOther(sha(1), sha(5)), prFiles, exemptBetween).some((f) => f.title === neverTitle))
  // Pro gate round 5 at a0f01cd9: first sight is the baseline a path's first RED
  // run requested, not that run's effective revision. Round 2 requested sha(1)
  // and a Red-first-base trailer ran it from intermediate commit sha(50), no
  // recorded head. With that trailer merged out of range, round 3's edit to
  // another case ran from sha(2), which already held the never-red case, and
  // round 4 reverted the edit: baselined on sha(2) the file is unchanged and the
  // P1 cleared though the case never went RED.
  const trailerFirstSight = [roundEntry(1, 0, 10, 0),
    roundEntry(2, 1, 20, 0, { findings: liveNever, red: { ...neverRedAt(sha(50)),
      requested: [{ path: carriedPath, pre_fix: sha(1) }] } }),
    roundEntry(3, 1, 20, 0, { findings: liveNever, red: { status: 'never-red', unchanged: [],
      requested: [{ path: carriedPath, pre_fix: sha(2) }],
      tests: [candidate(carriedPath, sha(2), 'ran', [caseResult('other', 'fail', 'pass', 'verified')])] } })]
  assert('a first run\'s requested baseline stays first sight when a trailer moved its effective one',
    sameData(carriedManifest(trailerFirstSight), [{ path: carriedPath, pre_fix: sha(1) }]))
  // This history's runner: the file at sha(4) is its sha(2) version, which
  // differs from sha(1) only in the never-red case.
  const revertedRun = (preFix) => preFix === sha(2)
    ? { ...emptyRun(sha(4)), requested: [{ path: carriedPath, pre_fix: preFix }],
      unchanged: [{ path: carriedPath, pre_fix: preFix }] }
    : { ...emptyRun(sha(4)), overlay: [carriedPath], requested: [{ path: carriedPath, pre_fix: preFix }],
      tests: [candidate(carriedPath, preFix, 'ran', [caseResult('missed', 'pass', 'pass', 'never-red')])] }
  const revertRun = revertedRun(carriedManifest(trailerFirstSight)[0].pre_fix)
  const revertRed = [...redFirstFindings(revertRun), ...carriedFor(revertRun, prFiles, trailerFirstSight)]
  const revertMerged = mergeRedFindings([], revertRed)
  const revertRecord = composeRecord(trailerFirstSight, { head_sha: sha(4), patch_id: sha(157), diff_lines: 20,
    ledger: ledger(trailerFirstSight) }, revertMerged, computeVerdict(revertMerged),
  composeRedFirst(revertRun, revertRed, true), false).record
  assert('reverting an unrelated edit composes a DIRTY record with the never-red P1 live, not CLEAN',
    revertRecord.verdict === 'DIRTY' && revertRecord.live.P1 === 1 &&
    revertRecord.findings.some((f) => f.severity === 'P1' && f.title === neverTitle))
  // A requested baseline keeps the recorded-head check: an edited request that
  // names no prior head leaves that record's effective entries, the earlier
  // baseline, which errs toward keeping.
  assert('a requested pre-fix that is no prior head is ignored',
    sameData(carriedManifest([roundEntry(1, 0, 10, 0),
      roundEntry(2, 0, 20, 0, { red: { ...carriedRed([carriedRan(sha(1))], []),
        requested: [{ path: carriedPath, pre_fix: sha(77) }] } }),
      roundEntry(3, 0, 30, 0, { red: { ...carriedRed([carriedRan(sha(2))], []),
        requested: [{ path: carriedPath, pre_fix: sha(2) }] } })]), [{ path: carriedPath, pre_fix: sha(1) }]))
  // Within one record the earliest recorded head wins, whichever field holds it.
  const bothHeads = (req, eff) => carriedManifest([roundEntry(1, 0, 10, 0), roundEntry(2, 0, 20, 0),
    roundEntry(3, 0, 30, 0, { red: { ...carriedRed([carriedRan(eff)], []),
      requested: [{ path: carriedPath, pre_fix: req }] } })])
  assert('a record\'s earliest recorded baseline is first sight, requested or effective',
    sameData(bothHeads(sha(2), sha(1)), [{ path: carriedPath, pre_fix: sha(1) }]) &&
    sameData(bothHeads(sha(1), sha(2)), [{ path: carriedPath, pre_fix: sha(1) }]))
  assert('a head seen again by a later rerun keeps its first place in round order',
    sameData(carriedManifest([roundEntry(1, 0, 10, 0), roundEntry(2, 0, 20, 0), roundEntry(3, 0, 30, 0),
      roundEntry(4, 0, 40, 0, { head: sha(2), rerun: true }),
      roundEntry(5, 0, 50, 0, { red: { ...carriedRed([carriedRan(sha(2))], []),
        requested: [{ path: carriedPath, pre_fix: sha(3) }] } })]), [{ path: carriedPath, pre_fix: sha(2) }]))
  // Pro gate round 1 at e2688e9f: production history is U1's `read --compact`
  // view, not the full records above. The flagging round is composed here and
  // handed to the U1 block below, which posts it through compose_body, reads it
  // back and compacts it; the confirm-outcome block then carries from that view.
  const flaggingRun = { ...emptyRun(sha(2)), overlay: [carriedPath],
    requested: [{ path: carriedPath, pre_fix: sha(1) }],
    tests: [candidate(carriedPath, sha(1), 'ran', [caseResult('missed', 'pass', 'pass', 'never-red'),
      caseResult('kept', 'fail', 'pass', 'verified')])] }
  const flaggingPrior = [{ round: 1, rerun: false, comment_id: 1, author_id: 12,
    created_at: '2026-09-24T00:00:00Z', record: firstRecord }]
  const flaggingRed = redFirstFindings(flaggingRun)
  const flaggingMerged = mergeRedFindings([], flaggingRed)
  const flagging = composeRecord(flaggingPrior, { head_sha: sha(2), patch_id: sha(152), diff_lines: 20,
    ledger: ledger(flaggingPrior) }, flaggingMerged, computeVerdict(flaggingMerged),
  composeRedFirst(flaggingRun, flaggingRed, true), false).record
  assert('the flagging round records the never-red P1 and its attributed case',
    flagging.findings.some((f) => f.severity === 'P1' && f.title === neverTitle) &&
    flagging.red_first.tests.some((t) => t.path === carriedPath && t.cases.some((c) => c.name === 'missed')))
  fs.writeFileSync(`${process.argv[2]}/neverFlagged.json`, JSON.stringify({ first: firstRecord, flagging }))
  // Pro gate round 2 at e96e1eee: a RED finding keeps its exact path::case
  // identity. Cases whose titles normalize alike (a punctuation-only
  // difference) stay two live P1s, are recorded apart and clear independently.
  const dashTitle = `never-red regression test: ${carriedPath}::rejects foo-bar`
  const dotTitle = `never-red regression test: ${carriedPath}::rejects foo.bar`
  const collidingRun = { ...emptyRun(sha(2)), overlay: [carriedPath],
    requested: [{ path: carriedPath, pre_fix: sha(1) }],
    tests: [candidate(carriedPath, sha(1), 'ran', [caseResult('rejects foo-bar', 'pass', 'pass', 'never-red'),
      caseResult('rejects foo.bar', 'pass', 'pass', 'never-red')])] }
  const collidingRed = redFirstFindings(collidingRun)
  const collidingMerged = mergeRedFindings([], collidingRed)
  const colliding = composeRecord(flaggingPrior, { head_sha: sha(2), patch_id: sha(153), diff_lines: 20,
    ledger: ledger(flaggingPrior) }, collidingMerged, computeVerdict(collidingMerged),
  composeRedFirst(collidingRun, collidingRed, true), false).record
  assert('never-red cases whose titles normalize alike stay two live P1 findings',
    deepEqSorted(collidingMerged.map((f) => f.title), [dashTitle, dotTitle]) && colliding.live.P1 === 2 &&
    deepEqSorted(colliding.findings.map((f) => f.title), [dashTitle, dotTitle]))
  const collidingPrior = [...flaggingPrior, { round: 2, rerun: false, comment_id: 2, author_id: 12,
    created_at: '2026-09-24T00:00:00Z', record: colliding }]
  // A trailer-moved run names one case; the other is unchanged since that
  // revision, so this round holds no evidence about it.
  const namesOnly = (caseName) => ({ ...emptyRun(sha(4)), overlay: [carriedPath],
    requested: [{ path: carriedPath, pre_fix: sha(1) }],
    tests: [candidate(carriedPath, sha(3), 'ran', [caseResult(caseName, 'fail', 'pass', 'verified')])] })
  const dashCarry = carriedNeverRed(collidingPrior, namesOnly('rejects foo-bar'), prFiles, new Set())
  const dashMerged = mergeRedFindings([], [...redFirstFindings(namesOnly('rejects foo-bar')), ...dashCarry])
  assert('verifying one of two alike-named cases carries the other and keeps the round DIRTY',
    sameData(dashCarry.map((f) => f.title), [dotTitle]) && computeVerdict(dashMerged) === 'DIRTY')
  assert('each alike-named case clears only on evidence about itself',
    sameData(carriedNeverRed(collidingPrior, namesOnly('rejects foo.bar'), prFiles, new Set())
      .map((f) => f.title), [dashTitle]))
  // A lens finding merges with one RED case by normalized title and takes that
  // case's exact title, which the carry parses; the other case stays separate.
  const lensAlike = [{ file: carriedPath, line: null, title: `Never-red regression test: ${carriedPath}::rejects foo bar`,
    severity: 'P2', rationale: 'lens', refuted: false, lenses: ['correctness'] }]
  const lensMerged = mergeRedFindings(lensAlike, collidingRed)
  assert('a lens finding absorbs one RED case under its exact title and leaves the other separate',
    lensMerged.length === 2 && deepEqSorted(lensMerged.map((f) => f.title), [dashTitle, dotTitle]) &&
    lensMerged.some((f) => f.title === dashTitle && f.severity === 'P1' &&
      deepEqSorted(f.lenses, ['correctness', 'red-first'])))
  // Verify lens at 82cab14f: a stricter lens keeps its own title, so a lens P1
  // alike to an exempt never-red P3 is not recorded as a carried never-red P1.
  const exemptRun = { ...collidingRun, exempt: [carriedPath], tests: [candidate(carriedPath, sha(1), 'ran',
    [caseResult('rejects foo-bar', 'pass', 'pass', 'never-red')], null, true)] }
  const exemptRed = redFirstFindings(exemptRun)
  const lensStricter = [{ ...lensAlike[0], title: `Never-red regression test: ${carriedPath}::rejects foo-bar`,
    severity: 'P1' }]
  const stricterMerged = mergeRedFindings(lensStricter, exemptRed)
  const exemptRecord = composeRecord(flaggingPrior, { head_sha: sha(2), patch_id: sha(154), diff_lines: 20,
    ledger: ledger(flaggingPrior) }, stricterMerged, computeVerdict(stricterMerged),
  composeRedFirst(exemptRun, exemptRed, true), false).record
  const exemptPrior = [...flaggingPrior, { round: 2, rerun: false, comment_id: 2, author_id: 12,
    created_at: '2026-09-24T00:00:00Z', record: exemptRecord }]
  const equalMerged = mergeRedFindings([{ ...lensStricter[0] }], collidingRed)
  assert('an equally severe lens finding takes the RED title, so its never-red P1 is carried',
    equalMerged.length === 2 && equalMerged.some((f) => f.title === dashTitle && f.lenses.includes('correctness')) &&
    deepEqSorted(equalMerged.map((f) => f.title), [dashTitle, dotTitle]))
  assert('a stricter lens finding keeps its title and is not carried as an exempt case\'s never-red P1',
    exemptRed.length === 1 && exemptRed[0].severity === 'P3' && stricterMerged.length === 1 &&
    stricterMerged[0].title === lensStricter[0].title && stricterMerged[0].severity === 'P1' &&
    carriedNeverRed(exemptPrior, emptyRun(sha(4)), prFiles, new Set()).length === 0)
  // Verify lens at a31af260: a stricter lens title copying the lowercase prefix
  // is carried like RED's, since a record keeps no finding's source and the
  // carry errs toward keeping (refute lens at 6f6f3082).
  const mimic = [{ ...lensStricter[0], title: `never-red regression test: ${carriedPath}::rejects foo bar` }]
  const mimicMerged = mergeRedFindings(mimic, exemptRed)
  const mimicRecord = composeRecord(flaggingPrior, { head_sha: sha(2), patch_id: sha(155), diff_lines: 20,
    ledger: ledger(flaggingPrior) }, mimicMerged, computeVerdict(mimicMerged),
  composeRedFirst(exemptRun, exemptRed, true), false).record
  assert('a stricter lens title copying the never-red prefix is recorded and carried',
    mimicRecord.findings.some((f) => f.severity === 'P1' && f.title === mimic[0].title) &&
    sameData(carriedNeverRed([...flaggingPrior, { round: 2, rerun: false, comment_id: 2, author_id: 12,
      created_at: '2026-09-24T00:00:00Z', record: mimicRecord }], emptyRun(sha(4)), prFiles, new Set())
      .map((f) => f.title), [mimic[0].title]))
  // A refuted lens finding is never the stricter one: RED's severity and title stand.
  const refutedMerged = mergeRedFindings([{ ...lensStricter[0], refuted: true }], exemptRed)
  assert('a refuted stricter lens finding takes RED\'s severity and title instead of reviving',
    refutedMerged.length === 1 && refutedMerged[0].severity === 'P3' && !refutedMerged[0].refuted &&
    refutedMerged[0].title === exemptRed[0].title && computeVerdict(refutedMerged) === computeVerdict(exemptRed))
}

// Contract S: record bodies over the 65536-character comment limit are refused
// before any post (its provenance is in evidence-regime §8). The estimate
// counts 6 per UTF-16 unit above 0x7e (json.dumps escapes it as \uXXXX) plus a
// fixed 1024 allowance for marker, table and fence.
const specEstimate = (record) => {
  const text = JSON.stringify(record, null, 2)
  let total = 1024
  for (let i = 0; i < text.length; i++) total += text.charCodeAt(i) > 0x7e ? 6 : 1
  return total
}
const sizedCollected = { ...collected, pr_repo: 'o/r', pr_number: 1 }
const sizedRecord = (title) => composeRecord(one, sizedCollected, [{ file: 'a.js', title, severity: 'P2',
  refuted: false, lenses: ['lens'] }], 'BORDERLINE', emptyRed, false, ['security']).record
const limitLength = 1 + 65536 - specEstimate(sizedRecord('x'))
const atLimit = sizedRecord('x'.repeat(limitLength))
assert('a record estimated at exactly the limit is composed', specEstimate(atLimit) === 65536)
try {
  sizedRecord('x'.repeat(limitLength + 1))
  assert('a record one character over the limit stops as ledger-record-too-large', false)
} catch (error) {
  assert('a record one character over the limit stops as ledger-record-too-large',
    error.code === 'ledger-record-too-large' && String(error).split('\n')[0] ===
      'Error: ledger-record-too-large: round 2 record body would be about 65537 characters ' +
      '(GitHub comment limit 65536); nothing was posted')
  // Contract T: the one finding's title alone is past the delivery limit, so the
  // payload keeps every scalar and reports the dropped finding by count.
  assert('ledger-record-too-large payload carries every decision field',
    sameData(payloadOf(error), { code: 'ledger-record-too-large', estimated_chars: 65537, limit: 65536,
      pr_repo: 'o/r', pr_number: 1, round: 2, verdict: 'BORDERLINE', underlying_verdict: 'BORDERLINE',
      touched_domains: ['security'], live: { P1: 0, P2: 1, P3: 0 }, red_first_status: 'not-applicable',
      findings: [], truncated: { findings: 1 } }))
}
assertThrows('the existing count bound still refuses before the size bound', () =>
  composeRecord(one, sizedCollected, Array.from({ length: 201 }, (_, i) => ({ file: 'a.js', title: `t${i}`,
    severity: 'P3', refuted: false, lenses: ['lens'] })), 'BORDERLINE', emptyRed, false, []),
'U1 ledger bounds')
// U1 validate_record refuses a record past its MAX_* bounds on every post, so
// composeRecord must refuse at exactly the same count: accept MAX, refuse MAX + 1.
// The bounds are read from review-rounds.py itself (u1-bounds.json, above).
const u1 = JSON.parse(fs.readFileSync(`${process.argv[2]}/u1-bounds.json`, 'utf8'))
for (const [name, value] of Object.entries(u1)) {
  assert(`U1 ${name} is a positive integer`, Number.isInteger(value) && value > 0)
}
const boundFindings = (n, severity = 'P3') => Array.from({ length: n }, (_, i) =>
  ({ file: `f${i}.js`, title: `t${i}`, severity, refuted: false, lenses: ['lens'] }))
const boundTests = (n) => Array.from({ length: n }, (_, i) =>
  candidate(`t${i}.test.sh`, sha(1), 'unverifiable', [], 'bounds fixture'))
const boundCases = (n) => [candidate(testPath, sha(1), 'ran',
  Array.from({ length: n }, (_, i) => caseResult(`c${i}`, 'fail', 'pass', 'verified')))]
const composeBound = (findings, tests, prior = one) => () => composeRecord(prior, sizedCollected, findings,
  'BORDERLINE', { status: 'verified', tests }, false, [])
assertDoesNotThrow(`exactly U1 MAX_FINDINGS (${u1.MAX_FINDINGS}) live findings compose`,
  composeBound(boundFindings(u1.MAX_FINDINGS), []))
assertThrows('one live finding past U1 MAX_FINDINGS is refused',
  composeBound(boundFindings(u1.MAX_FINDINGS + 1), []), 'U1 ledger bounds')
assertDoesNotThrow(`exactly U1 MAX_RED_FIRST_TESTS (${u1.MAX_RED_FIRST_TESTS}) RED tests compose`,
  composeBound([], boundTests(u1.MAX_RED_FIRST_TESTS)))
assertThrows('one RED test past U1 MAX_RED_FIRST_TESTS is refused',
  composeBound([], boundTests(u1.MAX_RED_FIRST_TESTS + 1)), 'U1 ledger bounds')
assertDoesNotThrow(`exactly U1 MAX_RED_FIRST_CASES (${u1.MAX_RED_FIRST_CASES}) cases in one test compose`,
  composeBound([], boundCases(u1.MAX_RED_FIRST_CASES)))
assertThrows('one case past U1 MAX_RED_FIRST_CASES is refused',
  composeBound([], boundCases(u1.MAX_RED_FIRST_CASES + 1)), 'U1 ledger bounds')
// Residual classes group live P1/P2 findings by file, so they never outnumber the
// findings bound checked first: the refusing side is unreachable, and only the
// accepting side and the literal itself can be checked.
const frozenBound = (() => {
  try { return composeBound(boundFindings(u1.MAX_RESIDUAL_CLASSES, 'P1'), [], two)().record } catch { return null }
})()
assert(`exactly U1 MAX_RESIDUAL_CLASSES (${u1.MAX_RESIDUAL_CLASSES}) residual classes compose on a FROZEN round`,
  frozenBound?.verdict === 'FROZEN' && frozenBound.residual_classes.length === u1.MAX_RESIDUAL_CLASSES)
assertThrows('residual classes past U1 MAX_RESIDUAL_CLASSES are refused',
  composeBound(boundFindings(u1.MAX_RESIDUAL_CLASSES + 1, 'P1'), [], two), 'U1 ledger bounds')
assert('composeRecord residual_classes bound literal equals U1 MAX_RESIDUAL_CLASSES',
  Number(composeRecord.toString().match(/score\.residual_classes\.length > (\d+)/)?.[1]) === u1.MAX_RESIDUAL_CLASSES)
// Cross-checked below against U1's own compose_body, ASCII and non-ASCII alike.
const unicodeText = 'naïve — ünïcødé 😀 “quoted” \t tab \n newline " quote \\ slash \u007f del \u0000 nul \u2028 sep'
const unicodeReport = { ...report, tests: [candidate(testPath, sha(1), 'ran',
  [caseResult(`case ✓ ${unicodeText}`, 'pass', 'pass', 'never-red')], `Traceback … ${unicodeText}`)] }
const unicodeFindings = mergeRedFindings([{ file: 'ü.js', title: unicodeText, severity: 'P2', refuted: false,
  lenses: ['lens'] }], redFirstFindings(unicodeReport))
const sized = {
  ...variants,
  unicode: composeRecord(one, sizedCollected, unicodeFindings, computeVerdict(unicodeFindings),
    composeRedFirst(unicodeReport, redFirstFindings(unicodeReport), true), false, []).record,
  atLimit,
  unicodeNearLimit: sizedRecord('—'.repeat(Math.floor((65536 - specEstimate(sizedRecord('x')) + 1) / 6))),
}
assert('workflow exposes its comment-size estimate', typeof recordBodyEstimate === 'function')
for (const [name, record] of Object.entries(sized)) {
  if (typeof recordBodyEstimate === 'function') {
    assert(`workflow estimate for ${name} follows contract S`, recordBodyEstimate(record) === specEstimate(record))
    fs.writeFileSync(`${process.argv[2]}/size-${name}.json`,
      JSON.stringify({ record, estimate: recordBodyEstimate(record) }))
  }
}
variants.unicode = sized.unicode
for (const [name, record] of Object.entries(variants)) {
  fs.writeFileSync(`${process.argv[2]}/${name}.json`, JSON.stringify(record))
}

// Contract T: Claude Code 2.1.280's Workflow runtime renders a thrown script error
// with Nnt: oc([oc(`${name}: ${message}`), ...up to five `at` stack lines, each cut
// to 500 characters plus an ellipsis].join('\n')), where oc(e, n = 1e4) with FR =
// 1024 keeps the first 5000 and last 5000 characters of any text past 11024 around
// a truncation marker. A cut through the payload line breaks its JSON, so every
// typed stop must reach the caller through this rendering intact. With stack ''
// the model is exactly the `${name}: ${message}` rendering.
const RUNTIME_KEEP = 10000
const runtimeCut = (text) => (text.length <= RUNTIME_KEEP + 1024 ? text
  : `${text.slice(0, RUNTIME_KEEP / 2)}\n\n... [${text.length - RUNTIME_KEEP} characters truncated] ...\n\n` +
    text.slice(text.length - RUNTIME_KEEP / 2))
const runtimeRender = (error, stack = String(error.stack || '')) => runtimeCut([
  runtimeCut(`${error.name}: ${error.message}`),
  ...stack.split('\n').filter((line) => /^\s*at /.test(line)).slice(0, 5)
    .map((line) => (line.length > 500 ? `${line.slice(0, 500)}…` : line))].join('\n'))
const renderedPayload = (error, stack) => {
  const line = runtimeRender(error, stack).split('\n')[1]
  if (typeof line !== 'string' || !line.startsWith('payload=')) return null
  try { return JSON.parse(line.slice('payload='.length)) } catch { return null }
}
assert('workflow bounds typed stops at TYPED_STOP_LIMIT = 8000 with a 2000-character summary',
  typeof TYPED_STOP_LIMIT === 'number' && TYPED_STOP_LIMIT === 8000 &&
  typeof TYPED_STOP_SUMMARY_LIMIT === 'number' && TYPED_STOP_SUMMARY_LIMIT === 2000)
const stopLimit = typeof TYPED_STOP_LIMIT === 'number' ? TYPED_STOP_LIMIT : 8000
// The largest stack the renderer appends: five `at` lines, each cut to 501 characters.
const worstStack = Array.from({ length: 5 }, () => `    at ${'w'.repeat(600)}`).join('\n')
const caught = (fn) => { try { fn() } catch (error) { return error } return null }
const checkDelivered = (name, error, summary, payload, routing, oversized) => {
  const unbounded = `${summary}\npayload=${JSON.stringify(payload)}`
  assert(`${name}: fixture ${oversized ? 'would' : 'would not'} be cut by the runtime without the bound`,
    runtimeCut(`Error: ${unbounded}`).includes('characters truncated') === oversized)
  if (!(error instanceof Error)) { assert(`${name}: the typed stop was thrown`, false); return }
  const rendered = runtimeRender(error)
  const got = renderedPayload(error)
  assert(`${name}: the message stays within TYPED_STOP_LIMIT and the runtime renders it uncut`,
    error.message.length <= stopLimit && !rendered.includes('characters truncated'))
  assert(`${name}: the rendered payload= line parses as JSON`, got !== null)
  if (got === null) return
  assert(`${name}: the stack-free rendering carries the same payload`, sameData(renderedPayload(error, ''), got))
  assert(`${name}: a worst-case stack still renders the same payload uncut`,
    sameData(renderedPayload(error, worstStack), got) && !runtimeRender(error, worstStack).includes('characters truncated'))
  assert(`${name}: the summary line survives`, rendered.split('\n')[0] === `Error: ${summary}`)
  assert(`${name}: code and every scalar routing field survive exactly`,
    error.code === payload.code && ['code', ...routing].every((key) => Object.hasOwn(got, key) &&
      sameData(got[key], payload[key])))
  if (!oversized) {
    assert(`${name}: a payload that fits round-trips exactly with no truncated key`,
      sameData(got, payload) && !Object.hasOwn(got, 'truncated'))
    return
  }
  const shortened = Object.keys(got.truncated || {})
  assert(`${name}: the payload names the arrays it shortened`, shortened.length > 0 &&
    shortened.every((key) => Array.isArray(payload[key])) &&
    sameData(Object.keys(got).sort(), [...Object.keys(payload), 'truncated'].sort()))
  for (const [key, value] of Object.entries(payload)) {
    if (!Array.isArray(value)) {
      assert(`${name}: non-array field ${key} is never altered`, sameData(got[key], value))
    } else if (shortened.includes(key)) {
      assert(`${name}: truncated.${key} is the original length and the kept ${key} is a halving prefix`,
        got.truncated[key] === value.length && Array.isArray(got[key]) && got[key].length < value.length &&
        sameData(got[key], value.slice(0, got[key].length)) &&
        Array.from({ length: 32 }, (_, k) => Math.floor(value.length / 2 ** (k + 1))).includes(got[key].length))
    } else {
      assert(`${name}: unshortened array ${key} survives exactly`, sameData(got[key], value))
    }
  }
}
// frozen: payload fields exactly as the workflow's admission stop builds them.
const longTitle = (i) => `residual finding ${i}: ` + 'r'.repeat(120)
const frozenHistory = Array.from({ length: 40 }, (_, i) => roundEntry(i + 1, 2, 100 + i, i < 38 ? 0 : i - 37))
const frozenPayload = { code: 'frozen', pr_repo: 'o/r', pr_number: 1, prior_round: 40, streak: 2,
  underlying_verdict: 'DIRTY', touched_domains: ['ci', 'security'], table: roundTable(frozenHistory, null).slice(-32),
  residual_classes: residualClasses(Array.from({ length: 200 }, (_, i) => ({ file: `hooks/residual-${i}.js`,
    severity: 'P1', title: longTitle(i), refuted: false }))),
  ledger_errors: [untrustedNoise] }
const frozenSummary = 'frozen: PR 1 round 40 has streak 2; continue_past_freeze not supplied'
assert('frozen fixture has 32 table rows and 200 residual classes',
  frozenPayload.table.length === 32 && frozenPayload.residual_classes.length === 200)
checkDelivered('frozen', typedStop(frozenSummary, frozenPayload), frozenSummary, frozenPayload,
  ['pr_repo', 'pr_number', 'prior_round', 'streak', 'underlying_verdict', 'touched_domains'], true)
// ledger-history-incomplete: 300 long ledger errors through validateLedger itself.
const manyErrors = Array.from({ length: 300 }, (_, i) => ({ comment_id: i + 1, kind: 'invalid-record',
  reason: `trusted marker ${i} failed to parse   ` + 'e'.repeat(200) }))
const historyStop = caught(() => validateLedger({ ...ledger([]), ledger_errors: manyErrors }, 'o/r', 1))
checkDelivered('ledger-history-incomplete', historyStop,
  'ledger-history-incomplete: marker history has invalid or unknown trust',
  { code: 'ledger-history-incomplete', ledger_errors: manyErrors }, [], true)
assert('ledger-history-incomplete keeps every error on the in-process property',
  historyStop?.code === 'ledger-history-incomplete' && sameData(historyStop.errors, manyErrors))
// ledger-record-too-large: 200 findings with long titles through composeRecord itself.
const tooLargeFindings = Array.from({ length: 200 }, (_, i) => ({ file: `f${i}.js`,
  title: `long finding ${i}: ` + 't'.repeat(400), severity: 'P2', refuted: false, lenses: ['lens'] }))
const tooLargeStop = caught(() => composeRecord(one, sizedCollected, tooLargeFindings, 'BORDERLINE', emptyRed, false,
  ['ci', 'security']))
const tooLargeChars = tooLargeStop?.estimated_chars
checkDelivered('ledger-record-too-large', tooLargeStop,
  `ledger-record-too-large: round 2 record body would be about ${tooLargeChars} characters ` +
    '(GitHub comment limit 65536); nothing was posted',
  { code: 'ledger-record-too-large', estimated_chars: tooLargeChars, limit: 65536, pr_repo: 'o/r', pr_number: 1,
    round: 2, verdict: 'BORDERLINE', underlying_verdict: 'BORDERLINE', touched_domains: ['ci', 'security'],
    live: { P1: 0, P2: 200, P3: 0 }, red_first_status: 'not-applicable',
    findings: tooLargeFindings.map(({ file, severity, title }) => ({ file, severity, title })) },
  ['estimated_chars', 'round', 'verdict', 'underlying_verdict', 'touched_domains'], true)
assert('ledger-record-too-large keeps its in-process size properties',
  tooLargeStop?.code === 'ledger-record-too-large' && tooLargeChars > 65536 && tooLargeStop.limit === 65536)
// ledger-write-failed: a small payload passes through unchanged.
const writeFailedPayload = { code: 'ledger-write-failed', reason: 'three posting attempts exhausted with unchanged trusted history',
  record_path: '/tmp/review-adversarial-first.abcdef/round.json', ledger_path: '/tmp/review-adversarial-first.abcdef/ledger.json',
  driver_dir: '/home/u/.claude/scripts', pr_repo: 'o/r', pr_number: 1, record_written: true, pending_mismatch: false,
  verdict: 'CLEAN', underlying_verdict: 'CLEAN', touched_domains: ['security'] }
const writeFailedSummary = 'ledger-write-failed: three posting attempts exhausted with unchanged trusted history'
const writeFailedStop = typedStop(writeFailedSummary, writeFailedPayload, { record_written: true })
checkDelivered('ledger-write-failed', writeFailedStop, writeFailedSummary, writeFailedPayload,
  ['verdict', 'underlying_verdict', 'touched_domains', 'pending_mismatch'], false)
assert('a typed stop keeps its code and extra properties', writeFailedStop.code === 'ledger-write-failed' &&
  writeFailedStop.record_written === true)
// Scalars are never shortened: past the limit with every array empty, only the
// code survives, named as over the limit.
const scalarHeavy = typedStop('scalar-heavy stop', { code: 'x', reason: 's'.repeat(12000), items: [1, 2, 3] })
assert('a payload whose scalars alone exceed the limit delivers only its code',
  scalarHeavy.message.length <= stopLimit &&
  sameData(renderedPayload(scalarHeavy), { code: 'x', truncated: 'payload exceeds the delivery limit' }))
// A summary line past TYPED_STOP_SUMMARY_LIMIT is cut first, so it never costs the
// payload a field.
const longSummary = typedStop('z'.repeat(20000), { code: 'y', items: [1] })
assert('a summary past its limit is cut to 2000 characters and the payload survives exactly',
  longSummary.message.length <= stopLimit && longSummary.message.startsWith('zzz') &&
  longSummary.message.split('\n')[0].length === 2000 && longSummary.message.split('\n')[0].endsWith('…') &&
  sameData(renderedPayload(longSummary, worstStack), { code: 'y', items: [1] }))
// A cut never splits a UTF-16 surrogate pair: a pair straddling it is dropped whole.
const loneSurrogate = (text) => /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(text)
const pairHead = typedStop(`${'z'.repeat(1998)}\u{1F600}${'z'.repeat(50)}`, { code: 'y' }).message.split('\n')[0]
assert('a summary cut through a surrogate pair drops the whole pair',
  !loneSurrogate(pairHead) && pairHead === `${'z'.repeat(1998)}…`)
assert('clipText keeps short text, cuts long text to its limit, and never splits a pair',
  typeof clipText === 'function' && clipText('abc', 3) === 'abc' && clipText('abcd', 3) === 'ab…' &&
  clipText(`a\u{1F600}b`, 3) === 'a…' && clipText(`ab\u{1F600}`, 4) === `ab\u{1F600}`)
// A scratch directory name is bounded, so every path built from it (and every
// red-first-stage-failed message quoting one) stays far below the render cut.
assert('a scratch directory suffix is 6 to 64 characters',
  isRoundDirectory(`/tmp/review-adversarial-first.${'a'.repeat(64)}`, '/tmp') &&
  !isRoundDirectory(`/tmp/review-adversarial-first.${'a'.repeat(65)}`, '/tmp') &&
  isRoundDirectory('/tmp/review-adversarial-first.abcdef', '/tmp') &&
  !isRoundDirectory('/tmp/review-adversarial-first.abcde', '/tmp'))
// A payload the old 10000-character cap admitted unchanged fits the bare rendering,
// but a worst-case stack pushes it past 11024; the 8000 cap must shorten it.
const nearPayload = { code: 'near-limit', items: Array.from({ length: 95 }, (_, i) => `item ${i} ${'n'.repeat(90)}`) }
const nearMessage = `near-limit stop\npayload=${JSON.stringify(nearPayload)}`
assert('near-limit fixture sits between the safe and the old cap',
  nearMessage.length > 8507 && nearMessage.length <= 10000 &&
  runtimeRender({ name: 'Error', message: nearMessage }, worstStack).includes('characters truncated'))
const nearStop = typedStop('near-limit stop', nearPayload)
const nearGot = renderedPayload(nearStop, worstStack)
assert('a near-limit typed stop survives the worst-case stack with its array shortened and counted',
  nearGot !== null && nearGot.code === 'near-limit' && nearGot.truncated?.items === 95 &&
  nearGot.items.length > 0 && sameData(nearGot.items, nearPayload.items.slice(0, nearGot.items.length)) &&
  !runtimeRender(nearStop, worstStack).includes('characters truncated'))

// Live PR #1390 round 4: a Collect agent abbreviated the full 22.5 KB ledger
// (RED test output) instead of echoing it. Agents now carry U1's compact view.
assertThrows('a ledger that is not U1 compact view is refused', () =>
  validateLedger({ target: { repo: 'o/r', pr: 1 }, rounds: [], ledger_errors: [] }, 'o/r', 1), 'compact')
assertThrows('an abbreviated RED test list still fails closed', () => validateLedger(ledger([{ ...one[0],
  record: { ...one[0].record, red_first: { status: 'inconclusive', tests: '[omitted for size]' } } }]), 'o/r', 1),
  'invalid trusted envelope')
// Pro gate round 1 at e2688e9f: the never-red carry reads historical case names,
// so history whose RED tests lack them is refused here, not crashed on in Judge.
const withTests = (tests) => ledger([{ ...one[0],
  record: { ...one[0].record, red_first: { status: 'never-red', tests } } }])
const namedTest = { path: 'tests/x.test.sh', pre_fix: sha(1), status: 'ran', exempt: false,
  exempt_reason: null, cases: [{ name: 'missed' }] }
assertDoesNotThrow('compact history with name-only cases is admitted',
  () => validateLedger(withTests([namedTest]), 'o/r', 1))
assertThrows('compact history whose RED test lacks cases is refused', () => {
  const { cases, ...noCases } = namedTest
  validateLedger(withTests([noCases]), 'o/r', 1)
}, 'invalid trusted envelope')
assertThrows('compact history whose case lacks a name is refused', () =>
  validateLedger(withTests([{ ...namedTest, cases: [{ status: 'never-red' }] }]), 'o/r', 1), 'invalid trusted envelope')

// Later in round 4 a Readback agent re-typing history "corrected" a duplicate
// round and failed a correct post. U1 confirm now compares; agents carry its outcome.
assert('workflow reads the U1 confirm outcome', typeof confirmOutcome === 'function')
const outcome = (c) => { try { return confirmOutcome(c, recordFrozen, 2) } catch (error) { return error } }
const settled = { round: null, comment_id: null, reason: null }
if (typeof confirmOutcome === 'function') {
  assert('an exact single append confirms', recordFrozen.round === 3 &&
    outcome({ status: 'appended', rounds: 3, round: 3, comment_id: 7, reason: null }) === true)
  assert('unchanged history is not confirmed', outcome({ ...settled, status: 'unchanged', rounds: 2 }) === false)
  const conflict = outcome({ ...settled, status: 'conflict', rounds: 3,
    reason: 'appended round 3 differs from the pending record' })
  assert('a conflict stops with U1 reason', conflict instanceof Error &&
    conflict.message.includes('differs from the pending record'))
  for (const bad of [
    { status: 'appended', rounds: 3, round: 4, comment_id: 7, reason: null },
    { status: 'appended', rounds: 4, round: 3, comment_id: 7, reason: null },
    { status: 'appended', rounds: 3, round: 3, comment_id: '7', reason: null },
    { ...settled, status: 'unchanged', rounds: 3 },
    { ...settled, status: 'conflict', rounds: 3 },
    { ...settled, status: 'ok', rounds: 3 },
    null,
  ]) {
    assert(`confirm outcome ${JSON.stringify(bad)} neither confirms nor permits retry`, outcome(bad) instanceof Error)
  }
}

console.log(`RESULT ${nodePass} ${nodeFail}`)
process.exit(nodeFail > 0 ? 1 : 0)
NODE
} > "$TMP/all.js"

# Run one Node assertion file; it prints FAIL lines plus a final "RESULT <pass> <fail>".
run_node() {
  local label=$1
  shift
  local output status result_line node_pass node_fail
  output=$(node "$@")
  status=$?
  echo "$output" | grep -v '^RESULT ' || true
  result_line=$(echo "$output" | grep '^RESULT ' || echo "RESULT 0 1")
  node_pass=$(echo "$result_line" | awk '{print $2}')
  node_fail=$(echo "$result_line" | awk '{print $3}')
  pass=$((pass + node_pass))
  fail=$((fail + node_fail))
  if [ "$status" -ne 0 ] || [ "$node_fail" -gt 0 ]; then
    echo "FAIL: review-adversarial-first $label assertions failed ($node_fail failure(s), node exit $status)" >&2
    exit 1
  fi
}

# U1's own record bounds, read from review-rounds.py so composeRecord is held to
# them rather than to copies typed into this file.
python3 - "$TMP" "$REPO" <<'PY' || { echo "FAIL: cannot read U1 MAX_* bounds from review-rounds.py" >&2; exit 1; }
import importlib.util
import json
import pathlib
import sys

root, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("review_rounds", repo / "scripts/review-rounds.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
names = ("MAX_FINDINGS", "MAX_RESIDUAL_CLASSES", "MAX_RED_FIRST_TESTS", "MAX_RED_FIRST_CASES")
(root / "u1-bounds.json").write_text(json.dumps({name: getattr(module, name) for name in names}))
PY

run_node pure-logic "$TMP/all.js" "$TMP"
python3 - "$TMP" "$REPO" <<'PY' || exit 1
import importlib.util
import json
import pathlib
import sys

root, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("review_rounds", repo / "scripts/review-rounds.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
names = ("recordFrozen", "recordOverride", "firstRecord", "inconclusive", "unsupported", "unverifiable", "fileLevel",
         "unicode", "ordinaryProse")
for name in names:
    errors = module.validate_record(json.loads((root / (name + ".json")).read_text()))
    if errors:
        raise SystemExit(f"FAIL: U1 validate_record rejected {name}: {errors}")
print(f"U1 validate_record: {len(names)}/{len(names)} composed record variants pass")
# Contract S: the workflow's estimate must never undercount U1's real comment body.
sizes = sorted(root.glob("size-*.json"))
if len(sizes) != 11:
    raise SystemExit(f"FAIL: expected 11 workflow size estimates, found {len(sizes)}")
for path in sizes:
    doc = json.loads(path.read_text())
    actual = len(module.compose_body(doc["record"]))
    if not actual <= doc["estimate"] <= actual + 1024:
        raise SystemExit(f"FAIL: {path.name}: estimate {doc['estimate']} vs compose_body length {actual}")
print(f"U1 compose_body: {len(sizes)}/{len(sizes)} workflow size estimates bound the real body within 1024")
PY

# The confirmOutcome assertions above use hand-typed outcome literals; these
# are REAL U1 confirm_round outcomes. A JS-composed round-2 record is posted
# through U1's own compose_body and read back through a fake gh (the FakeGh
# pattern of test_review_rounds.py), so a U1 output-shape change fails here.
python3 - "$TMP" "$REPO" <<'PY' || exit 1
import importlib.util
import json
import pathlib
import sys

root, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("review_rounds", repo / "scripts/review-rounds.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
OPERATOR_ID = 101


class FakeGh:
    """Stands in for gh_lines(path, jq): the operator's numeric ID and the PR comments."""

    def __init__(self, comments):
        self.comments = comments

    def __call__(self, path, jq):
        return [OPERATOR_ID] if path == "user" else list(self.comments)


def comment(comment_id, body):
    return {"id": comment_id, "body": body, "created_at": f"2026-09-25T03:0{comment_id}:00Z",
            "user": {"id": OPERATOR_ID}}


def posted(comment_id, record):
    return comment(comment_id, module.compose_body(record))


pending = json.loads((root / "inconclusive.json").read_text())
prior = dict(json.loads((root / "firstRecord.json").read_text()), head="1" * 40, patch_id="a" * 40)
for name, record in (("pending", pending), ("prior", prior)):
    errors = module.validate_record(record)
    if errors:
        raise SystemExit(f"FAIL: U1 validate_record rejected confirm fixture {name}: {errors}")
history = [posted(1, prior)]
captured = module.compact_ledger(module.read_rounds("o/r", 1, gh=FakeGh(history)))
cases = {
    "appended": (history + [posted(3, pending)], "appended", None),
    "unchanged": (history, "unchanged", None),
    "differs": (history + [posted(3, dict(pending, diff_lines=pending["diff_lines"] + 1))], "conflict",
                "differs from the pending record"),
    "ledger errors": (history + [comment(2, module.MARKER + "\nno json"), posted(3, pending)], "conflict",
                      "trusted ledger errors changed"),
    "history changed": ([posted(1, dict(prior, diff_lines=prior["diff_lines"] + 1)), posted(3, pending)], "conflict",
                        "trusted history before the pending round changed"),
    "two appends": (history + [posted(3, pending), posted(4, pending)], "conflict", "more than one round appended"),
}
outcomes = {}
for name, (comments, status, reason) in cases.items():
    outcome = module.confirm_round("o/r", 1, captured, pending, gh=FakeGh(comments))
    if outcome.get("status") != status or (reason and reason not in str(outcome.get("reason"))):
        raise SystemExit(f"FAIL: U1 confirm_round fixture {name!r} gave {outcome}")
    outcomes[name] = outcome
(root / "confirm.json").write_text(json.dumps({"pending": pending, "prior_rounds": len(captured["rounds"]),
                                               "outcomes": outcomes}))
print(f"U1 confirm_round: {len(outcomes)}/{len(cases)} real outcomes produced for confirmOutcome")

# The never-red flagging round as production history holds it: posted through
# compose_body, read back by read_rounds and compacted by compact_ledger.
flagged = json.loads((root / "neverFlagged.json").read_text())
first = dict(flagged["first"], head="1" * 40, patch_id="a" * 40)
for name, record in (("first", first), ("flagging", flagged["flagging"])):
    errors = module.validate_record(record)
    if errors:
        raise SystemExit(f"FAIL: U1 validate_record rejected never-red fixture {name}: {errors}")
full = module.read_rounds("o/r", 1, gh=FakeGh([posted(1, first), posted(2, flagged["flagging"])]))
if [entry["round"] for entry in full["rounds"]] != [1, 2] or full["ledger_errors"]:
    raise SystemExit(f"FAIL: U1 read_rounds did not return the two never-red fixture rounds: {full}")
(root / "neverLedgers.json").write_text(json.dumps({"full": full, "compact": module.compact_ledger(full)}))
print("U1 compact_ledger: never-red flagging history produced for carriedNeverRed")
PY

{
  printf '%s\n' "$rounds"
  cat <<'NODE'

let nodePass = 0
let nodeFail = 0
function assert(name, cond) {
  if (cond) {
    nodePass++
  } else {
    nodeFail++
    console.error(`FAIL: ${name}`)
  }
}
const fs = require('fs')
const { pending, prior_rounds: priorRounds, outcomes } =
  JSON.parse(fs.readFileSync(`${process.argv[2]}/confirm.json`, 'utf8'))
const decide = (outcome) => { try { return confirmOutcome(outcome, pending, priorRounds) } catch (error) { return error } }
assert('a real U1 appended outcome confirms the round', decide(outcomes.appended) === true)
assert('a real U1 unchanged outcome permits a bounded retry', decide(outcomes.unchanged) === false)
const conflicts = ['differs', 'ledger errors', 'history changed', 'two appends']
assert('every real U1 outcome fixture is decided here', sameData(Object.keys(outcomes).sort(),
  ['appended', 'unchanged', ...conflicts].sort()))
for (const name of conflicts) {
  const decided = decide(outcomes[name])
  assert(`a real U1 "${name}" conflict stops with U1's own reason`, decided instanceof Error &&
    decided.message === `Ledger readback conflicts with the captured trusted history: ${outcomes[name].reason}`)
}

// Pro gate round 1 at e2688e9f: the never-red carry ran only on full records in
// the pure-logic suite, but Collect always supplies U1's compact view, whose
// transcript omissions made the next round throw in Judge. Carry from the real
// compact history of a round that flagged `missed` against sha(1).
const sha = (n) => n.toString(16).padStart(40, '0')
const { compact: neverCompact } = JSON.parse(fs.readFileSync(`${process.argv[2]}/neverLedgers.json`, 'utf8'))
const carriedPath = 'tests/x.test.sh'
const neverTitle = `never-red regression test: ${carriedPath}::missed`
const prFiles = [carriedPath, 'a.js']
const run = (head, tests = [], requested = []) => ({ head, base_branch: sha(90), overlay: [], exempt: [],
  unchanged: [], requested, tests })
const ranAt = (preFix, names) => ({ path: carriedPath, pre_fix: preFix, status: 'ran', command: 'bash x',
  reason: null, exempt: false, exempt_reason: null,
  cases: names.map((name) => ({ name, pre_fix: 'fail', head: 'pass', status: 'verified' })) })
let compactHistory = null
try { compactHistory = validateLedger(neverCompact, 'o/r', 1) } catch (error) { compactHistory = error }
assert('the real U1 compact never-red history is admitted', Array.isArray(compactHistory) &&
  compactHistory.length === 2 && compactHistory[1].record.red_first.tests.every((t) =>
    !Object.hasOwn(t, 'command') && !Object.hasOwn(t, 'reason')))
const carry = (report, files = prFiles, removedAtHead = new Set()) => {
  try { return carriedNeverRed(compactHistory, report, files, removedAtHead).map((f) => f.title) } catch (error) {
    return `threw: ${error.message}`
  }
}
if (Array.isArray(compactHistory)) {
  const probe = carry(run(sha(3)))
  assert(`carrying from compact history does not throw${typeof probe === 'string' ? ` (${probe})` : ''}`,
    Array.isArray(probe))
  assert('a same-head re-run on compact history keeps the never-red P1',
    sameData(carry(run(sha(2))), [neverTitle]))
  assert('a source-only round on compact history keeps the never-red P1',
    sameData(carry(run(sha(3))), [neverTitle]))
  assert('a compact-history run from the flagging revision without the case clears it',
    sameData(carry(run(sha(3), [ranAt(sha(1), ['kept'])], [{ path: carriedPath, pre_fix: sha(1) }])), []))
  assert('a compact-history run from a later revision without the case keeps it',
    sameData(carry(run(sha(3), [ranAt(sha(2), ['kept'])], [{ path: carriedPath, pre_fix: sha(2) }])), [neverTitle]))
  assert('a compact-history run naming the case clears it',
    sameData(carry(run(sha(3), [ranAt(sha(2), ['missed'])], [{ path: carriedPath, pre_fix: sha(2) }])), []))
  assert('deleting the test at head clears the carry on compact history',
    sameData(carry(run(sha(3)), prFiles, new Set([carriedPath])), []))
  assert('a test that left the PR clears the carry on compact history', sameData(carry(run(sha(3)), ['a.js']), []))
}
console.log(`RESULT ${nodePass} ${nodeFail}`)
process.exit(nodeFail > 0 ? 1 : 0)
NODE
} > "$TMP/confirm.js"
run_node confirm-outcome "$TMP/confirm.js" "$TMP"

# ---------------------------------------------------------------------------
# Whole-script run. The assertions above call validateCollected and
# checkLensCoverage directly, which cannot catch the script calling them late,
# out of order, or not at all (test the call order, not the callees). This
# executes the REAL shipped script top to bottom with stubbed agent() and
# parallel(). It also runs every path-target diff command Collect's own prompt
# instructs, in a scratch git repo, and requires the gate to accept its first
# line: a gate stricter than the instructions it guards fails every run.
cat > "$TMP/flow.js" <<'NODE'
const fs = require('fs')
const path = require('path')
const { execFileSync, spawnSync } = require('child_process')

const [, , src, tmp] = process.argv
const body = fs.readFileSync(src, 'utf8').replace('export const meta =', 'const meta =')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const runScript = new AsyncFunction('agent', 'parallel', 'phase', 'log', 'args', body)

let nodePass = 0
let nodeFail = 0
function assert(name, cond) {
  if (cond) {
    nodePass++
  } else {
    nodeFail++
    console.log(`FAIL: ${name}`)
  }
}

const sha = (n) => n.toString(16).padStart(40, '0')
const record = (n, count, lines, streak, extra = {}) => ({
  schema: 'review-adversarial-first/round/v1', round: n, head: extra.head || sha(n),
  patch_id: extra.patch || sha(100 + n), diff_lines: lines,
  verdict: extra.verdict || 'BORDERLINE', underlying_verdict: 'BORDERLINE',
  live: { P1: count, P2: 0, P3: 0 }, findings: extra.findings || [],
  red_first: extra.red || { status: 'not-applicable', tests: [] },
  streak, override: !!extra.override, rerun: !!extra.rerun, ledger_errors: [],
})
const entry = (n, count, lines, streak, extra) => ({ round: n, rerun: !!extra?.rerun,
  comment_id: n, author_id: 12, created_at: '2026-09-24T00:00:00Z',
  record: record(n, count, lines, streak, extra) })
// U1 read: `--compact` drops each RED test's command and reason and keeps only
// case names; checked below against U1's own compact_ledger output.
const compactOf = (r) => (Array.isArray(r?.red_first?.tests) ? { ...r, red_first: { ...r.red_first,
  tests: r.red_first.tests.map(({ command, reason, ...rest }) => (Array.isArray(rest.cases)
    ? { ...rest, cases: rest.cases.map(({ name }) => ({ name })) } : rest)) } } : r)
const fullLedger = (rounds = []) => ({ target: { repo: 'o/r', pr: 1 }, rounds, ledger_errors: [] })
const ledger = (rounds = []) => ({ ...fullLedger(rounds.map((e) => ({ ...e, record: compactOf(e.record) }))),
  view: 'compact' })
const GOOD_COLLECT = {
  files: ['a.js'], pr_files: ['a.js'], diff_files: ['a.js'],
  scratch_dir: path.join(tmp, 'review-adversarial-first.fixture0001'),
  driver_dir: '/home/user/.claude/scripts', driver_source: 'installed', drivers_ready: true,
  pr_identity: { repo: 'o/r', number: 1, head_sha: sha(6), base_sha: sha(90),
    head_repo: 'o/r', base_repo: 'o/r', head_repo_id: 10, base_repo_id: 10,
    author_id: 12, operator_id: 12 },
  diff_path: path.join(tmp, 'review-adversarial-first.fixture0001/diff.patch'),
  diff_line_count: 40, first_line: 'diff --git a/a.js b/a.js',
  is_pr: true, pr_repo: 'o/r', pr_number: 1, repo_root: '/tmp/stub-collect',
  head_sha: sha(6), base_sha: sha(90),
  confirmed_head_sha: sha(6), confirmed_base_sha: sha(90),
  patch_id: sha(106), patch_sha256: 'ab'.repeat(32), diff_lines: 100,
  ledger_path: path.join(tmp, 'review-adversarial-first.fixture0001/ledger.json'), ledger: ledger(),
  selection: { previous_head: null, head_sha: sha(6), base_sha: sha(90),
    changed_paths: [], blob_facts: [], error: null },
}
const FULL_READ = () => ({ findings: [], diff_lines_read: 40 })
// Typed stops reach the caller as message text only; `payload=` is the second line.
const payloadOf = (error) => {
  const lines = String(error).split('\n')
  if (lines.length !== 2 || !lines[1].startsWith('payload=')) return null
  try { return JSON.parse(lines[1].slice('payload='.length)) } catch { return null }
}
const deepSame = (a, b) => {
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((v, i) => deepSame(v, b[i]))
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const keys = Object.keys(a).sort()
    return deepSame(keys, Object.keys(b).sort()) && keys.every((key) => deepSame(a[key], b[key]))
  }
  return a === b
}
// A PR stop after Collect's checks runs only the verified ledger re-read first.
const onlyCollected = (calls) => deepSame(calls.map((c) => c.phase), ['Collect', 'LedgerFileRead'])
// The hand mirror above must equal U1's compact_ledger on a RED-bearing history
// (the never-red fixture the U1 block wrote), or every whole-script run below
// exercises a view production never delivers.
const u1Ledgers = JSON.parse(fs.readFileSync(path.join(tmp, 'neverLedgers.json'), 'utf8'))
assert('compactOf mirrors U1 compact_ledger on a history holding RED cases',
  u1Ledgers.full.rounds.some((e) => e.record.red_first.tests.some((t) => t.cases.length)) &&
  deepSame(ledger(u1Ledgers.full.rounds), u1Ledgers.compact))
const tableOf = (rounds) => rounds.map((e) => ({ round: e.round, head: e.record.head, verdict: e.record.verdict,
  live: e.record.live, diff_lines: e.record.diff_lines, streak: e.record.streak, rerun: e.rerun }))
const withHistory = (prior, updates = {}) => ({ ...GOOD_COLLECT, ...updates,
  ledger: ledger(prior), selection: { ...GOOD_COLLECT.selection,
    previous_head: prior.at(-1)?.record.head || null, ...updates.selection } })

// Offline StructuredOutput boundary double, deliberately limited to the schema
// keywords Collect uses. Unsupported keywords fail loudly instead of silently
// weakening this fixture. This tests the supplied contract, not live SDK retry.
function checkCollectSchema(schema, value, at = 'Collect') {
  const supported = ['type', 'properties', 'items', 'required', 'enum', 'pattern',
    'minimum', 'minLength', 'maxLength']
  for (const key of Object.keys(schema)) {
    if (!supported.includes(key)) throw new Error(`unsupported schema keyword: ${key}`)
  }
  const types = {
    object: value !== null && typeof value === 'object' && !Array.isArray(value),
    array: Array.isArray(value), string: typeof value === 'string',
    boolean: typeof value === 'boolean', integer: Number.isInteger(value),
  }
  if (schema.type && !types[schema.type]) throw new Error(`${at}: type`)
  if (schema.enum && !schema.enum.includes(value)) throw new Error(`${at}: enum`)
  if (schema.pattern && !new RegExp(schema.pattern).test(value)) throw new Error(`${at}: pattern`)
  if (schema.minimum !== undefined && value < schema.minimum) throw new Error(`${at}: minimum`)
  if (schema.minLength !== undefined && value.length < schema.minLength) throw new Error(`${at}: minLength`)
  if (schema.maxLength !== undefined && value.length > schema.maxLength) throw new Error(`${at}: maxLength`)
  for (const key of schema.required || []) {
    if (!Object.hasOwn(value, key)) throw new Error(`${at}.${key}: required`)
  }
  for (const [key, child] of Object.entries(schema.properties || {})) {
    if (Object.hasOwn(value, key)) checkCollectSchema(child, value[key], `${at}.${key}`)
  }
  if (schema.items) value.forEach((item, i) => checkCollectSchema(schema.items, item, `${at}[${i}]`))
}

// These agent stubs exercise call order and readback decisions, not live GH.
async function run(collect, lens, options = {}) {
  const calls = []
  const logs = []
  let lastPost = null
  const manifestPath = `${collect.scratch_dir}/manifest.json`
  const filesPath = `${collect.scratch_dir}/files.txt`
  const reportPath = `${collect.scratch_dir}/report.json`
  const recordPath = `${collect.scratch_dir}/round.json`
  // Each stub invocation starts without a previous invocation's pending record.
  fs.rmSync(recordPath, { force: true })
  const agent = async (prompt, opts) => {
    calls.push({ phase: opts?.phase, prompt, opts })
    if (opts?.phase === 'Collect') {
      if (options.collectFiles) collect = options.collectFiles(prompt)
      if (options.checkCollectSchema) {
        try { checkCollectSchema(opts.schema, collect) } catch (error) {
          error.code = 'collect-schema-rejected'
          throw error
        }
      }
      // The shell redirects U1's compact read into ledger.json; the agent returns
      // its copy, which diskLedger lets a test make differ from the file.
      if (collect?.is_pr && collect.ledger && typeof collect.ledger_path === 'string' &&
          collect.ledger_path.startsWith(`${collect.scratch_dir}/`)) {
        fs.mkdirSync(collect.scratch_dir, { recursive: true })
        fs.writeFileSync(collect.ledger_path, JSON.stringify(options.diskLedger || collect.ledger, null, 2))
      }
      return collect
    }
    if (opts?.phase === 'LedgerFileRead') {
      if (options.ledgerReadThrows) throw new Error('Read failed: EACCES')
      if (options.ledgerReadNull) return null
      const named = prompt.match(/Read the ENTIRE contents of the existing file (\S+) with the Read tool/)
      if (!named) throw new Error('LedgerFileRead prompt names no file')
      try {
        return { ledger: JSON.parse(fs.readFileSync(named[1], 'utf8')) }
      } catch (error) { throw new Error(`Read failed: ${error.message}`) }
    }
    if (opts?.phase === 'Lenses') return lens()
    if (opts?.phase === 'RedFirst') {
      const stage = options.redStage === undefined
        ? { manifest_path: manifestPath, files_path: filesPath, report_path: reportPath,
            report: { head: collect.head_sha, base_branch: collect.base_sha,
              tests: [], unchanged: [], overlay: [], exempt: [], requested: [] } }
        : options.redStage
      if (!stage) return stage
      fs.mkdirSync(collect.scratch_dir, { recursive: true })
      const match = prompt.match(/return manifest_path: (\[[^\n]*\])\./)
      if (options.omitRedFile) {
        for (const file of [manifestPath, filesPath, reportPath]) fs.rmSync(file, { force: true })
      } else {
        fs.writeFileSync(stage.manifest_path, options.diskManifest || match?.[1] || '[]')
        fs.writeFileSync(stage.files_path, options.diskFiles || collect.files.join('\n') + '\n')
        // The shell redirects red-first.sh stdout straight to report.json, so the
        // fixture report is the runner's output; the agent returns what it Reads.
        fs.writeFileSync(stage.report_path, JSON.stringify(stage.report))
      }
      const { report: runnerReport, ...paths } = stage
      return { ...paths, exit_code: options.redExit ?? 0, report: options.agentReport ||
        (options.omitRedFile ? runnerReport : JSON.parse(fs.readFileSync(stage.report_path, 'utf8'))),
        ...(options.redDiagnostic !== undefined ? { diagnostic: options.redDiagnostic } : {}) }
    }
    if (opts?.phase === 'RedFileRead') {
      if (options.fileReadOverride) return options.fileReadOverride
      // A real reader opens the paths its prompt names, wherever they point.
      const named = prompt.match(/Manifest JSON: (\S+)\. Full newline-separated file list: (\S+)\. Report JSON: (\S+)\./)
      if (!named) throw new Error('RedFileRead prompt names no files')
      try {
        return { manifest: JSON.parse(fs.readFileSync(named[1], 'utf8')),
          files: fs.readFileSync(named[2], 'utf8').trimEnd().split('\n'),
          report: JSON.parse(fs.readFileSync(named[3], 'utf8')) }
      } catch (error) { throw new Error(`Read failed: ${error.message}`) }
    }
    if (opts?.phase === 'Cleanup') {
      if (options.cleanupThrows) throw new Error('unlink denied')
      return { pending: options.cleanupPending || [] }
    }
    if (opts?.phase === 'Record') {
      const made = JSON.parse(prompt.split('\n').find((line) => line.startsWith('{"schema":')))
      const attempt = calls.filter((c) => c.phase === 'Record').length
      if (options.recordBeforeWriteThrows) throw new Error('Write failed before record file existed')
      fs.mkdirSync(collect.scratch_dir, { recursive: true })
      if (attempt === 1) {
        fs.writeFileSync(recordPath, JSON.stringify(options.diskTamper ? options.diskTamper(made) : made))
      }
      // A later Record agent has write access to the pending file too.
      if (attempt === options.rewriteAt) fs.writeFileSync(recordPath, JSON.stringify({ ...made, head: sha(98) }))
      // U1 posts the pending file, not the prompt's JSON.
      const onDisk = JSON.parse(fs.readFileSync(recordPath, 'utf8'))
      const posted = !!((!options.failPosts && (!options.failUntil || attempt > options.failUntil) &&
        !options.recordThrowsUnposted) || options.acceptedError || options.conflict || options.recordThrows)
      const prior = collect.ledger.rounds
      const newEntry = { round: made.round, rerun: made.rerun, comment_id: prior.length + 1,
        author_id: 12, created_at: '2026-09-24T00:00:00Z',
        record: options.conflict ? { ...onDisk, head: sha(99) } : onDisk }
      lastPost = { rounds: posted && !options.invisiblePost ? [...prior, newEntry] : prior,
        ledger_errors: options.readbackErrors || [] }
      if (options.recordThrows || options.recordThrowsUnposted) throw new Error('post response lost')
      return { record_path: recordPath, write_confirmed: true,
        post_ok: posted && !options.acceptedError,
        post_error: posted && !options.acceptedError ? undefined : 'gh pr comment: timeout' }
    }
    if (opts?.phase === 'Readback') {
      if (options.readUnavailable ||
          calls.filter((c) => c.phase === 'Readback').length >= (options.readUnavailableFrom ?? Infinity)) {
        throw new Error(options.readbackError ?? 'gh api user failed')
      }
      // Test double for U1 `confirm` (its comparisons are unit-tested in Python):
      // current trusted history vs the captured compact ledger and pending file.
      if (!/ confirm --repo .* --ledger .* --record /.test(prompt)) throw new Error('readback did not run U1 confirm')
      if (!fs.existsSync(recordPath)) throw new Error(`confirm: --record ${recordPath}: No such file`)
      const pending = JSON.parse(fs.readFileSync(recordPath, 'utf8'))
      const captured = collect.ledger
      const current = lastPost || { rounds: captured.rounds, ledger_errors: captured.ledger_errors }
      const n = captured.rounds.length
      const confirmation = { status: 'conflict', rounds: current.rounds.length, round: null,
        comment_id: null, reason: null }
      const appendedEntry = current.rounds[n]
      if (JSON.stringify(current.ledger_errors) !== JSON.stringify(captured.ledger_errors)) {
        confirmation.reason = 'trusted ledger errors changed since capture'
      } else if (current.rounds.length === n) {
        confirmation.status = 'unchanged'
      } else if (current.rounds.length > n + 1) {
        confirmation.reason = 'more than one round appended since capture'
      } else if (JSON.stringify(appendedEntry.record) !== JSON.stringify(pending) ||
          appendedEntry.round !== pending.round || appendedEntry.rerun !== pending.rerun) {
        confirmation.reason = `appended round ${appendedEntry.round} differs from the pending record`
      } else {
        Object.assign(confirmation, { status: 'appended', round: appendedEntry.round,
          comment_id: appendedEntry.comment_id })
      }
      const readbackAttempt = calls.filter((c) => c.phase === 'Readback').length
      return { confirmation,
        ...(!options.dropRecordOnDisk && readbackAttempt < (options.dropRecordOnDiskFrom ?? Infinity)
          ? { record_on_disk: pending } : {}) }
    }
    throw new Error('unexpected stage')
  }
  const parallel = (thunks) => Promise.all(thunks.map((t) => t().catch(() => null)))
  let result = null
  let error = null
  try {
    result = await runScript(agent, parallel, () => {}, (msg) => logs.push(String(msg)),
      { target: options.target || '1', repo: 'o/r', scratch_root: tmp,
        ...(collect.ledger?.rounds?.length && !options.noTrust ? { trusted_head_sha: collect.head_sha } : {}),
        ...options.args })
  } catch (e) { error = e }
  const lensCalls = calls.filter((c) => c.phase === 'Lenses')
  const verdictLogged = logs.some((l) => l.startsWith('Verdict:'))
  return { calls, lensCalls, result, error, verdictLogged, logs }
}

;(async () => {
  const bad = await run({ ...GOOD_COLLECT, first_line: 'commit 1efff622' }, FULL_READ)
  assert('a non-diff Collect first_line throws', Boolean(bad.error) && /first_line/.test(bad.error.message))
  assert('a rejected Collect spawns no lens', bad.lensCalls.length === 0)
  assert('a rejected Collect logs no verdict', !bad.verdictLogged)

  let n = 0
  const short = await run(GOOD_COLLECT, () => ({ findings: [], diff_lines_read: n++ === 0 ? 10 : 40 }))
  assert('one under-reading lens throws', Boolean(short.error) && /Lens coverage incomplete/.test(short.error.message))
  assert('an under-read run returns no verdict', short.result === null)
  assert('an under-read run logs no verdict', !short.verdictLogged)

  let m = 0
  const dead = await run(GOOD_COLLECT, () => (m++ === 0 ? null : FULL_READ()))
  assert('a lens that returns nothing throws', Boolean(dead.error) && /Lens coverage incomplete/.test(dead.error.message))
  assert('a dead-lens run logs no verdict', !dead.verdictLogged)

  const clean = await run(GOOD_COLLECT, FULL_READ)
  assert('a full-coverage run returns a verdict', clean.error === null && Boolean(clean.result) && clean.result.verdict === 'CLEAN')
  assert('a full-coverage run logs its verdict (positive control for the no-verdict checks)', clean.verdictLogged)
  assert('a completed numeric PR round records itself before returning',
    clean.error === null && clean.result?.rounds?.enabled === true &&
    clean.calls.some((c) => c.phase === 'Record'))
  assert('every lens prompt names the diff file and its line count',
    clean.lensCalls.length > 0 &&
    clean.lensCalls.every((c) => c.prompt.includes(GOOD_COLLECT.diff_path) && c.prompt.includes('40 lines')))
  assert('first round skips RED, posts and reads back once',
    !clean.calls.some((c) => c.phase === 'RedFirst') &&
    clean.calls.filter((c) => c.phase === 'Record').length === 1 && clean.result.rounds.round === 1)
  assert('cleanup only follows confirmed record and targets exact round files',
    clean.calls.at(-1).phase === 'Cleanup' && clean.result.rounds.scratch_cleanup_pending.length === 0 &&
    clean.calls.at(-1).prompt.includes(GOOD_COLLECT.ledger_path) &&
    clean.calls.at(-1).prompt.includes(clean.result.rounds.record_path))
  assert('PR lenses pin source inspection to git show SHA:path, not stale checkout files',
    clean.lensCalls.every((c) => c.prompt.includes(GOOD_COLLECT.repo_root) &&
      c.prompt.includes(`${GOOD_COLLECT.head_sha}:<repo-relative-path>`) &&
      c.prompt.includes('Never use checkout files')))
  // Authored CLEAN lens fixtures exercise transport, not model proof of eligibility.
  const proseLens = () => ({ ...FULL_READ(), ordinary_prose: {
    eligible: true, evidence: 'Inspected package scripts and all README consumers at captured head: human-facing only.' } })
  const proseRun = await run(GOOD_COLLECT, proseLens)
  const postedProse = proseRun.calls.find(c => c.phase === 'Record')?.prompt.split('\n')
    .find(line => line.startsWith('{"schema":'))
  assert('whole workflow transports all lens assessments into the posted revision-and-patch-bound record',
    proseRun.error === null && JSON.parse(postedProse || '{}').ordinary_prose?.base === GOOD_COLLECT.base_sha &&
    JSON.parse(postedProse || '{}').ordinary_prose?.patch_sha256 === GOOD_COLLECT.patch_sha256)
  for (const digest of [undefined, null, '', 'a'.repeat(63), 'a'.repeat(65), 'A'.repeat(64), 'g'.repeat(64),
    'a'.repeat(64) + '\n', 42, ['a'.repeat(64)]]) {
    const noDigest = await run({ ...GOOD_COLLECT, patch_sha256: digest }, proseLens)
    const posted = noDigest.calls.find(c => c.phase === 'Record')?.prompt.split('\n')
      .find(line => line.startsWith('{"schema":'))
    assert(`whole workflow remains usable without granting exemption for digest ${JSON.stringify(digest)}`,
      noDigest.error === null && noDigest.result?.verdict === 'CLEAN' && !!posted &&
      !JSON.parse(posted).ordinary_prose)
  }
  const collectSchema = proseRun.calls.find(c => c.phase === 'Collect').opts.schema
  const commonRequired = ['files', 'diff_path', 'diff_line_count', 'first_line', 'is_pr', 'scratch_dir']
  const prRequired = ['pr_files', 'diff_files', 'confirmed_head_sha', 'confirmed_base_sha',
    'pr_repo', 'pr_number', 'repo_root', 'driver_dir', 'driver_source', 'drivers_ready',
    'base_sha', 'head_sha', 'patch_id', 'diff_lines', 'ledger_path', 'ledger', 'selection', 'pr_identity']
  const branchCollect = Object.fromEntries(commonRequired.map((key) => [key, GOOD_COLLECT[key]]))
  branchCollect.is_pr = false
  const schemaBranch = await run(branchCollect, FULL_READ, { target: 'feature', checkCollectSchema: true })
  const branchSchema = schemaBranch.calls.find(c => c.phase === 'Collect').opts.schema
  assert('branch schema requires only common consumers, without PR-only data',
    deepSame([...branchSchema.required].sort(), [...commonRequired].sort()) &&
    schemaBranch.error === null && schemaBranch.result?.rounds.enabled === false &&
    deepSame(schemaBranch.calls.map(c => c.phase), ['Collect', 'Lenses', 'Lenses', 'Lenses']))
  assert('PR schema requires each unconditional PR consumer, not optional evidence',
    deepSame([...collectSchema.required].sort(), [...commonRequired, ...prRequired].sort()))
  const firstRound = { ...GOOD_COLLECT }
  delete firstRound.patch_sha256
  assert('first PR round accepts complete identity without optional prose digest',
    (await run(firstRound, FULL_READ, { checkCollectSchema: true })).error === null)
  for (const target of ['1', 'feature', 'src/a.js']) {
    const fixture = target === '1' ? GOOD_COLLECT : branchCollect
    for (const key of target === '1' ? [...commonRequired, ...prRequired] : commonRequired) {
      const omitted = { ...fixture }
      delete omitted[key]
      const rejected = await run(omitted, FULL_READ, { target, checkCollectSchema: true })
      assert(`${target}: omitted ${key} is rejected at the schema boundary before any downstream agent`,
        rejected.error?.code === 'collect-schema-rejected' &&
        rejected.error.message === `Collect.${key}: required` &&
        deepSame(rejected.calls.map(c => c.phase), ['Collect']) && !rejected.verdictLogged)
    }
  }
  for (const [key, value] of [
    ['scratch_dir', null], ['scratch_dir', ''], ['scratch_dir', 'relative'],
    ['repo_root', null], ['repo_root', ''], ['repo_root', 'relative'],
    ['ledger_path', null], ['ledger_path', ''], ['ledger_path', 'relative'],
    ['driver_dir', null], ['driver_dir', ''], ['driver_dir', 'relative'],
    ['driver_source', null], ['driver_source', 'unknown'],
    ['drivers_ready', 'true'], ['drivers_ready', false],
  ]) {
    const rejected = await run({ ...GOOD_COLLECT, [key]: value }, FULL_READ, { checkCollectSchema: true })
    assert(`invalid ${key}=${JSON.stringify(value)} fails at schema before downstream work`,
      rejected.error?.code === 'collect-schema-rejected' &&
      rejected.error.message.startsWith(`Collect.${key}:`) &&
      deepSame(rejected.calls.map(c => c.phase), ['Collect']) && !rejected.verdictLogged)
  }
  const missingScratch = { ...GOOD_COLLECT }
  delete missingScratch.scratch_dir
  const schemaBypass = await run(missingScratch, FULL_READ)
  assert('semantic Collect validation still rejects missing scratch even if a caller bypasses schema',
    schemaBypass.error?.message.includes('scratch directory') && schemaBypass.calls.length === 1)
  const corrected = await run(GOOD_COLLECT, FULL_READ, { checkCollectSchema: true })
  assert('a corrected full Collect response still reaches all review and recording gates',
    corrected.error === null && corrected.result?.rounds.round === 1 &&
    corrected.calls.some(c => c.phase === 'Record') && corrected.calls.at(-1).phase === 'Cleanup')
  assert('Collect schema carries an optional lowercase SHA-256 digest',
    collectSchema.properties.patch_sha256?.type === 'string' &&
    collectSchema.properties.patch_sha256?.pattern === '^[0-9a-f]{64}$' &&
    collectSchema.properties.patch_sha256?.minLength === 64 &&
    collectSchema.properties.patch_sha256?.maxLength === 64 &&
    !collectSchema.required.includes('patch_sha256'))
  const prior = [entry(1, 1, 90, 0)]
  // #1824: identity omission must fail at StructuredOutput, not after Collect.
  // This offline boundary double proves the contract, not live SDK retry behavior.
  const identityKeys = ['repo', 'number', 'head_sha', 'base_sha', 'head_repo',
    'base_repo', 'head_repo_id', 'base_repo_id', 'author_id', 'operator_id']
  for (const history of [[], prior]) {
    for (const key of [null, ...identityKeys]) {
      const fixture = withHistory(history)
      fixture.pr_identity = { ...GOOD_COLLECT.pr_identity }
      if (key === null) delete fixture.pr_identity
      else delete fixture.pr_identity[key]
      const rejected = await run(fixture, FULL_READ, { checkCollectSchema: true })
      assert(`round ${history.length + 1}: omitted identity ${key || 'object'} rejected before downstream work`,
        rejected.error?.code === 'collect-schema-rejected' &&
        rejected.error.message === `Collect.pr_identity${key ? '.' + key : ''}: required` &&
        deepSame(rejected.calls.map(c => c.phase), ['Collect']) && !rejected.verdictLogged)
    }
  }
  for (const identity of [null, [], 'identity',
    ...identityKeys.map(key => ({ ...GOOD_COLLECT.pr_identity,
      [key]: typeof GOOD_COLLECT.pr_identity[key] === 'number' ? '12' : 12 })),
    ...['number', 'head_repo_id', 'base_repo_id', 'author_id', 'operator_id']
      .flatMap(key => [0, -1, 1.5].map(value => ({ ...GOOD_COLLECT.pr_identity, [key]: value })))]) {
    const rejected = await run(withHistory(prior, { pr_identity: identity }), FULL_READ,
      { checkCollectSchema: true })
    assert('malformed identity is rejected at schema boundary without downstream work',
      rejected.error?.code === 'collect-schema-rejected' &&
      (rejected.error.message.startsWith('Collect.pr_identity:') ||
       rejected.error.message.startsWith('Collect.pr_identity.')) &&
      deepSame(rejected.calls.map(c => c.phase), ['Collect']) && !rejected.verdictLogged)
  }
  const admittedIdentity = await run(withHistory(prior), FULL_READ, { checkCollectSchema: true })
  assert('complete numeric API identity admits later round with schema enforcement',
    admittedIdentity.error === null && admittedIdentity.result?.rounds?.round === 2)
  const omittedIdentity = withHistory(prior)
  delete omittedIdentity.pr_identity
  const schemaBypassedIdentity = await run(omittedIdentity, FULL_READ)
  assert('bypassing schema does not bypass missing-identity trust refusal',
    schemaBypassedIdentity.error?.code === 'untrusted-head' &&
    onlyCollected(schemaBypassedIdentity.calls) && !schemaBypassedIdentity.verdictLogged)
  for (const [key, value] of [
    ['repo', 'other/repo'], ['number', 2], ['head_sha', sha(77)], ['base_sha', sha(77)],
    ['head_repo', 'fork/repo'], ['base_repo', 'other/repo'], ['head_repo_id', 99],
    ['base_repo_id', 99], ['author_id', 99], ['operator_id', 99],
  ]) {
    const rejected = await run(withHistory(prior, {
      pr_identity: { ...GOOD_COLLECT.pr_identity, [key]: value },
    }), FULL_READ, { checkCollectSchema: true })
    assert(`shaped but inconsistent ${key} still fails unchanged trust gate`,
      rejected.error?.code === 'untrusted-head' && onlyCollected(rejected.calls) &&
      !rejected.verdictLogged)
  }
  const corruptPrior = await run({ ...withHistory(prior), ledger: { ...ledger(prior),
    ledger_errors: [{ comment_id: 8, kind: 'invalid-record', reason: 'broken trusted marker' }] } }, FULL_READ)
  assert('corrupt existing history blocks RED as well as lenses and Record',
    corruptPrior.error?.code === 'ledger-history-incomplete' && corruptPrior.calls.length === 1)
  const later = await run(withHistory(prior), FULL_READ, { args: { trusted_head_sha: sha(6) } })
  const phases = later.calls.map((c) => c.phase)
  assert('later round requires exact explicitly trusted head even with matching metadata',
    (await run(withHistory(prior), FULL_READ, { noTrust: true })).error?.code === 'untrusted-head')
  for (const updates of [
    { head_sha: sha(7), confirmed_head_sha: sha(7), pr_identity: { ...GOOD_COLLECT.pr_identity, head_sha: sha(7) } },
    { pr_identity: { ...GOOD_COLLECT.pr_identity, head_repo_id: 11, head_repo: 'fork/r' } },
    { pr_identity: { ...GOOD_COLLECT.pr_identity, author_id: 99 } },
    { pr_identity: { ...GOOD_COLLECT.pr_identity, operator_id: '12' } },
    { pr_identity: { ...GOOD_COLLECT.pr_identity, base_sha: sha(91) } },
    { pr_identity: { ...GOOD_COLLECT.pr_identity, number: 2 } },
  ]) {
    const rejected = await run(withHistory(prior, updates), FULL_READ,
      { args: { trusted_head_sha: sha(6) } })
    assert('moved, foreign, nonoperator or inconsistent metadata refuses before RED/lenses/Record',
      rejected.error?.code === 'untrusted-head' && rejected.error.message.includes(rejected.error.head_sha) &&
      onlyCollected(rejected.calls) && !rejected.verdictLogged)
  }
  const invalidTrust = await run(GOOD_COLLECT, FULL_READ, { args: { trusted_head_sha: 'abc' } })
  assert('invalid trusted SHA fails before Collect', invalidTrust.error && invalidTrust.calls.length === 0)
  const firstTrustedFree = await run(GOOD_COLLECT, FULL_READ)
  assert('first PR round stays compatible without trust arg', firstTrustedFree.result?.rounds?.round === 1)
  const invalidDriver = await run(GOOD_COLLECT, FULL_READ, { args: { driver_root: 'relative' } })
  const invalidScratch = await run(GOOD_COLLECT, FULL_READ, { args: { scratch_root: '/tmp/../escape' } })
  assert('optional directory arguments reject relative and traversal paths before Collect',
    invalidDriver.calls.length === 0 && invalidDriver.error && invalidScratch.calls.length === 0 && invalidScratch.error)
  assert('Collect requests authoritative PR API head/author and authenticated numeric operator ID',
    later.calls.find((c) => c.phase === 'Collect')?.prompt.includes('gh api repos/<repo>/pulls/<number>') &&
    later.calls.find((c) => c.phase === 'Collect')?.prompt.includes('gh api user') &&
    later.calls.find((c) => c.phase === 'Collect')?.prompt.includes('head.repo.id/full_name'))
  assert('default driver resolves from installed directory, never target checkout',
    later.calls.find((c) => c.phase === 'Collect')?.prompt.includes('~/.claude/scripts') &&
    later.calls.find((c) => c.phase === 'RedFirst')?.prompt.includes(`${GOOD_COLLECT.driver_dir}/red-first.sh`) &&
    !later.calls.find((c) => c.phase === 'RedFirst')?.prompt.includes(`${GOOD_COLLECT.repo_root}/scripts/red-first.sh`))
  const candidateDriver = '/opt/operator/candidate/scripts'
  const explicit = await run(withHistory(prior, { driver_dir: candidateDriver, driver_source: 'explicit' }), FULL_READ,
    { args: { trusted_head_sha: sha(6), driver_root: candidateDriver } })
  assert('explicit driver directory is used by RED, posting and readback',
    explicit.result?.rounds?.round === 2 && ['RedFirst', 'Record', 'Readback'].every((step) =>
      explicit.calls.find((c) => c.phase === step)?.prompt.includes(candidateDriver)))
  const unavailableDrivers = await run(withHistory(prior, { drivers_ready: false }), FULL_READ)
  assert('missing driver is refused before RED, lenses or Record',
    unavailableDrivers.error?.message.includes('required trusted drivers') &&
    unavailableDrivers.calls.length === 1)
  const spoofedDriver = await run(withHistory(prior, { driver_dir: `${GOOD_COLLECT.repo_root}/scripts`, driver_source: 'explicit' }), FULL_READ,
    { args: { trusted_head_sha: sha(6) } })
  assert('a target checkout driver is not selected without explicit operator argument',
    spoofedDriver.error && spoofedDriver.calls.length === 1)
  // Live round 4 lens: the installed default was a path-suffix match, so a target
  // checkout's own .claude/scripts passed as "installed".
  const checkoutInstalled = await run(withHistory(prior, { driver_dir: `${GOOD_COLLECT.repo_root}/.claude/scripts`,
    driver_source: 'installed' }), FULL_READ, { args: { trusted_head_sha: sha(6) } })
  assert('an "installed" driver inside the target checkout is refused before RED, lenses or Record',
    !!checkoutInstalled.error && checkoutInstalled.calls.length === 1)
  const relocated = path.join(tmp, 'review-adversarial-first.fixture0002')
  const movedScratch = await run(withHistory(prior, { scratch_dir: relocated,
    diff_path: `${relocated}/diff.patch`, ledger_path: `${relocated}/ledger.json` }), FULL_READ,
    { args: { trusted_head_sha: sha(6), scratch_root: tmp } })
  assert('distinct custom-root scratch location propagates to RED, record and cleanup',
    movedScratch.result?.rounds?.record_path === `${relocated}/round.json` &&
    movedScratch.calls.find((c) => c.phase === 'RedFirst')?.prompt.includes(`${relocated}/manifest.json`) &&
    movedScratch.calls.at(-1)?.prompt.includes(`${relocated}/ledger.json`))
  const wrongRoot = await run(withHistory(prior), FULL_READ,
    { args: { trusted_head_sha: sha(6), scratch_root: '/tmp/not-this-test' } })
  assert('scratch directory outside requested root fails before any expensive stage',
    wrongRoot.error && wrongRoot.calls.length === 1)
  assert('scratch directories for two invocations are different even with one custom root',
    movedScratch.result?.rounds?.record_path !== later.result?.rounds?.record_path)
  const escapedDiff = await run({ ...GOOD_COLLECT, diff_path: `${GOOD_COLLECT.scratch_dir}/../diff.patch` }, FULL_READ)
  assert('diff traversal out of scratch fails Collect validation',
    escapedDiff.error && escapedDiff.calls.length === 1)
  const defaultScratch = await run(GOOD_COLLECT, FULL_READ, { args: { scratch_root: undefined } })
  assert('default scratch root is /tmp and collector is instructed to make each directory unique',
    defaultScratch.calls[0].prompt.includes('/tmp') && defaultScratch.calls[0].prompt.includes('fresh unique'))
  assert('later PR dispatches RED with lenses then records after judge',
    phases.indexOf('RedFirst') < phases.indexOf('Lenses') &&
    phases.indexOf('Lenses') < phases.indexOf('Record') && later.result?.rounds.red_first.status === 'not-applicable')
  assert('later round cleans ledger, RED inputs/output and confirmed record',
    later.calls.at(-1).phase === 'Cleanup' &&
    ['manifest.json', 'files.txt', 'report.json', 'ledger.json', 'round.json'].every((path) =>
      later.calls.at(-1).prompt.includes(path)))
  assert('RED agent pinned Sonnet with no low-effort override',
    later.calls.find((c) => c.phase === 'RedFirst')?.opts.model === 'sonnet' &&
    !Object.hasOwn(later.calls.find((c) => c.phase === 'RedFirst').opts, 'effort'))
  assert('Record agent pinned Sonnet with inherited effort',
    later.calls.find((c) => c.phase === 'Record')?.opts.model === 'sonnet' &&
    !Object.hasOwn(later.calls.find((c) => c.phase === 'Record').opts, 'effort'))
  assert('poster and independent readback use the same selected quoted driver path',
    ['Record', 'Readback'].every((phase) => later.calls.find((c) => c.phase === phase)?.prompt
      .includes(`'${GOOD_COLLECT.driver_dir}/review-rounds.py'`)))
  assert('runner receives captured base SHA and full PR file list',
    later.calls.find((c) => c.phase === 'RedFirst').prompt.includes(`--base-branch '${GOOD_COLLECT.base_sha}'`) &&
    later.calls.find((c) => c.phase === 'RedFirst').prompt.includes(JSON.stringify(GOOD_COLLECT.files)))
  // Review finding #9: an agent-typed report.json made the file-read check
  // compare the agent with itself; the shell now writes the runner's stdout.
  const redCall = later.calls.find((c) => c.phase === 'RedFirst')
  const redScratch = GOOD_COLLECT.scratch_dir
  assert('RedFirst redirects runner stdout to report.json and stderr to red-first.err, then echoes the exit',
    !!redCall?.prompt.includes(`--files '${redScratch}/files.txt' > '${redScratch}/report.json' ` +
      `2> '${redScratch}/red-first.err'; echo "EXIT:$?"`))
  assert('RedFirst never instructs writing report.json and returns it by Reading the runner file',
    !!redCall && !/Write the exact stdout/.test(redCall.prompt) &&
    redCall.prompt.split('\n').filter((line) => /report(\.json|_path)/.test(line) && /\bWrite\b|heredoc/.test(line))
      .every((line) => line.includes('NEVER')) &&
    redCall.prompt.includes(`Read the ENTIRE '${redScratch}/report.json'`))
  // The harness raises BASH_MAX_TIMEOUT_MS to 1800000 (settings.json);
  // 600000 is only the stock maximum, so the schema's own limit decides.
  assert('RedFirst gives the runner Bash call the largest timeout the Bash tool schema accepts',
    !!redCall?.prompt.includes('largest timeout its Bash tool schema accepts') &&
    redCall.prompt.includes('1800000 ms') && redCall.prompt.includes('600000 ms') &&
    !redCall.prompt.includes('maximum timeout of 600000'))
  assert('RedFirst schema requires an integer exit_code',
    !!redCall?.opts.schema.required.includes('exit_code') && redCall.opts.schema.properties.exit_code?.type === 'integer')
  assert('later round cleanup includes the runner stderr file',
    later.calls.at(-1).phase === 'Cleanup' && later.calls.at(-1).prompt.includes(`${redScratch}/red-first.err`))
  const declined = await run({ ...GOOD_COLLECT, is_pr: false }, FULL_READ)
  assert('numeric PR cannot be downgraded by collector', declined.error?.message.includes('downgrade') &&
    declined.lensCalls.length === 0)
  for (const changed of [{ diff_files: ['different.js'] }, { confirmed_head_sha: sha(9) },
    { confirmed_base_sha: sha(91) },
    { files: ['a.js', 'a.js'], pr_files: ['a.js', 'a.js'], diff_files: ['a.js', 'a.js'] }]) {
    const mixed = await run({ ...GOOD_COLLECT, ...changed }, FULL_READ)
    assert(`mixed or moving PR evidence ${JSON.stringify(changed)} fails before lens/record`,
      mixed.error?.message === 'Collect returned mixed or moving PR file/revision evidence' &&
      mixed.calls.length === 1)
  }
  // On a PR's first round checkTrustedHead does not run, so this is the only
  // check keeping the ledger read and the Record post on the requested PR. Each
  // fixture's ledger names the same wrong target so nothing later catches it.
  for (const target of [{ pr_repo: 'o/r', pr_number: 2 }, { pr_repo: 'x/r', pr_number: 1 }]) {
    const moved = await run({ ...GOOD_COLLECT, ...target,
      ledger: { ...ledger(), target: { repo: target.pr_repo, pr: target.pr_number } } }, FULL_READ)
    assert(`Collect for another PR target ${JSON.stringify(target)} fails before lens/record`,
      moved.error?.message === 'Collect returned a different PR target or repository' && moved.calls.length === 1)
  }
  const escapedLedger = await run({ ...GOOD_COLLECT, ledger_path: '/tmp/outside.json' }, FULL_READ)
  assert('collector scratch outside the PR worktree is rejected before review',
    !!escapedLedger.error && escapedLedger.calls.length === 1)
  const noRead = await run({ ...GOOD_COLLECT, ledger: null }, FULL_READ)
  assert('failed ledger read cannot masquerade as empty history', !!noRead.error &&
    noRead.lensCalls.length === 0 && !noRead.calls.some((c) => c.phase === 'Record'))
  for (const problem of [
    { comment_id: 9, kind: 'invalid-record', reason: 'untrusted author in body' },
    { comment_id: 10, kind: 'invalid-author', reason: 'missing author user.id' },
    { comment_id: 11, reason: 'untrusted author ID 99' },
  ]) {
    const corrupt = await run({ ...GOOD_COLLECT,
      ledger: { ...ledger(), ledger_errors: [problem] } }, FULL_READ)
    assert(`corrupt/unknown ledger history ${problem.comment_id} blocks all expensive dispatch`,
      corrupt.error?.code === 'ledger-history-incomplete' &&
      JSON.stringify(corrupt.error.errors) === JSON.stringify([problem]) &&
      corrupt.calls.length === 1 && !corrupt.verdictLogged)
    assert(`corrupt ledger history ${problem.comment_id} payload reaches the caller in the message`,
      deepSame(payloadOf(corrupt.error), { code: 'ledger-history-incomplete', ledger_errors: [problem] }))
  }
  const noise = { comment_id: 12, kind: 'untrusted-author', reason: 'untrusted author ID 99' }
  const noisy = await run({ ...GOOD_COLLECT,
    ledger: { ...ledger(), ledger_errors: [noise] } }, FULL_READ, {
      readbackErrors: [noise],
    })
  assert('known untrusted noise remains visible and does not block a completed round',
    noisy.result?.verdict === 'CLEAN' && noisy.result.rounds.ledger_errors[0]?.kind === 'untrusted-author' &&
    noisy.calls.some((c) => c.phase === 'Lenses') && noisy.calls.some((c) => c.phase === 'Record'))
  const testPath = 'tests/case.test.sh'
  const changedTest = withHistory(prior, {
    files: [testPath], pr_files: [testPath], diff_files: [testPath], selection: {
      changed_paths: [testPath], blob_facts: [{ path: testPath,
        previous_blob: '100644 blob 111', head_blob: '100644 blob 222' }],
    },
  })
  const genuineReport = { head: GOOD_COLLECT.head_sha, base_branch: GOOD_COLLECT.base_sha,
    requested: [{ path: testPath, pre_fix: sha(1) }],
    tests: [{ path: testPath, pre_fix: sha(1), status: 'ran', command: 'bash test',
      reason: null, exempt: false, exempt_reason: null,
      cases: [{ name: 'missed', pre_fix: 'pass', head: 'pass', status: 'never-red' }] }],
    unchanged: [], overlay: [testPath], exempt: [] }
  const gate = await run(changedTest, FULL_READ, {
    redStage: { manifest_path: `${GOOD_COLLECT.scratch_dir}/manifest.json`,
      files_path: `${GOOD_COLLECT.scratch_dir}/files.txt`,
      report_path: `${GOOD_COLLECT.scratch_dir}/report.json`, report: genuineReport },
  })
  assert('PR round maps machine-selected test to RED P1 and records DIRTY',
    gate.result?.verdict === 'DIRTY' && gate.result.rounds.red_first.tests.length === 1 &&
    gate.calls.find((c) => c.phase === 'RedFirst')?.prompt.includes(`"pre_fix":"${sha(1)}"`) &&
    gate.calls.some((c) => c.phase === 'Record'))
  const transcriptReport = { ...genuineReport, tests: [{ ...genuineReport.tests[0],
    reason: 'pre-fix exit 1: Traceback (most recent call last): "x"' }] }
  const redStageFor = (report) => ({ manifest_path: `${GOOD_COLLECT.scratch_dir}/manifest.json`,
    files_path: `${GOOD_COLLECT.scratch_dir}/files.txt`,
    report_path: `${GOOD_COLLECT.scratch_dir}/report.json`, report })
  const compactRound = await run(changedTest, FULL_READ, { redStage: redStageFor(transcriptReport) })
  const collectCall = compactRound.calls.find((c) => c.phase === 'Collect')?.prompt || ''
  const readbackCall = compactRound.calls.find((c) => c.phase === 'Readback')?.prompt || ''
  assert('Collect redirects U1 compact read output; Readback runs U1 confirm on that file and the pending record',
    / read .*--compact/.test(collectCall) && /redirect/i.test(collectCall) &&
    readbackCall.includes(`confirm --repo 'o/r' --pr 1 --ledger '${GOOD_COLLECT.ledger_path}' ` +
      `--record '${GOOD_COLLECT.scratch_dir}/round.json'`) && !/ read /.test(readbackCall))
  assert('a RED transcript round confirms through compact readback and the exact pending file',
    compactRound.result?.rounds?.round === 2 && compactRound.calls.filter((c) => c.phase === 'Record').length === 1)
  const tampered = await run(changedTest, FULL_READ, { redStage: redStageFor(transcriptReport),
    diskTamper: (r) => ({ ...r, red_first: { ...r.red_first,
      tests: r.red_first.tests.map((t) => ({ ...t, reason: 'mangled' })) } }) })
  assert('a pending file whose transcript differs from the composed record fails after compact confirmation',
    tampered.error?.code === 'ledger-write-failed' && /pending file differs/.test(tampered.error.message) &&
    tampered.calls.filter((c) => c.phase === 'Record').length === 1 && !tampered.verdictLogged)
  assert('a pending-file mismatch reaches the caller as pending_mismatch in the payload',
    deepSame(payloadOf(tampered.error), { code: 'ledger-write-failed',
      reason: 'pending file differs from immutable record after attempt 1',
      record_path: `${GOOD_COLLECT.scratch_dir}/round.json`, ledger_path: GOOD_COLLECT.ledger_path,
      driver_dir: GOOD_COLLECT.driver_dir, pr_repo: 'o/r', pr_number: 1, record_written: true,
      pending_mismatch: true, verdict: 'DIRTY', underlying_verdict: 'DIRTY', touched_domains: ['ci'] }))
  const redExit = await run(changedTest, FULL_READ, { redStage: redStageFor(genuineReport), redExit: 1 })
  assert('a nonzero red-first.sh exit is a RED stage failure before Record',
    !!redExit.error?.message.includes('red-first-stage-failed') && redExit.error.message.includes('exited 1') &&
    !redExit.calls.some((c) => c.phase === 'Record') && !redExit.verdictLogged)
  // Contract DG: the caller sees only the message, so the runner's own last
  // stderr lines travel in it when the agent returned them.
  const redErrFile = `${GOOD_COLLECT.scratch_dir}/red-first.err`
  const redExitBase = `red-first-stage-failed: red-first.sh exited 2; diagnostics in ${redErrFile}`
  const diagnostic = 'red-first.sh: --manifest entry tests/case.test.sh: pre_fix is not 40-hex'
  for (const [label, redDiagnostic, expected] of [
    ['without a diagnostic', undefined, redExitBase],
    ['with an empty diagnostic', '', redExitBase],
    ['with a diagnostic', diagnostic, `${redExitBase}: ${diagnostic}`],
    ['with a diagnostic past 2000 characters', 'd'.repeat(2500), `${redExitBase}: ${'d'.repeat(2000)}`],
  ]) {
    const failed = await run(changedTest, FULL_READ, { redStage: redStageFor(genuineReport), redExit: 2, redDiagnostic })
    assert(`a nonzero red-first.sh exit ${label} throws the exact stage-failed message`,
      failed.error?.message === expected && !failed.calls.some((c) => c.phase === 'Record'))
  }
  const redSchemaCall = redExit.calls.find((c) => c.phase === 'RedFirst')
  assert('RedFirst schema offers an optional string diagnostic and asks for the last red-first.err lines',
    redSchemaCall?.opts.schema.properties.diagnostic?.type === 'string' &&
    !redSchemaCall.opts.schema.required.includes('diagnostic') &&
    /return the last lines of '[^']*red-first\.err'[^\n]* as diagnostic/.test(redSchemaCall.prompt))
  // Contract C: a same-head re-run selects no test, so its manifest is empty;
  // the stored never-red P1 must stay live rather than vanish.
  const neverTitle = `never-red regression test: ${testPath}::missed`
  // Round 2's RED run named the case against a Red-first-base trailer revision
  // (sha(50), not a recorded head), so the path's first-sight baseline stays the
  // latest recorded head while the carry sees the case's attribution.
  const attributed = { status: 'never-red', unchanged: [], tests: [{ path: testPath, pre_fix: sha(50),
    status: 'ran', command: 'bash test', reason: null, exempt: false, exempt_reason: null,
    cases: [{ name: 'missed', pre_fix: 'pass', head: 'pass', status: 'never-red' }] }] }
  const neverPrior = [entry(1, 0, 80, 0), entry(2, 1, 90, 0, { head: sha(6),
    findings: [{ file: testPath, severity: 'P1', title: neverTitle }], red: attributed })]
  const sameHead = await run(withHistory(neverPrior, { files: [testPath], pr_files: [testPath],
    diff_files: [testPath] }), FULL_READ)
  const sameHeadRecord = JSON.parse(sameHead.calls.find((c) => c.phase === 'Record')?.prompt.split('\n')
    .find((line) => line.startsWith('{"schema":')) || 'null')
  assert('a same-head re-run over a stored never-red P1 returns DIRTY',
    sameHead.result?.verdict === 'DIRTY' && sameHead.result.rounds.rerun === true &&
    sameHead.result.rounds.red_first.status === 'never-red' && sameHeadRecord?.live.P1 === 1 &&
    sameHeadRecord.findings.some((f) => f.title === neverTitle) &&
    sameHead.calls.some((c) => c.phase === 'RedFirst'))
  // Contract C2: the test changed since the never-red round (head sha(2)), so it is
  // selected against sha(2); a runner that proves it unchanged against some other
  // revision says nothing about the requested baseline, and the P1 stays live.
  const carriedPrior = [entry(1, 0, 80, 0), entry(2, 1, 90, 0,
    { findings: [{ file: testPath, severity: 'P1', title: neverTitle }], red: attributed })]
  const recordOf = (outcome) => JSON.parse(outcome.calls.find((c) => c.phase === 'Record')?.prompt.split('\n')
    .find((line) => line.startsWith('{"schema":')) || 'null')
  const carriedChange = (headBlob) => withHistory(carriedPrior, { files: [testPath], pr_files: [testPath],
    diff_files: [testPath], selection: { changed_paths: [testPath],
      blob_facts: [{ path: testPath, previous_blob: '100644 blob 111', head_blob: headBlob }] } })
  const unchangedReport = (preFix) => ({ head: GOOD_COLLECT.head_sha, base_branch: GOOD_COLLECT.base_sha,
    requested: [{ path: testPath, pre_fix: sha(2) }], tests: [], unchanged: [{ path: testPath, pre_fix: preFix }],
    overlay: [], exempt: [] })
  const otherBaseline = await run(carriedChange('100644 blob 222'), FULL_READ,
    { redStage: redStageFor(unchangedReport(sha(1))) })
  assert('unchanged against a pre_fix other than the requested one returns DIRTY with the carried P1 live',
    otherBaseline.error === null && otherBaseline.result?.verdict === 'DIRTY' &&
    otherBaseline.calls.find((c) => c.phase === 'RedFirst')?.prompt.includes(`"pre_fix":"${sha(2)}"`) &&
    otherBaseline.result.findings.some((f) => f.title === neverTitle && !f.refuted &&
      f.rationale.startsWith('carried from round 2')) &&
    recordOf(otherBaseline)?.live.P1 === 1 && recordOf(otherBaseline).findings.some((f) => f.title === neverTitle))
  const sameBaseline = await run(carriedChange('100644 blob 222'), FULL_READ,
    { redStage: redStageFor(unchangedReport(sha(2))) })
  assert('unchanged against the requested pre_fix clears the carried P1 (control)',
    sameBaseline.error === null && sameBaseline.result?.verdict === 'CLEAN' &&
    !sameBaseline.result.findings.some((f) => f.title === neverTitle))
  // A test deleted at head: Collect's blob fact has an empty head entry and the
  // runner reports the path unverifiable, so only the P2 remains.
  const deletedReport = { head: GOOD_COLLECT.head_sha, base_branch: GOOD_COLLECT.base_sha,
    requested: [{ path: testPath, pre_fix: sha(2) }], unchanged: [], overlay: [], exempt: [],
    tests: [{ path: testPath, pre_fix: sha(2), status: 'unverifiable', command: null,
      reason: 'path absent at head checkout', exempt: false, exempt_reason: null, cases: [] }] }
  const deletedAtHead = await run(carriedChange(''), FULL_READ, { redStage: redStageFor(deletedReport) })
  assert('a test path absent at head clears its carried never-red P1 from the Collect blob facts',
    deletedAtHead.error === null && deletedAtHead.result?.verdict === 'BORDERLINE' &&
    !deletedAtHead.result.findings.some((f) => f.title === neverTitle) &&
    recordOf(deletedAtHead)?.live.P1 === 0)
  // Contract S: a record body over the 65536-character comment limit is refused
  // before any posting agent, not posted and retried.
  const hookFiles = ['hooks/x.js']
  const hugeTitle = 'x'.repeat(70000)
  const oversized = await run({ ...GOOD_COLLECT, files: hookFiles, pr_files: hookFiles, diff_files: hookFiles },
    () => ({ findings: [{ title: hugeTitle, file: hookFiles[0], line: 3, severity: 'P2', refuted: false }],
      diff_lines_read: 40 }))
  const oversizedPayload = payloadOf(oversized.error)
  assert('an oversized record stops as ledger-record-too-large before any Record or Readback agent',
    oversized.error?.code === 'ledger-record-too-large' &&
    !oversized.calls.some((c) => ['Record', 'Readback', 'Cleanup'].includes(c.phase)) && !oversized.verdictLogged)
  assert('ledger-record-too-large payload reaches the caller in the message',
    oversizedPayload?.code === 'ledger-record-too-large' && oversizedPayload.estimated_chars > 70000 &&
    String(oversized.error).split('\n')[0] === 'Error: ledger-record-too-large: round 1 record body would be ' +
      `about ${oversizedPayload.estimated_chars} characters (GitHub comment limit 65536); nothing was posted` &&
    // Contract T: the 70000-character title cannot fit the delivery limit, so the
    // finding is dropped and counted; every scalar routing field stays exact.
    oversized.error.message.length <= 8000 &&
    deepSame({ ...oversizedPayload, estimated_chars: 0 }, { code: 'ledger-record-too-large', estimated_chars: 0,
      limit: 65536, pr_repo: 'o/r', pr_number: 1, round: 1, verdict: 'BORDERLINE', underlying_verdict: 'BORDERLINE',
      touched_domains: ['security'], live: { P1: 0, P2: 1, P3: 0 }, red_first_status: 'not-applicable',
      findings: [], truncated: { findings: 1 } }))
  const unread = await run(changedTest, FULL_READ, { redStage: redStageFor(transcriptReport),
    dropRecordOnDisk: true })
  assert('a confirmed append without the exact pending file is not reported as recorded',
    unread.error?.code === 'ledger-write-failed' && /pending record file/.test(unread.error.message) &&
    unread.calls.filter((c) => c.phase === 'Record').length === 1 && !unread.verdictLogged)
  // Contract PM: the Record agent confirmed its own write, but this workflow never
  // compared the pending file, so recovery must not read it as "matches".
  assert('a confirmed append whose pending file was not read back carries pending_mismatch null',
    payloadOf(unread.error)?.pending_mismatch === null && payloadOf(unread.error).record_written === true)
  // Each RED stage branch names its own cause; the shared prefix alone would let
  // one branch fire in another's place.
  const divergentRed = 'red-first-stage-failed: on-disk RED inputs/output missing, partial or divergent'
  for (const [diskOverride, expected] of [
    [{ omitRedFile: true }, (message) => message.startsWith(
      `red-first-stage-failed: file read failed: Read failed: ENOENT: no such file or directory, open '${GOOD_COLLECT.scratch_dir}/manifest.json'`)],
    [{ diskManifest: '[]' }, (message) => message === divergentRed],
    [{ diskFiles: 'different.js\n' }, (message) => message === divergentRed],
    // An agent-returned report that drops the runner's never-red test.
    [{ agentReport: { ...genuineReport, tests: [] } }, (message) => message === divergentRed],
  ]) {
    const diskMismatch = await run(changedTest, FULL_READ, {
      ...diskOverride, redStage: { manifest_path: `${GOOD_COLLECT.scratch_dir}/manifest.json`,
        files_path: `${GOOD_COLLECT.scratch_dir}/files.txt`,
        report_path: `${GOOD_COLLECT.scratch_dir}/report.json`, report: genuineReport },
    })
    assert(`missing or divergent RED on-disk input/output ${Object.keys(diskOverride)[0]} refuses before Record ` +
      'with its own message',
      expected(String(diskMismatch.error?.message)) &&
      !diskMismatch.calls.some((c) => c.phase === 'Record') && !diskMismatch.verdictLogged)
  }
  const partialRead = await run(changedTest, FULL_READ, { fileReadOverride: {
    manifest: genuineReport.requested, files: [], report: genuineReport,
  }, redStage: { manifest_path: `${GOOD_COLLECT.scratch_dir}/manifest.json`,
    files_path: `${GOOD_COLLECT.scratch_dir}/files.txt`,
    report_path: `${GOOD_COLLECT.scratch_dir}/report.json`, report: genuineReport } })
  assert('partial file-reader transport fails before Record',
    partialRead.error?.message === divergentRed &&
    !partialRead.calls.some((c) => c.phase === 'Record'))
  assert('RED file reader is separate Sonnet lean-reader before Record',
    gate.calls.find((c) => c.phase === 'RedFileRead')?.opts.agentType === 'lean-reader' &&
    gate.calls.find((c) => c.phase === 'RedFileRead')?.opts.model === 'sonnet' &&
    gate.calls.findIndex((c) => c.phase === 'RedFileRead') < gate.calls.findIndex((c) => c.phase === 'Record'))
  const wrongRequested = await run(changedTest, FULL_READ, {
    redStage: { manifest_path: `${GOOD_COLLECT.scratch_dir}/manifest.json`,
      files_path: `${GOOD_COLLECT.scratch_dir}/files.txt`,
      report_path: `${GOOD_COLLECT.scratch_dir}/report.json`,
      report: { ...genuineReport, requested: [{ path: testPath, pre_fix: GOOD_COLLECT.head_sha }],
        tests: [], unchanged: [{ path: testPath, pre_fix: GOOD_COLLECT.head_sha }] } },
  })
  assert('wrong manifest pinned to head cannot close as unchanged with no RED finding',
    wrongRequested.error?.message.includes('requested') &&
    !wrongRequested.calls.some((c) => c.phase === 'Record') && !wrongRequested.verdictLogged)
  const unexplained = await run(changedTest, FULL_READ, { redStage: {
    manifest_path: `${GOOD_COLLECT.scratch_dir}/manifest.json`,
    files_path: `${GOOD_COLLECT.scratch_dir}/files.txt`,
    report_path: `${GOOD_COLLECT.scratch_dir}/report.json`,
    report: { ...genuineReport, tests: [] },
  } })
  assert('missing selected path from runner is a hard stage failure',
    unexplained.error?.message.includes('partition') && !unexplained.calls.some((c) => c.phase === 'Record'))
  // Every RED file is really written and matches, so only the containment check
  // stands between an outside path and the reader, Record and Cleanup's unlink.
  const missingRedReport = 'red-first-stage-failed: missing file-backed mechanical RED report'
  const scratchRed = { manifest_path: `${GOOD_COLLECT.scratch_dir}/manifest.json`,
    files_path: `${GOOD_COLLECT.scratch_dir}/files.txt`, report_path: `${GOOD_COLLECT.scratch_dir}/report.json`,
    report: { head: GOOD_COLLECT.head_sha, base_branch: GOOD_COLLECT.base_sha,
      tests: [], unchanged: [], overlay: [], exempt: [], requested: [] } }
  for (const key of ['manifest_path', 'files_path', 'report_path']) {
    const escapedRed = await run(withHistory(prior), FULL_READ, { redStage: { ...scratchRed,
      [key]: path.join(tmp, `outside-${path.basename(scratchRed[key])}`) } })
    assert(`RED ${key} outside the round scratch directory stops on the containment check before any read`,
      escapedRed.error?.message === missingRedReport &&
      !escapedRed.calls.some((c) => ['RedFileRead', 'Record', 'Cleanup'].includes(c.phase)))
  }
  const containedRed = await run(withHistory(prior), FULL_READ, { redStage: scratchRed })
  assert('the same RED files inside the round scratch directory complete the round (containment control)',
    containedRed.error === null && containedRed.result?.rounds?.round === 2 &&
    containedRed.calls.some((c) => c.phase === 'RedFileRead'))
  const missingRed = await run(withHistory(prior), FULL_READ, { redStage: null })
  assert('missing RED hard-fails before record', missingRed.error?.message === missingRedReport &&
    !missingRed.calls.some((c) => c.phase === 'Record'))
  const unfetchable = await run(withHistory(prior, { selection: {
    changed_paths: [], blob_facts: [], error: 'git fetch origin ' + sha(1) + ': exit 128 unavailable',
  } }), FULL_READ)
  assert('unfetchable old head generates reasoned P2 without RED agent',
    unfetchable.result?.verdict === 'BORDERLINE' &&
    unfetchable.result.findings.some((f) => f.severity === 'P2' && f.rationale.includes('git fetch')) &&
    !unfetchable.calls.some((c) => c.phase === 'RedFirst'))
  const unfetchableRecord = JSON.parse(unfetchable.calls.find((c) => c.phase === 'Record')?.prompt.split('\n')
    .find((line) => line.startsWith('{"schema":')) || 'null')
  assert('an unfetchable old head is returned and recorded as red_first unverifiable, never not-applicable',
    unfetchable.result?.rounds?.red_first.status === 'unverifiable' &&
    unfetchableRecord?.red_first.status === 'unverifiable' && !!unfetchableRecord.red_first.selection_error)
  const underRed = await run(withHistory(prior), () => ({ findings: [], diff_lines_read: 1 }))
  assert('under-read lens with RED still prevents record', !!underRed.error &&
    !underRed.calls.some((c) => c.phase === 'Record'))
  const exhausted = await run(GOOD_COLLECT, FULL_READ, { failPosts: true })
  assert('three failed posts stop with immutable record path and no verdict',
    exhausted.error?.code === 'ledger-write-failed' && exhausted.error.record_path === `${GOOD_COLLECT.scratch_dir}/round.json` &&
    exhausted.error.ledger_path === GOOD_COLLECT.ledger_path &&
    exhausted.calls.filter((c) => c.phase === 'Record').length === 3 &&
    exhausted.calls.filter((c) => c.phase === 'Readback').length === 3 && !exhausted.verdictLogged &&
    !exhausted.calls.some((c) => c.phase === 'Cleanup'))
  // Review finding #8: the SKILL's confirm recovery needs these values, and the
  // runtime delivers only the message.
  const hookExhausted = await run({ ...GOOD_COLLECT, files: hookFiles, pr_files: hookFiles,
    diff_files: hookFiles }, FULL_READ, { failPosts: true })
  const exhaustedReason = 'three posting attempts exhausted with unchanged trusted history'
  assert('ledger-write-failed keeps its summary line and carries its payload in the message',
    String(hookExhausted.error).split('\n')[0] === `Error: ledger-write-failed: ${exhaustedReason}; ` +
      `record write confirmed at ${GOOD_COLLECT.scratch_dir}/round.json; captured ledger ${GOOD_COLLECT.ledger_path}` &&
    deepSame(payloadOf(hookExhausted.error), { code: 'ledger-write-failed', reason: exhaustedReason,
      record_path: `${GOOD_COLLECT.scratch_dir}/round.json`, ledger_path: GOOD_COLLECT.ledger_path,
      driver_dir: GOOD_COLLECT.driver_dir, pr_repo: 'o/r', pr_number: 1, record_written: true,
      pending_mismatch: false, verdict: 'CLEAN', underlying_verdict: 'CLEAN', touched_domains: ['security'] }))
  const cleanupBlocked = await run(GOOD_COLLECT, FULL_READ, { cleanupThrows: true })
  assert('cleanup failure leaves a posted round successful and reports pending scratch',
    cleanupBlocked.result?.verdict === 'CLEAN' && cleanupBlocked.result.rounds.scratch_cleanup_pending.length === 2 &&
    cleanupBlocked.logs.some((s) => s.includes('unlink denied')) &&
    cleanupBlocked.calls.filter((c) => c.phase === 'Record').length === 1)
  const cleanupPending = await run(GOOD_COLLECT, FULL_READ, {
    cleanupPending: [`${GOOD_COLLECT.scratch_dir}/round.json`],
  })
  assert('partial cleanup preserves a visible pending record path',
    cleanupPending.result?.rounds.scratch_cleanup_pending[0] === cleanupPending.result?.rounds.record_path &&
    cleanupPending.logs.some((s) => s.includes('round scratch remains')))
  const retried = await run(GOOD_COLLECT, FULL_READ, { failUntil: 2 })
  assert('bounded read-and-reconcile retries stop after confirmed third attempt',
    retried.result?.verdict === 'CLEAN' && retried.calls.filter((c) => c.phase === 'Record').length === 3)
  const invisible = await run(GOOD_COLLECT, FULL_READ, { invisiblePost: true })
  assert('reported post success with unchanged readback stops without a duplicate post',
    invisible.error?.code === 'ledger-write-failed' && invisible.error.record_written === true &&
    invisible.calls.filter((c) => c.phase === 'Record').length === 1 &&
    invisible.calls.filter((c) => c.phase === 'Readback').length === 1 &&
    !invisible.verdictLogged && !invisible.calls.some((c) => c.phase === 'Cleanup'))
  const readbackCorrupt = await run(GOOD_COLLECT, FULL_READ, {
    readbackErrors: [{ comment_id: 7, kind: 'invalid-record', reason: 'trusted broken JSON' }],
  })
  assert('new corrupt trusted readback cannot confirm posted round or trigger another post',
    readbackCorrupt.error?.code === 'ledger-write-failed' &&
    readbackCorrupt.error.message.includes('ledger errors changed') &&
    readbackCorrupt.calls.filter((c) => c.phase === 'Record').length === 1 &&
    !readbackCorrupt.calls.some((c) => c.phase === 'Cleanup') && !readbackCorrupt.verdictLogged)
  const conflict = await run(GOOD_COLLECT, FULL_READ, { conflict: true })
  assert('conflicting new record stops instead of returning an unproven verdict',
    conflict.error?.code === 'ledger-write-failed' && !conflict.verdictLogged &&
    conflict.calls.filter((c) => c.phase === 'Record').length === 1)
  const accepted = await run(GOOD_COLLECT, FULL_READ, { acceptedError: true })
  assert('accepted-but-error write reconciles through trusted readback before retry',
    accepted.result?.verdict === 'CLEAN' && accepted.calls.filter((c) => c.phase === 'Record').length === 1)
  const thrownAccepted = await run(GOOD_COLLECT, FULL_READ, { recordThrows: true })
  assert('ambiguous thrown post still gets independent readback and does not repost exact append',
    thrownAccepted.result?.verdict === 'CLEAN' &&
    thrownAccepted.calls.filter((c) => c.phase === 'Record').length === 1 &&
    thrownAccepted.calls.filter((c) => c.phase === 'Readback').length === 1)
  const thrownUnposted = await run(GOOD_COLLECT, FULL_READ, { recordThrowsUnposted: true })
  assert('ambiguous thrown post with exact pending file retries only after unchanged readback, max three',
    thrownUnposted.error?.code === 'ledger-write-failed' && thrownUnposted.error.record_written === true &&
    thrownUnposted.calls.filter((c) => c.phase === 'Record').length === 3 &&
    thrownUnposted.calls.filter((c) => c.phase === 'Readback').length === 3)
  // Pro gate round 2 at e96e1eee: another post needs this attempt's own equal
  // comparison of the pending file; the Record agent's write_confirmed is not it,
  // and U1 posts whatever the file holds.
  const uncompared = await run(GOOD_COLLECT, FULL_READ, { failPosts: true, dropRecordOnDisk: true })
  assert('a failed post whose readback omits the pending file stops before a second post',
    uncompared.error?.code === 'ledger-write-failed' && !uncompared.verdictLogged &&
    uncompared.calls.filter((c) => c.phase === 'Record').length === 1 &&
    payloadOf(uncompared.error)?.pending_mismatch === null)
  const uncomparedThenPosted = await run(GOOD_COLLECT, FULL_READ, { failUntil: 1, dropRecordOnDisk: true })
  assert('an uncompared failed post is not retried into an unconfirmed append',
    uncomparedThenPosted.error?.code === 'ledger-write-failed' &&
    uncomparedThenPosted.calls.filter((c) => c.phase === 'Record').length === 1)
  // Verify lens at 82cab14f: attempt 2's Record agent rewrites the pending file
  // after attempt 1's equal comparison. Recovery treats pending_mismatch false as
  // leave to post that file, so an earlier comparison must not be reported.
  const comparedOnce = await run(GOOD_COLLECT, FULL_READ, { failPosts: true, rewriteAt: 2, dropRecordOnDiskFrom: 2 })
  assert('an equal comparison on an earlier attempt neither admits a later uncompared retry nor reports false',
    comparedOnce.error?.code === 'ledger-write-failed' &&
    comparedOnce.calls.filter((c) => c.phase === 'Record').length === 2 &&
    payloadOf(comparedOnce.error)?.pending_mismatch === null)
  const rewrittenAppend = await run(GOOD_COLLECT, FULL_READ, { failUntil: 1, rewriteAt: 2, dropRecordOnDiskFrom: 2 })
  assert('a confirmed append not read back after a later attempt carries pending_mismatch null',
    rewrittenAppend.error?.code === 'ledger-write-failed' &&
    rewrittenAppend.error.message.includes('was not read back for exact comparison') &&
    rewrittenAppend.calls.filter((c) => c.phase === 'Record').length === 2 &&
    payloadOf(rewrittenAppend.error)?.pending_mismatch === null)
  const neverWritten = await run(GOOD_COLLECT, FULL_READ, { recordBeforeWriteThrows: true })
  assert('unconfirmed pending file is not represented as existing and readback is still attempted',
    neverWritten.error?.code === 'ledger-write-failed' &&
    neverWritten.error.record_path === `${GOOD_COLLECT.scratch_dir}/round.json` &&
    neverWritten.error.ledger_path === GOOD_COLLECT.ledger_path &&
    neverWritten.error.record_written !== true &&
    !neverWritten.error.message.includes('immutable record at') &&
    neverWritten.calls.filter((c) => c.phase === 'Readback').length === 1 &&
    neverWritten.calls.filter((c) => c.phase === 'Record').length === 1)
  const neverWrittenPayload = payloadOf(neverWritten.error)
  // Contract PM: pending_mismatch is tri-state. Nothing compared the pending file
  // with the composed record here, so the payload says unknown, not "matches".
  assert('an unconfirmed pending file is record_written false and pending_mismatch null in the payload',
    neverWrittenPayload?.code === 'ledger-write-failed' && neverWrittenPayload.record_written === false &&
    neverWrittenPayload.pending_mismatch === null &&
    neverWrittenPayload.reason.startsWith('trusted readback failed after attempt 1') &&
    neverWrittenPayload.record_path === `${GOOD_COLLECT.scratch_dir}/round.json`)
  // Attempt 1's readback compared the pending file equal; attempt 2's Record agent
  // could then write it, and attempt 2's readback fails, so nothing compared it since.
  const comparedThenLost = await run(GOOD_COLLECT, FULL_READ, { failPosts: true, readUnavailableFrom: 2 })
  const comparedThenLostPayload = payloadOf(comparedThenLost.error)
  assert('a readback failure after a later posting attempt carries pending_mismatch null',
    comparedThenLost.calls.filter((c) => c.phase === 'Readback').length === 2 &&
    comparedThenLostPayload?.code === 'ledger-write-failed' && comparedThenLostPayload.record_written === true &&
    comparedThenLostPayload.pending_mismatch === null &&
    comparedThenLostPayload.reason.startsWith('trusted readback failed after attempt 2'))
  // The comparison after the last posting attempt is current, so the exhaustion
  // stop still reports it.
  const exhaustedCompared = await run(GOOD_COLLECT, FULL_READ, { failPosts: true })
  assert('exhausting three compared attempts carries pending_mismatch false',
    exhaustedCompared.error?.code === 'ledger-write-failed' &&
    exhaustedCompared.error.message.includes('three posting attempts exhausted') &&
    exhaustedCompared.calls.filter((c) => c.phase === 'Record').length === 3 &&
    payloadOf(exhaustedCompared.error)?.pending_mismatch === false)
  assert('posting agent and Python CLI readback agent are distinct, pinned Sonnet agents',
    clean.calls.filter((c) => c.phase === 'Readback').length === 1 &&
    clean.calls.find((c) => c.phase === 'Readback')?.opts.model === 'sonnet' &&
    clean.calls.find((c) => c.phase === 'Readback')?.opts.agentType !== 'lean-reader' &&
    !Object.hasOwn(clean.calls.find((c) => c.phase === 'Readback').opts, 'effort'))
  const unreadable = await run(GOOD_COLLECT, FULL_READ, { readUnavailable: true })
  assert('unavailable readback stops without blind repost',
    unreadable.error?.code === 'ledger-write-failed' &&
    unreadable.calls.filter((c) => c.phase === 'Record').length === 1)
  assert('a first readback failure after an agent-confirmed write carries pending_mismatch null',
    payloadOf(unreadable.error)?.pending_mismatch === null && payloadOf(unreadable.error).record_written === true)
  // Contract T: an agent error quoted in the reason is bounded where it enters the
  // stop, so the summary keeps its recovery paths and the payload every routing field.
  const longReadback = await run(GOOD_COLLECT, FULL_READ, { readUnavailable: true, readbackError: 'q'.repeat(12000) })
  const longPayload = payloadOf(longReadback.error)
  const shortPayload = payloadOf(unreadable.error)
  assert('a long agent error in ledger-write-failed keeps the message bounded and every routing and recovery field',
    longReadback.error?.code === 'ledger-write-failed' && longReadback.error.message.length <= 8000 &&
    longPayload !== null && shortPayload !== null && !Object.hasOwn(longPayload, 'truncated') &&
    longPayload.reason === `${`trusted readback failed after attempt 1: ${'q'.repeat(12000)}`.slice(0, 999)}…` &&
    deepSame({ ...longPayload, reason: '' }, { ...shortPayload, reason: '' }) &&
    longReadback.error.message.split('\n')[0].endsWith(`captured ledger ${GOOD_COLLECT.ledger_path}`))
  const reasonHead = 'trusted readback failed after attempt 1: '
  const pairReadback = await run(GOOD_COLLECT, FULL_READ, { readUnavailable: true,
    readbackError: `${'q'.repeat(998 - reasonHead.length)}\u{1F600}${'q'.repeat(3000)}` })
  assert('a ledger-write-failed reason cut through a surrogate pair drops the whole pair',
    payloadOf(pairReadback.error)?.reason === `${reasonHead}${'q'.repeat(998 - reasonHead.length)}…`)
  const many =Array.from({ length: 35 }, (_, i) => entry(i + 1, 1, i + 1, 0))
  const historical = await run(withHistory(many), FULL_READ)
  assert('>32 trusted rounds preserve old head identity but cap display with log',
    historical.result?.rounds.rerun && historical.result.rounds.table.length === 32 &&
    historical.logs.some((s) => s.includes('capped at 32 of 36')))
  const frozenPrior = [entry(1, 1, 60, 0), entry(2, 1, 80, 1),
    entry(3, 1, 90, 2, { verdict: 'FROZEN' })]
  const stopped = await run(withHistory(frozenPrior), FULL_READ)
  assert('frozen admission stops before trust/RED/lens/Record with prior table',
    stopped.error?.code === 'frozen' && stopped.error.rounds.table.length === 3 &&
    onlyCollected(stopped.calls) &&
    (await run(withHistory(frozenPrior), FULL_READ, { noTrust: true })).error?.code === 'frozen')
  // Review finding #8: the caller routes the higher tier and shows the prior
  // table from the frozen payload, the only channel the runtime delivers.
  const frozenFiles = ['hooks/x.js', 'b.md']
  const frozenWithFindings = [entry(1, 1, 60, 0), entry(2, 1, 80, 1), entry(3, 1, 90, 2, { verdict: 'FROZEN',
    findings: [{ file: frozenFiles[0], severity: 'P1', title: 'still open' },
      { file: frozenFiles[1], severity: 'P3', title: 'nit' }] })]
  const frozenStop = await run({ ...withHistory(frozenWithFindings, { files: frozenFiles, pr_files: frozenFiles,
    diff_files: frozenFiles }), ledger: { ...ledger(frozenWithFindings), ledger_errors: [noise] } }, FULL_READ)
  assert('frozen summary no longer reads as an instruction',
    String(frozenStop.error).split('\n')[0] ===
      'Error: frozen: PR 1 round 3 has streak 2; continue_past_freeze not supplied')
  assert('frozen payload carries table, residual classes and routing inputs in the message',
    frozenStop.error?.code === 'frozen' && onlyCollected(frozenStop.calls) &&
    deepSame(payloadOf(frozenStop.error), { code: 'frozen', pr_repo: 'o/r', pr_number: 1, prior_round: 3,
      streak: 2, underlying_verdict: 'BORDERLINE', touched_domains: ['docs', 'security'],
      table: tableOf(frozenWithFindings),
      residual_classes: [{ file: frozenFiles[0], severity: 'P1', titles: ['still open'] }],
      ledger_errors: [noise] }) &&
    deepSame(frozenStop.error.rounds.residual_classes, payloadOf(frozenStop.error)?.residual_classes))
  // The fixture above stores no residual_classes, so the P1 class is computed from
  // its live findings (the P3 nit is not a residual). A stored list is authority
  // and passes verbatim, even where recomputing from findings would differ.
  const storedResidual = [{ file: 'z.js', severity: 'P2', titles: ['stored class'] }]
  const frozenStored = [...frozenWithFindings.slice(0, 2), { ...frozenWithFindings[2],
    record: { ...frozenWithFindings[2].record, residual_classes: storedResidual } }]
  const storedStop = await run(withHistory(frozenStored, { files: frozenFiles, pr_files: frozenFiles,
    diff_files: frozenFiles }), FULL_READ)
  assert('a stored frozen residual_classes list reaches the payload verbatim',
    storedStop.error?.code === 'frozen' && onlyCollected(storedStop.calls) &&
    deepSame(payloadOf(storedStop.error)?.residual_classes, storedResidual) &&
    deepSame(storedStop.error.rounds.residual_classes, storedResidual))
  // Refute lens at 1c74d45a: admission, selection and the carry read Collect's
  // copy, so a separate reader re-reads the captured file and the copy must equal it.
  const divergentLedger = `ledger-read-failed: Collect's copy and the reader's copy of ${GOOD_COLLECT.ledger_path} differ`
  const droppedFrozen = await run(withHistory(frozenPrior.slice(0, 2)), FULL_READ,
    { diskLedger: ledger(frozenPrior) })
  assert('a Collect copy missing the frozen round stops on the ledger re-read before admission or any lens',
    droppedFrozen.error?.message === divergentLedger && onlyCollected(droppedFrozen.calls) &&
    !droppedFrozen.verdictLogged)
  const casePath = 'tests/t.test.sh'
  const casesPrior = [entry(1, 0, 80, 0), entry(2, 1, 90, 0, {
    findings: [{ file: casePath, severity: 'P1', title: `never-red regression test: ${casePath}::missed` }],
    red: { status: 'never-red', unchanged: [], tests: [{ path: casePath, pre_fix: sha(50), status: 'ran',
      command: 'bash test', reason: null, exempt: false, exempt_reason: null,
      cases: ['a', 'b', 'missed'].map((name) => ({ name, pre_fix: name === 'missed' ? 'pass' : 'fail',
        head: 'pass', status: name === 'missed' ? 'never-red' : 'verified' })) }] } })]
  const cutCopy = ledger(casesPrior)
  cutCopy.rounds[1].record.red_first.tests[0].cases.splice(2)
  const cutCases = await run({ ...withHistory(casesPrior), ledger: cutCopy }, FULL_READ,
    { diskLedger: ledger(casesPrior) })
  assert('a Collect copy with a shortened case list stops on the ledger re-read before RED, lenses or Record',
    cutCases.error?.message === divergentLedger && onlyCollected(cutCases.calls))
  const emptiedHistory = await run(GOOD_COLLECT, FULL_READ, { diskLedger: ledger(casesPrior) })
  assert('an empty first-round copy of a file that holds history is not a first round',
    emptiedHistory.error?.message === divergentLedger && onlyCollected(emptiedHistory.calls))
  const readerDown = await run(withHistory(frozenPrior), FULL_READ, { ledgerReadThrows: true })
  assert('a failed ledger re-read stops as ledger-read-failed before admission',
    readerDown.error?.message === 'ledger-read-failed: file read failed: Read failed: EACCES' &&
    onlyCollected(readerDown.calls))
  const readerEmpty = await run(withHistory(frozenPrior), FULL_READ, { ledgerReadNull: true })
  assert('a reader that returns nothing stops as ledger-read-failed without blaming Collect',
    readerEmpty.error?.message === `ledger-read-failed: the reader returned nothing for ${GOOD_COLLECT.ledger_path}` &&
    onlyCollected(readerEmpty.calls))
  const intactCases = await run(withHistory(casesPrior), FULL_READ)
  const ledgerReadCall = intactCases.calls.find((c) => c.phase === 'LedgerFileRead')
  assert('an equal copy passes the re-read: a separate Sonnet lean-reader of the captured file, before any lens',
    intactCases.error === null && intactCases.result?.rounds?.round === 3 &&
    ledgerReadCall?.opts.agentType === 'lean-reader' && ledgerReadCall.opts.model === 'sonnet' &&
    ledgerReadCall.prompt.includes(`existing file ${GOOD_COLLECT.ledger_path} with the Read tool`) &&
    intactCases.calls.findIndex((c) => c.phase === 'LedgerFileRead') === 1 &&
    intactCases.calls.findIndex((c) => c.phase === 'Lenses') > 1)
  const lensP1 = () => ({ findings: [{ title: 'live defect', file: 'a.js', line: 1,
    severity: 'P1', refuted: false }], diff_lines_read: 40 })
  const admitted = await run(withHistory(frozenPrior), lensP1, {
    args: { continue_past_freeze: true } })
  assert('one-shot override records underlying DIRTY while frozen state persists',
    admitted.result?.verdict === 'DIRTY' && admitted.result.rounds.frozen &&
    admitted.result.rounds.override && admitted.result.rounds.streak === 3 &&
    !Object.hasOwn(JSON.parse(admitted.calls.find((c) => c.phase === 'Record')
      .prompt.split('\n').find((line) => line.startsWith('{"schema":'))), 'residual_classes'))
  const converged = await run(withHistory(frozenPrior), FULL_READ,
    { args: { continue_past_freeze: true } })
  assert('overridden convergent round clears freeze',
    converged.result?.rounds.streak === 0 && !converged.result.rounds.frozen)
  const invalidFlag = await run(GOOD_COLLECT, FULL_READ, { args: { continue_past_freeze: 'true' } })
  assert('truthy string cannot authorize override', !!invalidFlag.error && invalidFlag.calls.length === 0)
  const branch = await run({ ...GOOD_COLLECT, is_pr: false, driver_dir: null,
    drivers_ready: false }, FULL_READ, { target: 'feature' })
  assert('branch remains non-PR even without installed PR drivers and explains disabled rounds',
    branch.result?.rounds.enabled === false && branch.result.rounds.reason === 'target is not a PR' &&
    !branch.calls.some((c) => ['RedFirst', 'Record'].includes(c.phase)))

  // Collect's instructions vs the gate, for the path-target commands (the PR
  // and branch forms use git diffs, which always open with a header).
  const collectPrompt = clean.calls.find((c) => c.phase === 'Collect').prompt
  assert('Collect digests the actual file that every lens reads, preserving patch_id',
    collectPrompt.includes('sha256sum <diff_path>') && collectPrompt.includes('patch_sha256') &&
    collectPrompt.includes('`git patch-id --stable` from THAT file'))
  const inventoryCmds = [...collectPrompt.matchAll(/`(git --no-replace-objects [^`]* (?:--no-patch --numstat|--name-only(?: -z)?) <base_sha>\.\.\.<head_sha> --)`/g)].map(x => x[1])
  assert('Collect prescribes canonical separate name-only and numstat commands', inventoryCmds.length === 2)
  const cmds = [...collectPrompt.matchAll(/`(git [a-z]+ [^`]*<path> > <diff_path>)`/g)].map((x) => x[1])
  assert('found the two path-target commands in the Collect prompt', cmds.length === 2)

  const repoDir = fs.mkdtempSync(path.join(tmp, 'repo-'))
  const env = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1' }
  const git = (...a) => execFileSync('git', a, { cwd: repoDir, env, encoding: 'utf8' })
  const commit = (msg) => git('-c', 'user.email=t@example.com', '-c', 'user.name=t', 'commit', '-q', '-m', msg)
  git('init', '-q', '-b', 'main')
  // A user config that forces color (color.ui=always) must not break the check:
  // Collect's commands have to produce a literal, uncolored diff header anyway.
  git('config', 'color.ui', 'always')
  fs.writeFileSync(path.join(repoDir, 'f.txt'), 'one\n')
  git('add', 'f.txt')
  commit('add f')
  fs.writeFileSync(path.join(repoDir, 'f.txt'), 'one\ntwo\n')
  for (const cmd of cmds) {
    const argv = cmd.replace(' > <diff_path>', '').replace('<path>', 'f.txt').split(' ')
    const first = git(...argv.slice(1)).split('\n')[0]
    const r = await run({ ...GOOD_COLLECT, is_pr: false, first_line: first }, FULL_READ,
      { target: 'feature' })
    assert(`Collect's own \`${cmd}\` yields a first line the gate accepts (got ${JSON.stringify(first)})`, r.error === null)
  }
  const baseSha = git('rev-parse', 'HEAD').trim()
  git('add', 'f.txt')
  commit('update f')
  const headSha = git('rev-parse', 'HEAD').trim()
  for (const cmd of inventoryCmds) {
    // Execute the actual prompt command, including its quoted context indicator.
    const resolved = cmd.replace('<base_sha>', baseSha).replace('<head_sha>', headSha)
    const actual = execFileSync('bash', ['-c', resolved], { cwd: repoDir, env, encoding: 'utf8' })
    const expected = cmd.includes('--name-only') ? (cmd.includes(' -z ') ? 'f.txt\0' : 'f.txt\n') : '1\t0\tf.txt\n'
    assert(`Collect inventory command emits only its requested output mode: ${cmd}`, actual === expected)
  }

  // #1721: execute the shipped Collect inventory commands against real git
  // trees and an argv-checking gh boundary double. No provider or GitHub call
  // runs here: this proves command construction, JSON transport and admission,
  // not live API pagination or a model's obedience to these instructions.
  const inventoryBin = fs.mkdtempSync(path.join(tmp, 'inventory-bin-'))
  const apiFixture = path.join(inventoryBin, 'pages.json')
  const ghCalls = path.join(inventoryBin, 'calls.jsonl')
  fs.writeFileSync(path.join(inventoryBin, 'gh'), `#!/usr/bin/env node
const fs = require('fs')
const argv = process.argv.slice(2)
fs.appendFileSync(process.env.INVENTORY_CALLS, JSON.stringify(argv) + '\\n')
const fixture = JSON.parse(fs.readFileSync(process.env.INVENTORY_FIXTURE, 'utf8'))
if (argv[0] === 'pr' && argv[1] === 'diff') {
  if (fixture.large) {
    console.error('HTTP 406: PullRequest.diff too_large (20000 lines)')
    process.exit(1)
  }
  process.stdout.write(fixture.pages.flat().map(f => f.filename).join('\\n') + '\\n')
  process.exit(0)
}
if (argv.length !== 4 || argv[0] !== 'api' || !argv.includes('--paginate') ||
    !argv.includes('--slurp') || !argv.includes('repos/o/r/pulls/1/files?per_page=100')) {
  console.error('unexpected gh argv: ' + JSON.stringify(argv))
  process.exit(2)
}
process.stdout.write(fixture.malformedJson ? '[[' : JSON.stringify(fixture.pages) + '\\n')
if (fixture.apiError) {
  console.error('HTTP 502: fixture page request failed')
  process.exit(1)
}
`, { mode: 0o755 })
  const inventoryEnv = { ...env, PATH: `${inventoryBin}:${process.env.PATH}`,
    INVENTORY_CALLS: ghCalls, INVENTORY_FIXTURE: apiFixture }
  const prInventoryCommand = [...collectPrompt.matchAll(/`([^`]+)`/g)]
    .map(m => m[1]).find(c => c.startsWith('set -o pipefail; gh api ') || c.startsWith('gh pr diff '))
  const nameCommand = inventoryCmds.find(c => c.includes('--name-only'))
  const patchCommand = [...collectPrompt.matchAll(/`([^`]+)`/g)].map(m => m[1])
    .find(c => c.startsWith('git --no-replace-objects ') && c.endsWith(' > <diff_path>'))
  assert('PR inventory uses paginated slurped files metadata, external jq and pipefail, never gh pr diff',
    !!prInventoryCommand?.includes('--paginate --slurp') && prInventoryCommand.includes('| jq -e ') &&
    prInventoryCommand.includes('previous_filename') && prInventoryCommand.includes('unique') &&
    !prInventoryCommand.includes('--jq') && !collectPrompt.includes('gh pr diff '))
  assert('canonical file names use NUL delimiters so quoted, Unicode and whitespace paths remain exact',
    !!nameCommand?.includes('--name-only -z') && collectPrompt.includes('NUL-delimited') &&
    collectPrompt.includes('3000'))

  // Both sides of every rename are expected from BOTH sources: the API lists
  // filename plus previous_filename, and CANONICAL_DIFF carries --no-renames,
  // so git lists the source as a deletion and the destination as an addition
  // (with rename detection on, --name-only would print only the destination;
  // #1702 pro-gate round 1 P1 assumed that default). The command executed below
  // is the one extracted from the Collect prompt, so this observes git, not a
  // transcription of it; dropping --no-renames turns these three cases RED.
  function inventoryRepo(label, renames, additions) {
    const dir = fs.mkdtempSync(path.join(tmp, `inventory-${label}-`))
    const git = (...a) => execFileSync('git', a, { cwd: dir, env, encoding: 'utf8' })
    const write = (p, text) => {
      fs.mkdirSync(path.dirname(path.join(dir, p)), { recursive: true })
      fs.writeFileSync(path.join(dir, p), text)
    }
    const commit = msg => git('-c', 'user.email=t@example.com', '-c', 'user.name=t',
      'commit', '-q', '-m', msg)
    git('init', '-q', '-b', 'main')
    write('unchanged.txt', 'anchor\n')
    renames.forEach(([old], i) => write(old, `unique unchanged rename ${i}\n`))
    git('add', '--all')
    commit('base inventory')
    const base = git('rev-parse', 'HEAD').trim()
    renames.forEach(([old, next]) => {
      fs.mkdirSync(path.dirname(path.join(dir, next)), { recursive: true })
      fs.renameSync(path.join(dir, old), path.join(dir, next))
    })
    additions.forEach(p => write(p, 'added line\n'.repeat(label === 'large' ? 155 : 1)))
    git('add', '--all')
    commit('head inventory')
    const head = git('rev-parse', 'HEAD').trim()
    const records = [...renames.map(([previous_filename, filename]) =>
      ({ filename, previous_filename, status: 'renamed' })),
    ...additions.map(filename => ({ filename, previous_filename: null, status: 'added' }))]
    const expected = [...renames.flat(), ...additions].sort()
    const renamed = git('diff', '--name-status', '--find-renames=100%', `${base}...${head}`, '--')
    assert(`${label} fixture contains its real R100 renames`,
      renamed.split('\n').filter(l => l.startsWith('R100\t')).length === renames.length)
    return { dir, base, head, records, expected, large: label === 'large' }
  }
  const renameFixture = inventoryRepo('rename', [['old.txt', 'new.txt']], [])
  const largeFixture = inventoryRepo('large', [
    ['corpus-cdn-cgi.test.txt', 'corpus-cdn-cgi.txt'],
    ['corpus-emphasis.test.txt', 'corpus-emphasis.txt'],
  ], Array.from({ length: 134 }, (_, i) => `files/changed-${String(i).padStart(3, '0')}.txt`))
  const oddFixture = inventoryRepo('paths', [['old name.txt', 'new name.txt']], [
    ' leading and trailing .txt ', 'docs/quote"back\\slash.txt', 'docs/日本語-é.txt', 'docs/tab\tline\nbreak.txt',
  ])
  const pagesOf = records => Array.from({ length: Math.ceil(records.length / 100) },
    (_, i) => records.slice(i * 100, (i + 1) * 100))
  const resolveInventory = (command, fixture) => command.replaceAll('<repo>', 'o/r')
    .replaceAll('<number>', '1').replaceAll('<target>', '1')
    .replaceAll('<base_sha>', fixture.base).replaceAll('<head_sha>', fixture.head)
  function collectInventory(fixture, pages = pagesOf(fixture.records), options = {}) {
    fs.writeFileSync(apiFixture, JSON.stringify({ pages, large: fixture.large,
      apiError: !!options.apiError, malformedJson: !!options.malformedJson }))
    fs.writeFileSync(ghCalls, '')
    const output = spawnSync('bash', ['-c', resolveInventory(prInventoryCommand, fixture)],
      { cwd: fixture.dir, env: inventoryEnv, encoding: 'utf8' })
    if (output.status !== 0) throw new Error(`inventory command failed: ${output.stderr.trim()}`)
    // The old command's newline output is retained only to exercise baseline
    // RED. The shipped command must return one machine-readable JSON array.
    const prFiles = prInventoryCommand.startsWith('gh pr diff ')
      ? output.stdout.trimEnd().split('\n') : JSON.parse(output.stdout)
    const names = execFileSync('bash', ['-c', resolveInventory(nameCommand, fixture)],
      { cwd: fixture.dir, env, encoding: 'utf8' })
    const diffFiles = names.slice(0, -1).split(nameCommand.includes(' -z ') ? '\0' : '\n')
    const patch = execFileSync('bash', ['-c', resolveInventory(patchCommand.replace(' > <diff_path>', ''), fixture)],
      { cwd: fixture.dir, env, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 })
    fs.mkdirSync(GOOD_COLLECT.scratch_dir, { recursive: true })
    fs.writeFileSync(GOOD_COLLECT.diff_path, patch)
    const patchId = execFileSync('git', ['patch-id', '--stable'], { input: patch, env, encoding: 'utf8' })
      .split(' ')[0]
    return { ...GOOD_COLLECT, files: prFiles, pr_files: prFiles, diff_files: diffFiles,
      repo_root: fixture.dir, head_sha: fixture.head, confirmed_head_sha: fixture.head,
      base_sha: fixture.base, confirmed_base_sha: fixture.base, patch_id: patchId,
      pr_identity: { ...GOOD_COLLECT.pr_identity, head_sha: fixture.head, base_sha: fixture.base },
      patch_sha256: require('crypto').createHash('sha256').update(patch).digest('hex'),
      diff_line_count: patch.split('\n').length - 1, first_line: patch.split('\n')[0],
      diff_lines: patch.split('\n').filter(l => /^[+-]/.test(l) && !/^(---|\+\+\+)/.test(l)).length,
      selection: { ...GOOD_COLLECT.selection, head_sha: fixture.head, base_sha: fixture.base },
      ...options.updates }
  }
  const fullInventoryRead = () => ({ findings: [], diff_lines_read: Number.MAX_SAFE_INTEGER })
  async function runInventory(fixture, pages, options = {}) {
    return run(GOOD_COLLECT, fullInventoryRead, { checkCollectSchema: true,
      collectFiles: () => collectInventory(fixture, pages, options) })
  }
  for (const [label, fixture, pages] of [
    ['R100 rename old and new paths', renameFixture, pagesOf(renameFixture.records)],
    ['historical 136 API entries plus 2 old names equals 138 canonical paths', largeFixture,
      pagesOf(largeFixture.records)],
    ['global dedup and lossless quoted Unicode whitespace paths', oddFixture,
      [oddFixture.records, [oddFixture.records[0], { filename: 'old name.txt' }, oddFixture.records.at(-1)]]],
  ]) {
    const result = await runInventory(fixture, pages)
    assert(`${label} completes Collect and reaches the first recorded round` +
      (result.error ? ` (${result.error.message})` : ''),
      result.error === null && result.result?.rounds.round === 1 && result.calls.some(c => c.phase === 'Record'))
    const calls = fs.readFileSync(ghCalls, 'utf8').trim().split('\n').map(JSON.parse)
    assert(`${label} never invokes gh pr diff`, calls.length === 1 && calls[0][0] === 'api')
    if (result.error === null) {
      const collected = collectInventory(fixture, pages)
      assert(`${label} returns exactly the independent expected path inventory`,
        deepSame([...collected.pr_files].sort(), fixture.expected) &&
        deepSame([...collected.diff_files].sort(), fixture.expected))
      if (fixture.large) assert('large fixture spans two API pages and exceeds the 20000-line diff cap',
        fixture.records.length === 136 && pages.length === 2 && pages[0].length === 100 &&
        pages[1].length === 36 && collected.pr_files.length === 138 && collected.diff_line_count > 20000)
    }
  }
  for (const [label, pages, options] of [
    ['missing second page', [largeFixture.records.slice(0, 100)], {}],
    ['missing old rename path', pagesOf(largeFixture.records.map(({ previous_filename, ...r }) => r)), {}],
    ['extra API path', pagesOf([...largeFixture.records, { filename: 'not-in-diff.txt' }]), {}],
    ['moving head', pagesOf(largeFixture.records), { updates: { confirmed_head_sha: sha(999) } }],
    ['moving base', pagesOf(largeFixture.records), { updates: { confirmed_base_sha: sha(998) } }],
    ['duplicate returned inventory', pagesOf(largeFixture.records), { updates: {
      files: [...largeFixture.expected, largeFixture.expected[0]],
      pr_files: [...largeFixture.expected, largeFixture.expected[0]],
      diff_files: [...largeFixture.expected, largeFixture.expected[0]],
    } }],
  ]) {
    const result = await runInventory(largeFixture, pages, options)
    assert(`${label} fails closed with the unchanged mismatch message before any downstream work`,
      result.error?.message === 'Collect returned mixed or moving PR file/revision evidence' &&
      deepSame(result.calls.map(c => c.phase), ['Collect']) && !result.verdictLogged)
  }
  for (const [label, pages, options] of [
    ['API failure despite complete parseable stdout', pagesOf(largeFixture.records), { apiError: true }],
    ['page failure after valid first page', [largeFixture.records.slice(0, 100)], { apiError: true }],
    ['API error object in a page', [largeFixture.records.slice(0, 100), { message: 'Bad Gateway' }], {}],
    ['null page after valid first page', [largeFixture.records.slice(0, 100), null], {}],
    ['truncated JSON despite successful API exit', pagesOf(largeFixture.records), { malformedJson: true }],
  ]) {
    const result = await runInventory(largeFixture, pages, options)
    assert(`${label} propagates command failure instead of returning partial evidence`,
      result.error?.message.startsWith('inventory command failed:') &&
      deepSame(result.calls.map(c => c.phase), ['Collect']) && !result.verdictLogged)
  }
  // GitHub caps this endpoint at 3000 records. The local canonical inventory
  // must remain authoritative even when pagination itself succeeds at the cap.
  const cappedPaths = Array.from({ length: 3001 }, (_, i) => `cap/file-${i}.txt`)
  const capped = await run({ ...GOOD_COLLECT, files: cappedPaths.slice(0, 3000),
    pr_files: cappedPaths.slice(0, 3000), diff_files: cappedPaths }, FULL_READ, { checkCollectSchema: true })
  assert('a successful 3000-file API prefix cannot bypass canonical mismatch',
    capped.error?.message === 'Collect returned mixed or moving PR file/revision evidence' &&
    deepSame(capped.calls.map(c => c.phase), ['Collect']) && !capped.verdictLogged)

  console.log(`RESULT ${nodePass} ${nodeFail}`)
  process.exit(nodeFail > 0 ? 1 : 0)
})().catch((e) => {
  console.log(`FAIL: whole-script harness crashed: ${e && e.stack}`)
  console.log('RESULT 0 1')
  process.exit(1)
})
NODE

run_node whole-script "$TMP/flow.js" "$SRC" "$TMP"

echo "ok — review-adversarial-first: $pass/$((pass + fail)) assertions passed"
exit 0
