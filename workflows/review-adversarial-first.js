export const meta = {
  name: 'review-adversarial-first',
  description: 'Refute-by-default adversarial review (evidence-regime.md §7): 3 lenses + a deterministic judge — the review ladder\'s entry tier (dotfiles #1285)',
  phases: [
    { title: 'Collect', detail: 'resolve the file list, write the diff to a file, compute touched domains' },
    { title: 'LedgerFileRead', detail: 'independent cooperative read of the captured ledger file' },
    { title: 'Lenses', detail: '3 refute-by-default lenses on the session model' },
    { title: 'RedFirst', detail: 'mechanical pre-fix test evidence for recorded PRs' },
    { title: 'RedFileRead', detail: 'independent cooperative read of RED input and output files' },
    { title: 'Judge', detail: 'deterministic dedup + verdict, no agent call' },
    { title: 'Record', detail: 'post the exact immutable PR round' },
    { title: 'Readback', detail: 'read full trusted history independently after every post outcome' },
    { title: 'Cleanup', detail: 'remove this round’s scratch files after readback' },
  ],
}

// ---------------------------------------------------------------------------
// Domain map: pure, unit-tested by tests/review-adversarial-first.test.sh
// via sed-extraction between the BEGIN/END markers below (renaming or moving a
// marker breaks that suite loudly — keep them paired with the extraction there).
// Mirrors evidence-regime.md §7's harness-behavior trigger list: hooks, guards,
// and doctrine/permission/credential surfaces (security), CI-relevant paths
// (ci), and docs-only diffs (docs). A file can match more than one domain; the
// skill decides "docs-only" by checking touched_domains has no member besides
// 'docs', not by relying on this map to special-case that itself.
// === DOMAIN_MAP:BEGIN ===
const DOMAIN_MAP = {
  security: [
    /(^|\/)\.env(\.[^/]*)?$/,
    /credential/i,
    /secret/i,
    /permission/i,
    /(^|\/)hooks\//,
    /guard/i,
    /settings(\.local)?\.json$/,
    /\.mcp\.json$/,
    /(^|\/)(CLAUDE|AGENTS|HARNESS)\.md$/i,
    /(^|\/)harness\/.*\.md$/i,
  ],
  ci: [/(^|\/)\.github\//, /(^|\/)tests\//],
  docs: [/\.md$/i],
}

function matchDomains(files) {
  const list = Array.isArray(files) ? files : []
  const matched = new Set()
  for (const file of list) {
    for (const domain of Object.keys(DOMAIN_MAP)) {
      if (DOMAIN_MAP[domain].some((re) => re.test(file))) matched.add(domain)
    }
  }
  return Array.from(matched).sort()
}
// === DOMAIN_MAP:END ===

// ---------------------------------------------------------------------------
// Lens prompts: pure string construction, unit-tested the same way as the
// domain map. The three lenses are the task's own spec, adapted from
// evidence-regime.md §7's general "own-doctrine / strongest-lever / research
// grounding" triad to code review specifically (there is no separate research-
// grounding lens here because the target is always this repo's own diff, not
// a platform-behavior claim).
// === LENS_PROMPTS:BEGIN ===
const LENSES = [
  {
    id: 'own-doctrine',
    label: 'Own-doctrine conformance',
    instruction:
      "Attack this diff for violating this repo's OWN written doctrine (CLAUDE.md, " +
      'harness/*.md, memory notes under memory/). Do not confirm the author\'s ' +
      'reasoning -- treat every claim in the diff or its PR description as an assertion to ' +
      'attack. Cite the exact doctrine line contradicted, if any; a vague "seems inconsistent" ' +
      'is not a finding.',
  },
  {
    id: 'strongest-lever',
    label: 'Strongest-lever correctness attack',
    instruction:
      'Find the single highest-leverage way this diff could be wrong or unsafe -- the change ' +
      'with the worst blast radius if it silently misbehaves. Try to actually break it (trace ' +
      'callers, edge inputs, concurrent/partial-failure paths); do not stop at the first ' +
      'plausible-looking check.',
  },
  {
    id: 'no-op-or-regression',
    label: 'No-op / regression lens',
    instruction:
      'Ask: what would make this diff a no-op (looks like it changed behavior but did not) or a ' +
      'regression (fixes the stated case but breaks another)? A guard whose condition can never ' +
      'fire, a check stricter or looser than the code it protects, or a fix that only works on ' +
      'the happy path are the exact shapes to hunt for -- this is the failure class topic ' +
      'reviewers routinely miss (see the adversarial-lens-catches-inert-guards memory note).',
  },
]

function buildLensPrompt(lens, target, repo, diffPath, diffLineCount, repoRoot, headSha) {
  return [
    `Refute-by-default review -- ${lens.label} lens (harness/evidence-regime.md §7).`,
    `Review target: ${target}${repo ? ` (repo: ${repo})` : ''}.`,
    ...(repoRoot && headSha ? [
      `Inspect source at captured head ${headSha} in absolute repository root ${repoRoot}: ` +
        `use git -C ${shellQuote(repoRoot)} show ${shellQuote(headSha + ':<repo-relative-path>')} ` +
        'for source files (quote the entire SHA:path argument) ' +
        '(and git tree commands pinned to that SHA for discovery). Never use checkout files, ' +
        'a moving branch or PR metadata as head-source evidence.',
    ] : []),
    '',
    `The diff under review is written to ${diffPath} (${diffLineCount} lines, from \`wc -l\`). Read ` +
      'the ENTIRE file with the Read tool before reviewing -- if it exceeds a single read, page ' +
      `through it with offset/limit until you have covered all ${diffLineCount} lines. Do not review ` +
      'from a partial read, and do not guess at content you have not read.',
    '',
    lens.instruction,
    '',
    'Also assess ordinary_prose for the ENTIRE diff, not just Markdown filenames or your findings. ' +
      'For code, mixed changes or known operational paths, set eligible=false without any extra ' +
      'consumer search. Only investigate eligibility when every change could be ordinary Markdown prose. ' +
      'Set eligible=true ONLY for ordinary human-facing prose, after inspecting repository consumers ' +
      'at the captured revision. Include concise concrete consumer evidence (scripts/configuration ' +
      'or callers inspected and what they establish), not just a filename. Behavior-bearing ' +
      'instructions/frontmatter, executable/generated/test input, agent-loaded memory, security/doctrine ' +
      'or platform/model-behavior claims are NOT ordinary prose. Unknown/custom repository roles, ' +
      'uninspected consumers, code or mixed changes mean eligible=false. Omission is noneligible. ' +
      'A path blocklist alone cannot prove absence of machine consumers.',
    '',
    'Default to refuted=true when uncertain -- the burden is on the finding to survive your own ' +
      'attempt to refute it, not the other way around. Every finding carries a severity (P1 = ' +
      'ships broken or unsafe, P2 = real but bounded, P3 = minor/nit), a one-line title, the file ' +
      'and line if applicable, a short rationale, and a refuted boolean. Do not pad the list with ' +
      'findings you already refuted -- report those only if they are worth recording as a checked ' +
      'and cleared concern. Also report diff_lines_read: the highest line number of the diff file ' +
      'you actually read (used to confirm you read the whole thing, not a truncated prefix).',
  ].join('\n')
}
// === LENS_PROMPTS:END ===

// === FINDINGS_SCHEMA:BEGIN ===
const FINDINGS_SCHEMA = {
  type: 'object',
  properties: {
    diff_lines_read: { type: 'integer' },
    ordinary_prose: {
      type: 'object',
      properties: {
        eligible: { type: 'boolean' },
        evidence: { type: 'string', maxLength: 1000 },
      },
      required: ['eligible', 'evidence'],
      additionalProperties: false,
    },
    findings: {
      type: 'array',
      maxItems: 20,
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'number' },
          severity: { type: 'string', enum: ['P1', 'P2', 'P3'] },
          refuted: { type: 'boolean' },
          rationale: { type: 'string' },
        },
        required: ['title', 'severity', 'refuted'],
      },
    },
  },
  required: ['findings', 'diff_lines_read'],
}
// === FINDINGS_SCHEMA:END ===

// ---------------------------------------------------------------------------
// Collect check: pure, unit-tested the same way as the domain map and judge.
// Guards the #1307 defect (a transcribed diff_text field silently accepted a
// path/prose/truncated string: 11 of 33 local Collect runs over 14 days carried
// no diff marker at all, recount recorded on #1307) by requiring Collect to hand
// back a real file it wrote, not text it typed: an absolute path, a positive
// line count from `wc -l`, and a first line that is actually a diff header.
// === COLLECT_CHECK:BEGIN ===
function validateCollected(collected, numericPr = false, expectedPr = null, expectedRepo = '',
  scratchRoot = null, driverRoot = null) {
  const diffPath = collected && collected.diff_path
  const diffLineCount = collected && collected.diff_line_count
  const firstLine = collected && collected.first_line
  if (typeof diffPath !== 'string' || !diffPath.startsWith('/')) {
    throw new Error(`Collect did not return an absolute diff_path (got ${JSON.stringify(diffPath)})`)
  }
  if (!Number.isInteger(diffLineCount) || diffLineCount <= 0) {
    throw new Error(
      `Collect did not return a positive integer diff_line_count (got ${JSON.stringify(diffLineCount)})`
    )
  }
  if (typeof firstLine !== 'string' || !firstLine.startsWith('diff --git')) {
    throw new Error(`Collect's first_line does not start with 'diff --git' (got ${JSON.stringify(firstLine)})`)
  }
  if (scratchRoot !== null) {
    if (!isRoundDirectory(collected.scratch_dir, scratchRoot) ||
        !isRoundScratch(diffPath, collected.scratch_dir, 'diff.patch')) {
      throw new Error('Collect scratch directory or diff_path is outside the requested fresh scratch root')
    }
    // The workflow cannot see HOME, so the installed default is a suffix match;
    // it must also lie outside the reviewed checkout, whose own .claude/scripts
    // would otherwise pass. Operators may still name any directory explicitly.
    const root = typeof collected.repo_root === 'string' ? collected.repo_root.replace(/\/+$/, '') : null
    if (numericPr && (!isAbsoluteDirectory(collected.driver_dir) ||
        (driverRoot !== null
          ? collected.driver_dir !== driverRoot || collected.driver_source !== 'explicit'
          : collected.driver_source !== 'installed' ||
            !/\/\.claude\/scripts$/.test(collected.driver_dir) || !root ||
            collected.driver_dir === root || collected.driver_dir.startsWith(root + '/')))) {
      throw new Error('Collect did not resolve the operator-selected driver directory')
    }
  }
  if (!numericPr) return
  if (!Array.isArray(collected.files) || !collected.files.every((p) => typeof p === 'string')) {
    throw new Error('Collect did not return a file list')
  }
  if (collected.is_pr !== true) throw new Error('Collect cannot downgrade a numeric PR target')
  const hex40 = /^[0-9a-f]{40}$/
  for (const field of ['head_sha', 'base_sha', 'patch_id']) {
    if (!hex40.test(collected[field])) throw new Error(`Collect did not capture ${field} as a 40-hex revision`)
  }
  if (typeof collected.repo_root !== 'string' || !collected.repo_root.startsWith('/') ||
      !Number.isInteger(collected.diff_lines) || collected.diff_lines < 0 ||
      !Array.isArray(collected.files) ||
      !isRoundScratch(collected.ledger_path, collected.scratch_dir, 'ledger.json')) {
    throw new Error('Collect did not return pinned PR root, diff_lines, files, or ledger_path')
  }
  if (collected.pr_number !== expectedPr || typeof collected.pr_repo !== 'string' ||
      !collected.pr_repo.includes('/') || (expectedRepo && collected.pr_repo !== expectedRepo)) {
    throw new Error('Collect returned a different PR target or repository')
  }
  if (!Array.isArray(collected.pr_files) || !Array.isArray(collected.diff_files) ||
      !sameData([...collected.pr_files].sort(), [...collected.diff_files].sort()) ||
      !sameData([...collected.files].sort(), [...collected.pr_files].sort()) ||
      new Set(collected.files).size !== collected.files.length ||
      collected.confirmed_head_sha !== collected.head_sha ||
      collected.confirmed_base_sha !== collected.base_sha) {
    throw new Error('Collect returned mixed or moving PR file/revision evidence')
  }
  validateLedger(collected.ledger, collected.pr_repo, collected.pr_number)
  if (!collected.selection || !Array.isArray(collected.selection.changed_paths) ||
      !Array.isArray(collected.selection.blob_facts) ||
      !(collected.selection.error === null || typeof collected.selection.error === 'string')) {
    throw new Error('Collect did not return machine-collected test selection facts')
  }
}
// === COLLECT_CHECK:END ===

// ---------------------------------------------------------------------------
// Judge: plain deterministic code, NOT an agent call, so it is unit-testable
// without spawning anything (tests/review-adversarial-first.test.sh).
// Dedup key is (file, line) when both are present -- independent lenses
// phrase the same real finding differently often enough that requiring an
// exact title match would defeat dedup almost entirely; falling back to the
// normalized title only covers findings with no specific location. refuted is
// AND-ed across duplicates, never OR-ed: one lens refuting a claim the other
// substantiated does not make the finding go away -- it stays live until
// every lens that raised it agrees it doesn't hold.
// === JUDGE:BEGIN ===
function normalizeTitle(title) {
  return String(title || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
}

function dedupeFindings(lensResults) {
  const seen = new Map()
  for (const result of lensResults) {
    if (!result || !Array.isArray(result.findings)) continue
    for (const finding of result.findings) {
      const key =
        finding.file && finding.line
          ? `${finding.file}|${finding.line}`
          : `title:${normalizeTitle(finding.title)}`
      const existing = seen.get(key)
      if (!existing) {
        seen.set(key, {
          title: finding.title,
          file: finding.file || '',
          line: finding.line || null,
          severity: finding.severity,
          rationale: finding.rationale || '',
          refuted: !!finding.refuted,
          lenses: [result.lens],
        })
      } else {
        existing.lenses.push(result.lens)
        // The strictest unrefuted report stands for the finding, as in
        // mergeRedFindings: keeping the first lens's would count a live P1 reported
        // second as a P3, or revive a refuted P1 reported first (refute lens at
        // 6f6f3082). A title-keyed merge takes its file too (refute lens at 1c74d45a).
        if (!finding.refuted &&
            (existing.refuted || Number(finding.severity[1]) < Number(existing.severity[1]))) {
          existing.title = finding.title
          existing.file = finding.file || ''
          existing.line = finding.line || null
          existing.severity = finding.severity
          existing.rationale = finding.rationale || ''
        }
        existing.refuted = existing.refuted && !!finding.refuted
      }
    }
  }
  return Array.from(seen.values())
}

function computeVerdict(findings) {
  const live = findings.filter((f) => !f.refuted)
  if (live.some((f) => f.severity === 'P1')) return 'DIRTY'
  if (live.some((f) => f.severity === 'P2' || f.severity === 'P3')) return 'BORDERLINE'
  return 'CLEAN'
}

function judgeFindings(lensResults, touchedDomains) {
  const findings = dedupeFindings(lensResults)
  return {
    verdict: computeVerdict(findings),
    findings,
    touched_domains: Array.isArray(touchedDomains) ? touchedDomains : [],
  }
}

// Coverage gate, run before judgeFindings: a lens that did not read the whole
// diff file (or did not return at all -- already logged separately as a dead
// lens) must not silently count toward a CLEAN verdict. `diff_lines_read`
// below `diffLineCount` fails a lens: the Read tool's last line number equals
// `wc -l` for a newline-terminated file and exceeds it by one otherwise, so
// even skipping only the final line counts as an under-read. A missing entry
// fails the same way. Throws rather than returning a verdict -- this must read
// as a failed run, not a clean pass.
function checkLensCoverage(lensResults, expectedLensIds, diffLineCount) {
  const byId = new Map()
  for (const result of lensResults) {
    if (result && result.lens) byId.set(result.lens, result)
  }
  const underRead = expectedLensIds.filter((id) => {
    const result = byId.get(id)
    const read = result ? result.diff_lines_read : null
    return typeof read !== 'number' || !Number.isFinite(read) || read < diffLineCount
  })
  if (underRead.length) {
    throw new Error(
      `Lens coverage incomplete -- did not read the full diff (or did not run): ${underRead.join(', ')}`
    )
  }
}
// === JUDGE:END ===

// Round decisions are pure: the ledger script owns trust, numbering and prior
// rerun flags; this block consumes its entire read result without a display cap.
// === ROUNDS:BEGIN ===
const HEX40 = /^[0-9a-f]{40}$/
// Keep byte-for-byte diff options aligned with review-prose-exemption.py.
// The captured file is the semantic evidence read by every existing lens.
const CANONICAL_DIFF =
  'git --no-replace-objects -c core.quotePath=true diff ' +
  '--no-color --no-ext-diff --no-textconv --no-renames --ignore-submodules=none ' +
  '--full-index --binary --src-prefix=a/ --dst-prefix=b/ --no-relative --patch ' +
  '--diff-algorithm=myers --no-indent-heuristic --unified=3 --inter-hunk-context=0 ' +
  '--submodule=short --output-indicator-new=+ --output-indicator-old=- ' +
  "'--output-indicator-context= ' --line-prefix= -O/dev/null"
const CASE_REVISIONS = ['pass', 'fail', 'unresolved', 'unsupported']
const CASE_STATUSES = ['verified', 'never-red', 'inconclusive', 'fails-at-head', 'unsupported']
const PATH_STATUSES = ['ran', 'file-level', 'unsupported', 'unverifiable']
const COMMENT_LIMIT = 65536
const TYPED_STOP_LIMIT = 8000
const TYPED_STOP_SUMMARY_LIMIT = 2000

// Cut text to at most `limit` UTF-16 units, ending in an ellipsis, without
// splitting a surrogate pair.
function clipText(text, limit) {
  if (text.length <= limit) return text
  const cut = text.slice(0, limit - 1)
  return `${/[\uD800-\uDBFF]$/.test(cut) ? cut.slice(0, -1) : cut}…`
}

// The Workflow runtime hands the caller only an error's message and stack, so a
// typed stop carries its decision payload as one trailing `payload=` JSON line
// (properties stay for in-process callers). Line separators that JSON leaves
// raw are escaped so the payload stays one line for any line splitter.
// Claude Code 2.1.280 renders the error as `Error: ${message}` plus up to five
// stack lines of at most 501 characters each, and replaces the middle of any
// rendering past 11024 characters with a truncation marker (oc: 10000 kept
// plus FR = 1024), which breaks the JSON. 7 + 8000 + 5 * 502 = 10517, so a
// message within TYPED_STOP_LIMIT survives any stack. The summary is cut to
// TYPED_STOP_SUMMARY_LIMIT first so the payload always has room; then the
// largest arrays shrink to halving prefixes with their original lengths under
// `truncated`, scalars are never altered, and a payload that cannot fit even
// then delivers only its code.
function typedStop(summary, payload, properties = {}) {
  const head = clipText(String(summary).replace(/[\r\n\u0085\u2028\u2029]+/g, ' '), TYPED_STOP_SUMMARY_LIMIT)
  const render = (body) => `${head}\npayload=${JSON.stringify(body).replace(/[\u0085\u2028\u2029]/g,
    (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`)}`
  const fits = (body) => render(body).length <= TYPED_STOP_LIMIT
  let body = payload
  if (!fits(body)) {
    body = { ...payload, truncated: {} }
    const arrays = Object.keys(payload).filter((key) => Array.isArray(payload[key]))
      .sort((a, b) => JSON.stringify(payload[b]).length - JSON.stringify(payload[a]).length)
    for (const key of arrays) {
      for (let kept = payload[key].length; !fits(body) && kept > 0;) {
        body.truncated[key] = payload[key].length
        kept = Math.floor(kept / 2)
        body[key] = payload[key].slice(0, kept)
      }
      if (fits(body)) break
    }
    if (!fits(body)) body = { code: payload.code, truncated: 'payload exceeds the delivery limit' }
  }
  return Object.assign(new Error(render(body)), { code: payload.code }, properties)
}

function isAbsoluteDirectory(path) {
  return typeof path === 'string' && path.startsWith('/') && path !== '/' &&
    path.split('/').slice(1).every((segment) => segment && segment !== '.' &&
      segment !== '..' && !/[\r\n\0]/.test(segment))
}

function isRoundDirectory(path, root) {
  return isAbsoluteDirectory(root) && typeof path === 'string' &&
    /^review-adversarial-first\.[A-Za-z0-9]{6,64}$/.test(path.slice(root.length + 1)) &&
    path.startsWith(`${root}/`)
}

function isRoundScratch(path, directory, filename) {
  return isAbsoluteDirectory(directory) && path === `${directory}/${filename}`
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`
}

function checkTrustedHead(collected, trusted, repo, pr) {
  const head = collected.head_sha
  const fail = (reason) => {
    const error = new Error(`untrusted-head: captured ${head}: ${reason}`)
    error.code = 'untrusted-head'
    error.head_sha = head
    error.reason = reason
    throw error
  }
  if (trusted !== head) fail('explicit trusted_head_sha does not match captured head')
  const identity = collected.pr_identity
  if (!identity || identity.repo !== repo || identity.number !== pr ||
      identity.head_sha !== head || identity.base_sha !== collected.base_sha ||
      identity.head_repo !== repo || identity.base_repo !== repo ||
      !Number.isSafeInteger(identity.head_repo_id) || identity.head_repo_id <= 0 ||
      identity.head_repo_id !== identity.base_repo_id) {
    fail('PR API head/base identity or same-repository provenance is missing or inconsistent')
  }
  if (!Number.isSafeInteger(identity.author_id) || identity.author_id <= 0 ||
      !Number.isSafeInteger(identity.operator_id) || identity.operator_id <= 0 ||
      identity.author_id !== identity.operator_id) {
    fail('PR author numeric API ID is not the authenticated operator numeric API ID')
  }
}

function sameData(a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    return Array.isArray(a) && Array.isArray(b) && a.length === b.length &&
      a.every((v, i) => sameData(v, b[i]))
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const keys = Object.keys(a).sort()
    return sameData(keys, Object.keys(b).sort()) && keys.every((key) => sameData(a[key], b[key]))
  }
  return a === b
}

// Collect carries U1's `read --compact` view: each RED test's command, reason
// and per-case statuses stay on the PR comment. On PR #1390 a Collect agent
// abbreviated the full 22.5 KB history instead of echoing it; no decision reads
// those fields. Case names stay: the never-red carry reads them.
function validateLedger(ledger, repo, pr) {
  if (!ledger || !sameData(ledger.target, { repo, pr }) || ledger.view !== 'compact' ||
      !Array.isArray(ledger.rounds) || !Array.isArray(ledger.ledger_errors)) {
    throw new Error('Ledger read failed or is not the U1 compact {target,rounds,ledger_errors,view} envelope')
  }
  if (ledger.ledger_errors.some((error) => error?.kind !== 'untrusted-author')) {
    throw typedStop('ledger-history-incomplete: marker history has invalid or unknown trust',
      { code: 'ledger-history-incomplete', ledger_errors: ledger.ledger_errors }, { errors: ledger.ledger_errors })
  }
  ledger.rounds.forEach((entry, index) => {
    const r = entry && entry.record
    if (entry.round !== index + 1 || typeof entry.rerun !== 'boolean' ||
        !Number.isInteger(entry.comment_id) || !Number.isInteger(entry.author_id) ||
        typeof entry.created_at !== 'string' || !r || r.schema !== 'review-adversarial-first/round/v1' ||
        !HEX40.test(r.head) || !HEX40.test(r.patch_id) || !Number.isInteger(r.diff_lines) ||
        !Number.isInteger(r.streak) || !r.live || !Number.isInteger(r.live.P1) ||
        !Number.isInteger(r.live.P2) || !Array.isArray(r.findings) || !Array.isArray(r.red_first?.tests) ||
        !r.red_first.tests.every((t) => t && typeof t.path === 'string' && Array.isArray(t.cases) &&
          t.cases.every((c) => c && typeof c.name === 'string'))) {
      throw new Error(`Ledger round ${index + 1} has an invalid trusted envelope or record`)
    }
  })
  for (const error of ledger.ledger_errors) {
    if (!error || typeof error.reason !== 'string') throw new Error('Ledger errors are malformed')
  }
  return ledger.rounds
}

function isTestPath(path) {
  return typeof path === 'string' && (
    /\.test\.[^/]*$/.test(path) || /^claude\/tests\/test_[^/]*\.py$/.test(path)
  )
}

// A path's baseline is fixed on first sight (KTD2): the earliest trusted record
// naming the path at a head recorded in trusted history; any other stored value
// is ignored. A record names the path by the baseline its run requested and by
// its effective entries (older records store no request); the earliest recorded
// head among them wins. A Red-first-base trailer's effective revision is often
// no recorded head: reading only effective entries skipped that first run, a
// later head already holding a never-red case became first sight, and the file
// came back unchanged there (Pro gate round 5 at a0f01cd9). red-first.sh
// re-derives trailers on every run, so a later record's never replaces the
// first sight. A first sight whose run came back
// unverifiable (its baseline rebased away) still counts: falling back to the
// latest head would start the next run past the round that added the test, so
// its cases would never be attributed. The heads filter is not a defense
// against edited marker comments (an edit can rewrite a record's head as well):
// red-first.sh's check that every effective pre-fix is an ancestor of the
// resolved head is the execution boundary. A selection-error round recorded its
// unverified previous head for every PR test path, so it carries nothing.
function carriedBaseline(path, prior) {
  const order = new Map()
  prior.forEach((entry, index) => { if (!order.has(entry.record.head)) order.set(entry.record.head, index) })
  for (const entry of prior) {
    const red = entry.record.red_first
    if (typeof red.selection_error === 'string' && red.selection_error) continue
    const requested = Array.isArray(red.requested) ? red.requested : []
    const named = [...requested, ...red.tests, ...(red.unchanged || [])]
      .filter((item) => item && item.path === path && HEX40.test(item.pre_fix) && order.has(item.pre_fix))
      .map((item) => item.pre_fix)
    if (named.length) return named.reduce((a, b) => (order.get(b) < order.get(a) ? b : a))
  }
  return null
}

// Plan R2: the round is DIRTY while a never-red finding is live. A same-head
// re-run or a source-only round selects no test, so the last record's never-red
// P1s (title 'never-red regression test: <path>::<case>') carry until this round
// holds evidence about that case: a run named the case (any fresh never-red comes
// from redFirstFindings; a file-level run's synthetic whole-file case does not
// count), a case-level run started from the revision the live P1 was flagged
// against (its diff to head attributes every case changed since, so an absent
// case was reverted, renamed or deleted), the path is unchanged against its
// requested baseline, or the path left the PR or is absent at head. That
// revision is the earliest run naming the case among the trailing records that
// still hold the P1. A trailer that moves the baseline past the case, or
// unchanged against any other revision, says nothing about it. Neither does a
// later re-flag, since a case can be reverted to a version already judged
// never-red; nor an earlier run, such as one that verified a stronger version
// (Pro gate round 4 at b30807d2). Each record stores its live findings, so the
// carry chains across rounds. A P1 whose case no recorded RED test names is carried too: the
// history arrives by cooperative agent transport, and requiring the attribution
// turned a shortened case list into a dropped P1 (refute lens at 6f6f3082, before
// LedgerFileRead). A record keeps no finding's source, so a lens title that copies
// the prefix is carried as well; that errs toward keeping.
const NEVER_RED_PREFIX = 'never-red regression test: '
function carriedNeverRed(prior, report, files, removedAtHead) {
  if (!prior.length) return []
  const last = prior[prior.length - 1].record
  const requested = new Map((report.requested || []).map((item) => [item.path, item.pre_fix]))
  const names = (t, caseName) => t.cases.some((c) => c.name === caseName && c.name !== t.path)
  const flaggedAgainst = (f, caseName) => {
    let origin = null
    for (let i = prior.length - 1; i >= 0; i--) {
      const record = prior[i].record
      if (!record.findings.some((g) => g.severity === 'P1' && g.file === f.file && g.title === f.title)) break
      const test = record.red_first.tests.find((t) => t.path === f.file && names(t, caseName))
      if (test) origin = test.pre_fix
    }
    return origin
  }
  const cleared = (f) => {
    const title = String(f.title)
    const key = title.startsWith(NEVER_RED_PREFIX) ? title.slice(NEVER_RED_PREFIX.length) : ''
    const caseName = key.startsWith(`${f.file}::`) ? key.slice(f.file.length + 2) : null
    const flagged = caseName === null ? null : flaggedAgainst(f, caseName)
    return !files.includes(f.file) || removedAtHead.has(f.file) ||
      report.tests.some((t) => t.path === f.file &&
        (((t.status === 'ran' || t.status === 'file-level') && names(t, caseName)) ||
          (t.status === 'ran' && flagged !== null && t.pre_fix === flagged))) ||
      report.unchanged.some((item) => item.path === f.file && requested.has(f.file) &&
        item.pre_fix === requested.get(f.file))
  }
  return last.findings
    .filter((f) => f.severity === 'P1' && String(f.title).startsWith('never-red regression test:') &&
      !cleared(f))
    .map((f) => ({ file: f.file, severity: 'P1', title: f.title,
      rationale: `carried from round ${prior.length} (head ${last.head}): no evidence about the case this round`,
      refuted: false, lenses: ['red-first'] }))
}

function buildManifest(files, prior, selection, head, base) {
  if (!prior.length) return { manifest: [], selection_error: null }
  const previous = prior[prior.length - 1].record.head
  if (selection.previous_head !== previous || selection.head_sha !== head || selection.base_sha !== base) {
    throw new Error('Collect mixed revision coordinates for RED selection')
  }
  const eligible = [...new Set(files.filter(isTestPath))]
  if (typeof selection.error === 'string' && selection.error.length) {
    return { manifest: [], selection_error: selection.error }
  }
  if (selection.error !== null) throw new Error('RED selection error must be a command failure or null')
  const changed = selection.changed_paths
  if (new Set(changed).size !== changed.length || changed.some((path) => typeof path !== 'string')) {
    throw new Error('Collect returned duplicate or invalid changed paths')
  }
  const selected = changed.filter((path) => eligible.includes(path))
  // Facts for other changed paths are harmless extra evidence; a duplicate or
  // a fact for an unchanged path contradicts the captured selection.
  const facts = selection.blob_facts
  if (new Set(facts.map((f) => f && f.path)).size !== facts.length ||
      facts.some((f) => !f || !changed.includes(f.path)) ||
      selected.some((path) => !facts.some((f) => f && f.path === path &&
        typeof f.head_blob === 'string' && typeof f.previous_blob === 'string' &&
        f.head_blob !== f.previous_blob))) {
    throw new Error('Collect returned incomplete or contradictory machine blob facts')
  }
  return {
    manifest: selected.map((path) => ({ path, pre_fix: carriedBaseline(path, prior) || previous })),
    selection_error: null,
  }
}

function selectionUnverifiable(files, prior, head, base, error) {
  const previous = prior[prior.length - 1].record.head
  const reason = `selection-unverifiable: ${error}`
  return {
    head, base_branch: base, overlay: [], exempt: [], unchanged: [], selection_error: reason,
    tests: [...new Set(files.filter(isTestPath))].map((path) => ({
      path, pre_fix: carriedBaseline(path, prior) || previous,
      status: 'unverifiable', command: null, reason, exempt: false, exempt_reason: null, cases: [],
    })),
  }
}

function checkRedReport(report, manifest, head, base) {
  if (!report || report.head !== head || report.base_branch !== base ||
      !Array.isArray(report.tests) || !Array.isArray(report.unchanged) ||
      !Array.isArray(report.overlay) || !Array.isArray(report.exempt)) {
    throw new Error('RedFirst missing or mixed head/base/report evidence')
  }
  const expected = manifest.map((m) => m.path)
  const requested = report.requested
  const byPath = (a, b) => String(a?.path).localeCompare(String(b?.path))
  if (!Array.isArray(requested) || new Set(requested.map((item) => item?.path)).size !== requested.length ||
      !sameData([...manifest].sort(byPath), [...requested].sort(byPath))) {
    throw new Error('RedFirst requested inputs do not match selected manifest path/baseline pairs')
  }
  const actual = [...report.tests.map((t) => t && t.path), ...report.unchanged.map((t) => t && t.path)]
  if (new Set(expected).size !== expected.length || !sameData([...expected].sort(), [...actual].sort())) {
    throw new Error('RedFirst report does not exactly partition selected manifest paths')
  }
  for (const item of report.unchanged) {
    if (typeof item.pre_fix !== 'string' || !item.pre_fix) throw new Error('RedFirst unchanged baseline missing')
  }
  const exempted = report.tests.filter((t) => t?.exempt)
    .map((t) => ({ path: t.path, reason: t.exempt_reason }))
  if (!sameData([...exempted].sort((a, b) => a.path.localeCompare(b.path)),
    [...report.exempt].sort((a, b) => String(a.path).localeCompare(String(b.path))))) {
    throw new Error('RedFirst exemption list conflicts with per-path evidence')
  }
  for (const test of report.tests) {
    if (!test || !PATH_STATUSES.includes(test.status) || !test.path ||
        typeof test.pre_fix !== 'string' || !test.pre_fix ||
        !Array.isArray(test.cases) || typeof test.exempt !== 'boolean' ||
        !(test.reason === null || typeof test.reason === 'string') ||
        !(test.command === null || typeof test.command === 'string') ||
        !(test.exempt_reason == null || typeof test.exempt_reason === 'string') ||
        (test.exempt && !test.exempt_reason)) {
      throw new Error('RedFirst returned a malformed test result')
    }
    if ((test.status === 'unsupported' || test.status === 'unverifiable') &&
        !test.reason) throw new Error(`RedFirst ${test.path} lacks a failure reason`)
    if (test.status === 'unverifiable' && test.cases.length) {
      throw new Error(`RedFirst ${test.path} has cases for an unverifiable path`)
    }
    if (test.status === 'ran' && !test.cases.length) throw new Error(`RedFirst ${test.path} has no named cases`)
    if (test.status === 'file-level' && !test.cases.length) {
      throw new Error(`RedFirst ${test.path} lacks its file-level result`)
    }
    for (const c of test.cases) {
      if (!c || typeof c.name !== 'string' || !c.name ||
          !CASE_REVISIONS.includes(c.pre_fix) || !CASE_REVISIONS.includes(c.head) ||
          !CASE_STATUSES.includes(c.status)) throw new Error(`RedFirst ${test.path} has a malformed case`)
      const expectedStatus = c.pre_fix === 'unsupported' || c.head === 'unsupported' ? 'unsupported'
        : c.pre_fix === 'unresolved' || c.head === 'unresolved' ? 'inconclusive'
          : c.pre_fix === 'fail' && c.head === 'pass' ? 'verified'
            : c.pre_fix === 'pass' && c.head === 'pass' ? 'never-red' : 'fails-at-head'
      if (c.status !== expectedStatus || (test.status === 'ran' && c.name === test.path) ||
          (test.status === 'unsupported' && (c.name !== test.path || c.status !== 'unsupported'))) {
        throw new Error(`RedFirst ${test.path}::${c.name} contradicts path/revision statuses`)
      }
    }
  }
}

function redFirstFindings(report) {
  const findings = []
  const add = (test, title, severity, reason) => findings.push({
    file: test.path, title, severity, rationale: `${reason}; pre-fix ${test.pre_fix}; head ${report.head}`,
    refuted: false, lenses: ['red-first'],
  })
  if (report.selection_error) {
    add({ path: '(RED selection)', pre_fix: 'unknown' }, 'red-first not verifiable: changed test selection',
      'P2', report.selection_error)
  }
  for (const test of report.tests) {
    if (test.status === 'unverifiable' || test.status === 'unsupported') {
      add(test, `red-first not verifiable: ${test.path}`, 'P2', test.reason)
      continue
    }
    let fallback = test.status === 'file-level'
    for (const c of test.cases) {
      // The runner's synthetic whole-file result is not named-case RED proof.
      if (test.status === 'file-level' && c.name === test.path) continue
      if (c.status === 'verified') continue
      const reason = `${test.reason || c.status}; case ${c.pre_fix} at pre-fix, ${c.head} at head` +
        (test.exempt ? `; exemption: ${test.exempt_reason}` : '')
      const label = c.status === 'never-red' ? 'never-red regression test' : `red-first ${c.status}`
      add(test, `${label}: ${test.path}::${c.name}`,
        c.status === 'never-red' ? (test.exempt ? 'P3' : 'P1') : 'P2', reason)
    }
    if (fallback) add(test, `red-first file-level fallback: ${test.path}`, 'P2',
      test.reason || 'case-level RED not attributable (file-level runner result)')
  }
  return findings
}

function composeRedFirst(report, findings, applicable) {
  if (!applicable) return { status: 'not-applicable', tests: [] }
  const status = report.selection_error || (report.tests.length && report.tests.every((t) => t.status === 'unverifiable'))
    ? 'unverifiable'
    : findings.some((f) => f.severity === 'P1' && f.title.startsWith('never-red regression test:'))
      ? 'never-red'
      : findings.some((f) => f.severity === 'P2') ? 'inconclusive'
        : report.tests.length ? 'verified' : 'not-applicable'
  return { ...report, status }
}

// A RED finding keeps its exact path::case identity (Pro gate at e96e1eee):
// cases whose titles normalize alike stay separate, and a lens finding that
// matches one takes its title, which the never-red carry parses, when RED sets
// the severity. A stricter lens keeps its own title, so a lens P1 turns an
// exempt never-red P3 into a carried P1 only when the lens's own title is a
// never-red title (verify lens at 82cab14f); a refuted lens finding is never the
// stricter one (verify lens at a31af260).
function mergeRedFindings(lensFindings, redFindings) {
  const merged = lensFindings.map((f) => ({ ...f, lenses: [...f.lenses] }))
  for (const red of redFindings) {
    const match = merged.find((f) => f.file === red.file && (f.lenses.includes('red-first')
      ? f.title === red.title : normalizeTitle(f.title) === normalizeTitle(red.title)))
    if (!match) { merged.push(red); continue }
    if (match.refuted || Number(red.severity[1]) <= Number(match.severity[1])) {
      match.severity = red.severity
      match.title = red.title
    }
    match.refuted = false
    match.rationale = red.rationale
    match.lenses.push('red-first')
  }
  return merged
}

function liveCounts(findings) {
  const counts = { P1: 0, P2: 0, P3: 0 }
  for (const f of findings) {
    if (!f.refuted && Object.hasOwn(counts, f.severity)) counts[f.severity]++
  }
  return counts
}

function residualClasses(findings) {
  const byFile = new Map()
  for (const f of findings) {
    if (f.refuted || !['P1', 'P2'].includes(f.severity)) continue
    const group = byFile.get(f.file) || { file: f.file, severity: f.severity, titles: [] }
    if (f.severity === 'P1') group.severity = 'P1'
    if (!group.titles.includes(f.title)) group.titles.push(f.title)
    byFile.set(f.file, group)
  }
  return [...byFile.values()].sort((a, b) => a.file.localeCompare(b.file))
}

function roundTable(prior, record) {
  return [...prior.map((entry) => ({ ...entry.record, round: entry.round, rerun: entry.rerun })),
    ...(record ? [record] : [])]
    .map((r) => ({ round: r.round, head: r.head, verdict: r.verdict, live: r.live,
      diff_lines: r.diff_lines, streak: r.streak, rerun: r.rerun }))
}

function scoreRound(prior, head, patchId, diffLines, findings) {
  const seen = new Set(prior.map((entry) => entry.record.head))
  const scored = prior.filter((entry) => !entry.rerun)
  const previous = scored.length ? scored[scored.length - 1].record : null
  const rerun = seen.has(head) || (previous !== null && previous.patch_id === patchId)
  const count = liveCounts(findings).P1 + liveCounts(findings).P2
  let streak = prior.length ? prior[prior.length - 1].record.streak : 0
  if (!rerun) {
    const previousCount = previous && previous.live.P1 + previous.live.P2
    streak = previous && count > 0 && count >= previousCount && diffLines >= previous.diff_lines
      ? streak + 1 : 0
  }
  return { rerun, streak, frozen: streak >= 2, residual_classes: streak >= 2 ? residualClasses(findings) : [] }
}

// COMMENT_LIMIT (65536 characters) is not in GitHub's published API docs; it
// is papercut's local refusal of issue bodies past it, added on an issue #527
// review finding (tests/test_papercut.py), and comment bodies are
// assumed to share it; no comment post has been observed failing at it. U1
// posts json.dumps output, whose ensure_ascii escapes each
// UTF-16 unit above 0x7e as \uXXXX, inside a marker, table and fence that 1024
// covers: never an undercount.
function recordBodyEstimate(record) {
  const text = JSON.stringify(record, null, 2)
  let estimate = 1024
  for (let i = 0; i < text.length; i++) estimate += text.charCodeAt(i) > 0x7e ? 6 : 1
  return estimate
}

function composeRecord(prior, collected, findings, underlying, redFirst, override, touchedDomains = [], lensResults = []) {
  const score = scoreRound(prior, collected.head_sha, collected.patch_id, collected.diff_lines, findings)
  const verdict = score.frozen && !override ? 'FROZEN' : underlying
  const record = {
    schema: 'review-adversarial-first/round/v1', round: prior.length + 1,
    head: collected.head_sha, patch_id: collected.patch_id, diff_lines: collected.diff_lines,
    verdict, underlying_verdict: underlying, live: liveCounts(findings),
    findings: findings.filter((f) => !f.refuted).map(({ file, severity, title }) => ({ file, severity, title })),
    red_first: redFirst, streak: score.streak, override, rerun: score.rerun,
    ledger_errors: collected.ledger.ledger_errors,
  }
  // Optional semantic evidence from the existing lenses, never a domain-map inference.
  // Mechanical file/revision checks remain the terminal helper's independent job.
  if (verdict === 'CLEAN' && underlying === 'CLEAN' && !override && !score.frozen &&
      record.live.P1 === 0 && record.live.P2 === 0 && record.ledger_errors.length === 0 &&
      HEX40.test(collected.base_sha) && HEX40.test(collected.head_sha) &&
      typeof collected.patch_sha256 === 'string' && collected.patch_sha256.length === 64 &&
      /^[0-9a-f]{64}$/.test(collected.patch_sha256) &&
      Number.isInteger(collected.diff_line_count) && collected.diff_line_count > 0 &&
      lensResults.length === LENSES.length && LENSES.every(({ id }) => {
        const matches = lensResults.filter(r => r?.lens === id)
        const r = matches[0]
        const p = r?.ordinary_prose
        return matches.length === 1 && Number.isFinite(r.diff_lines_read) &&
          r.diff_lines_read >= collected.diff_line_count && p?.eligible === true &&
          typeof p.evidence === 'string' && p.evidence.trim().length > 0 && p.evidence.length <= 1000
      })) {
    record.ordinary_prose = { base: collected.base_sha, head: collected.head_sha,
      patch_sha256: collected.patch_sha256,
      evidence: LENSES.map(({ id }) => ({ lens: id,
        consumer_evidence: lensResults.find(r => r.lens === id).ordinary_prose.evidence.trim() })) }
  }
  if (verdict === 'FROZEN') record.residual_classes = score.residual_classes
  if (record.findings.length > 200 || redFirst.tests.length > 100 ||
      redFirst.tests.some((t) => t.cases.length > 200) || score.residual_classes.length > 200) {
    throw new Error('Round exceeds U1 ledger bounds; cannot silently truncate evidence')
  }
  // An oversized body fails every posting attempt alike, after lenses and RED
  // have already been paid for; stop before any Record agent runs.
  const estimate = recordBodyEstimate(record)
  if (estimate > COMMENT_LIMIT) {
    throw typedStop(`ledger-record-too-large: round ${record.round} record body would be about ${estimate} ` +
      `characters (GitHub comment limit ${COMMENT_LIMIT}); nothing was posted`, {
      code: 'ledger-record-too-large', estimated_chars: estimate, limit: COMMENT_LIMIT,
      pr_repo: collected.pr_repo, pr_number: collected.pr_number, round: record.round, verdict,
      underlying_verdict: underlying, touched_domains: touchedDomains, live: record.live,
      red_first_status: redFirst.status, findings: record.findings,
    }, { estimated_chars: estimate, limit: COMMENT_LIMIT })
  }
  return { record, score }
}

// U1 `confirm` compares current trusted history with the captured ledger file
// and the pending record; agents carry only its outcome. On PR #1390 round 4 a
// Readback agent re-typing history "corrected" a duplicate round and failed a
// correct post. true = exact single append, false = unchanged (retry allowed).
function confirmOutcome(confirmation, record, priorCount) {
  const c = confirmation
  const settled = c && c.round === null && c.comment_id === null
  if (c?.status === 'appended' && c.rounds === priorCount + 1 && c.round === record.round &&
      Number.isInteger(c.comment_id) && c.reason === null) return true
  if (c?.status === 'unchanged' && c.rounds === priorCount && settled && c.reason === null) return false
  if (c?.status === 'conflict' && settled && typeof c.reason === 'string' && c.reason) {
    throw new Error(`Ledger readback conflicts with the captured trusted history: ${c.reason}`)
  }
  throw new Error('Ledger confirmation is missing, malformed or inconsistent')
}
// === ROUNDS:END ===

// ---------------------------------------------------------------------------
// args: { target, repo?, continue_past_freeze?, trusted_head_sha?, driver_root?, scratch_root? }
const target = (args && args.target) || ''
const repo = (args && args.repo) || ''
const numericPr = /^[0-9]+$/.test(String(target))
const override = args?.continue_past_freeze === undefined ? false : args.continue_past_freeze
const trustedHead = args?.trusted_head_sha
const driverRoot = args?.driver_root === undefined ? null : args.driver_root
const scratchRoot = args?.scratch_root === undefined ? '/tmp' : args.scratch_root
if (typeof override !== 'boolean') throw new Error('continue_past_freeze must be a boolean')
if (trustedHead !== undefined && (typeof trustedHead !== 'string' || !HEX40.test(trustedHead))) {
  throw new Error('trusted_head_sha must be an exact 40-hex SHA')
}
if (driverRoot !== null && !isAbsoluteDirectory(driverRoot)) {
  throw new Error('driver_root must be an absolute directory path (no dot or empty segments)')
}
if (!isAbsoluteDirectory(scratchRoot)) {
  throw new Error('scratch_root must be an absolute directory path (no dot or empty segments)')
}
if (numericPr && repo && !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) {
  throw new Error('repo must be an owner/name identifier for a numeric PR')
}
if (!target) {
  throw new Error('review-adversarial-first requires args.target (a PR number, branch, or path)')
}

phase('Collect')
// Collection needs Bash (gh/git) to resolve an arbitrary PR-number/branch/path
// target and to write the diff to a file, so it runs as a normal (Bash-
// capable) agent rather than the agentType: 'lean-reader' restriction
// (Read/Grep/Glob only, no Bash) -- lean-reader could not run `gh pr diff`
// or `git diff` at all. It inherits session effort: every lens reads this
// stage's output, and the #1322 measurement showed effort: 'low' miscounting
// its own files (dropped in #1332).
const collected = await agent(
  [
    `Resolve the file list and unified diff for review target "${target}"` +
      (repo ? ` in repo ${repo}.` : '.'),
    `Create a fresh unique directory under ${shellQuote(scratchRoot)} with ` +
      '`mktemp -d <scratch_root>/review-adversarial-first.XXXXXXXX` (quote the whole template); ' +
      'return its absolute scratch_dir. Use ONLY its direct children diff.patch and ledger.json ' +
      'for the captured diff and ledger. Redirect the diff command to diff.patch; never ' +
      'type/transcribe the diff yourself. Leave existing scratch untouched.',
    driverRoot === null
      ? 'Expand HOME for the operator-installed ~/.claude/scripts directory to an absolute ' +
        'driver_dir without dereferencing its symlink; return driver_source="installed". ' +
        'NEVER derive a driver from the target checkout or PR.'
      : `Use ONLY explicit driver directory ${shellQuote(driverRoot)} (no scripts suffix); ` +
        'return it exactly as driver_dir and driver_source="explicit".',
    'For PR targets, confirm both red-first.sh and review-rounds.py are regular, readable ' +
      'files directly in driver_dir before review; fail if either is missing/unavailable. ' +
      'Return drivers_ready=true only after checking. Branch/path targets need no PR drivers. ' +
      'Quote every file argument in shell commands.',
    '- If the target is a bare number, it is a PR number. Resolve the owner/repo if omitted. ' +
      'Capture baseRefOid and headRefOid in ONE `gh pr view <target> --repo <repo> --json ' +
      'baseRefOid,headRefOid,number` call. Return pr_repo, pr_number (integer), is_pr=true, ' +
      'base_sha and head_sha, and the absolute repo_root from `git rev-parse --show-toplevel`. ' +
      'Also get authoritative PR identity from `gh api repos/<repo>/pulls/<number>` ' +
      '(number, head.sha, base.sha, head.repo.id/full_name, base.repo.id/full_name, user.id) ' +
      'and authenticated operator ID from `gh api user` (`id` as a number). Return ' +
      'pr_identity {repo,number,head_sha,base_sha,head_repo,base_repo,head_repo_id,' +
      'base_repo_id,author_id,operator_id} using ONLY these API fields and the resolved repo. ' +
      'Compare API head/base/number with the captured gh pr view coordinates; fail if they ' +
      'differ. PR body, login, association and commit email never confer trust. ' +
      'Fetch the two captured SHAs if absent; never substitute a moving branch. In that root, ' +
      `write \`${CANONICAL_DIFF} <base_sha>...<head_sha> -- > <diff_path>\`; ` +
      'use these exact canonical options to disable replacement objects, external diff drivers, ' +
      'textconv and rename/submodule hiding. Run `sha256sum <diff_path>` on that actual captured ' +
      'file and return its lowercase 64-hex digest as patch_sha256; every lens reads THAT same ' +
      'file. Never hash a different diff or reconstruct the patch. Derive the stable ' +
      '`git patch-id --stable` from THAT file, and diff_lines as the sum of added + deleted ' +
      `numeric \`${CANONICAL_DIFF} --no-patch --numstat <base_sha>...<head_sha> --\` columns (not wc -l). ` +
      'List PR files from paginated metadata (not the size-capped diff endpoint): ' +
      '`set -o pipefail; gh api --paginate --slurp \'repos/<repo>/pulls/<number>/files?per_page=100\' ' +
      '| jq -e \'if type == "array" and all(.[]; type == "array") then ' +
      '[.[][] | .filename, .previous_filename | select(. != null)] | unique ' +
      'else error("invalid PR files pages") end\'`. Parse its single JSON array as pr_files, ' +
      'the globally deduplicated union of filename and every non-null previous_filename across ALL pages. ' +
      'Keep path strings exact, including Unicode and whitespace; never split JSON paths on lines or trim them. ' +
      'Any API, pagination or jq error is a hard failure; never use partial stdout. ' +
      `Return the separate \`${CANONICAL_DIFF} --name-only -z <base_sha>...<head_sha> --\` as diff_files, ` +
      'decoding its NUL-delimited paths without trimming or Git quote parsing, and fail on disagreement. ' +
      'The files API has a 3000-file cap: an incomplete inventory must still fail this exact comparison. ' +
      'Return files as that exact PR-wide list. ' +
      'Run `python3 <driver_dir>/review-rounds.py read --repo <repo> --pr <target> --compact` ' +
      'with stdout redirected to <scratch_dir>/ledger.json (never retype it: the later readback ' +
      'compares against that exact file); return its path as ledger_path and its parsed ' +
      'contents unchanged as ledger {target,rounds,ledger_errors,view}; ' +
      'never abbreviate, summarize or annotate any field. ' +
      'A failed read is a hard failure. ' +
      'For a prior round, use the LAST recorded head (even a rerun) and obtain ' +
      '`git diff --name-only <previous_head> <head_sha>` for selection.changed_paths; ' +
      'fetch the old head first if needed. For each changed PR test path (a basename ' +
      'containing `.test.`, or tests/test_*.py; other files under tests are not ' +
      'test paths) return machine ' +
      '`git ls-tree` facts {path,previous_blob,head_blob} as full tree-entry strings (use an ' +
      'empty string for an absent path); include selection {previous_head,head_sha,base_sha,' +
      'changed_paths,blob_facts,error:null}. If the previous head genuinely cannot be fetched ' +
      'or compared, return the failed command and diagnostic in selection.error, not an empty ' +
      'changed list; leave changed_paths and blob_facts empty in that case. With no history, ' +
      'return selection {previous_head:null,head_sha,base_sha,changed_paths:[],blob_facts:[],error:null}. ' +
      'Recheck PR baseRefOid/headRefOid before returning as confirmed_base_sha and ' +
      'confirmed_head_sha; throw if either moved. Return no guess, fabricated JSON or ' +
      'truncated round history.',
    '- If it names an existing branch, run `git diff --name-only origin/main...<target>` for the ' +
      'file list and `git diff --no-color origin/main...<target> > <diff_path>` for the diff.',
    '- Otherwise treat it as a path: `git diff --no-color -- <path> > <diff_path>` against the ' +
      'working tree, or `git log -p -1 --no-color --format= -- <path> > <diff_path>` if the tree is ' +
      'clean at that path (the empty --format drops the commit header, so the file opens with ' +
      '`diff --git`; the color flags keep a color-forcing git or gh config from prefixing it with ' +
      'escape codes).',
    'Then run `wc -l <diff_path>` for diff_line_count and read the file\'s literal first line for ' +
      'first_line. Return every changed file path, diff_path (the absolute path you wrote), ' +
      'diff_line_count, and first_line -- not the diff contents themselves. ' +
      'For branch/path targets return is_pr=false; do not run either PR primitive.',
  ].join('\n'),
  {
    phase: 'Collect',
    schema: {
      type: 'object',
      properties: {
        files: { type: 'array', items: { type: 'string' } },
        pr_files: { type: 'array', items: { type: 'string' } },
        diff_files: { type: 'array', items: { type: 'string' } },
        confirmed_head_sha: { type: 'string' },
        confirmed_base_sha: { type: 'string' },
        diff_path: { type: 'string' },
        diff_line_count: { type: 'integer' },
        first_line: { type: 'string' },
        is_pr: { type: 'boolean' },
        pr_repo: { type: 'string' },
        pr_number: { type: 'integer' },
        repo_root: { type: 'string', ...(numericPr ? { pattern: '^/' } : {}) },
        scratch_dir: { type: 'string', pattern: '^/' },
        driver_dir: { type: 'string', ...(numericPr ? { pattern: '^/' } : {}) },
        driver_source: { type: 'string', ...(numericPr ? { enum: ['installed', 'explicit'] } : {}) },
        drivers_ready: { type: 'boolean', ...(numericPr ? { enum: [true] } : {}) },
        pr_identity: {
          type: 'object',
          ...(numericPr ? {
            properties: {
              repo: { type: 'string' },
              number: { type: 'integer', minimum: 1 },
              head_sha: { type: 'string' },
              base_sha: { type: 'string' },
              head_repo: { type: 'string' },
              base_repo: { type: 'string' },
              head_repo_id: { type: 'integer', minimum: 1 },
              base_repo_id: { type: 'integer', minimum: 1 },
              author_id: { type: 'integer', minimum: 1 },
              operator_id: { type: 'integer', minimum: 1 },
            },
            required: ['repo', 'number', 'head_sha', 'base_sha', 'head_repo', 'base_repo',
              'head_repo_id', 'base_repo_id', 'author_id', 'operator_id'],
          } : {}),
        },
        base_sha: { type: 'string' },
        head_sha: { type: 'string' },
        patch_id: { type: 'string' },
        patch_sha256: { type: 'string', pattern: '^[0-9a-f]{64}$', minLength: 64, maxLength: 64 },
        diff_lines: { type: 'integer' },
        ledger_path: { type: 'string', ...(numericPr ? { pattern: '^/' } : {}) },
        ledger: { type: 'object' },
        selection: { type: 'object' },
      },
      // Select by the caller's target, never by Collect's self-reported is_pr.
      // Only scratch_dir joins the common contract. Numeric PRs always read
      // the pinned inventory, drivers, ledger and selection; branch/path runs
      // return before recording and need none of those fields. Numeric PRs
      // must collect complete identity even on round one; later-round trust
      // still independently checks its provenance. Keep patch_sha256 optional.
      required: ['files', 'diff_path', 'diff_line_count', 'first_line', 'is_pr', 'scratch_dir',
        ...(numericPr ? ['pr_files', 'diff_files', 'confirmed_head_sha', 'confirmed_base_sha',
          'pr_repo', 'pr_number', 'repo_root', 'driver_dir', 'driver_source', 'drivers_ready',
          'base_sha', 'head_sha', 'patch_id', 'diff_lines', 'ledger_path', 'ledger', 'selection',
          'pr_identity'] : [])],
    },
  }
)

validateCollected(collected, numericPr, Number(target), repo, scratchRoot, driverRoot)
if (numericPr && collected.drivers_ready !== true) {
  throw new Error('Collect did not confirm required trusted drivers')
}
// Admission, selection, baselines and the never-red carry all read Collect's copy
// of the history, and U1 confirm checks only the captured file, so a separate
// reader re-reads that file and the copy must equal it, as RedFileRead does for
// RED (refute lens at 1c74d45a: a shortened copy validated and recorded CLEAN).
if (numericPr) {
  phase('LedgerFileRead')
  let ledgerRead = null
  try {
    ledgerRead = await agent([
      `Read the ENTIRE contents of the existing file ${collected.ledger_path} with the Read tool; ` +
        'page until complete, do not use remembered agent output or synthesize missing data.',
      'Return its complete parsed JSON object unmodified as ledger; never abbreviate, summarize or ' +
        'annotate any field. If the file is missing, invalid or partial, fail instead of guessing.',
    ].join('\n'), { phase: 'LedgerFileRead', model: 'sonnet', agentType: 'lean-reader',
      schema: { type: 'object', properties: { ledger: { type: 'object' } }, required: ['ledger'] },
    })
  } catch (error) {
    throw new Error(`ledger-read-failed: file read failed: ${error.message}`)
  }
  if (!ledgerRead) throw new Error(`ledger-read-failed: the reader returned nothing for ${collected.ledger_path}`)
  // Either transcription can be the wrong one, so the message blames neither.
  if (!sameData(ledgerRead.ledger, collected.ledger)) {
    throw new Error(`ledger-read-failed: Collect's copy and the reader's copy of ${collected.ledger_path} differ`)
  }
}
const files = (collected && collected.files) || []
const diffPath = collected.diff_path
const diffLineCount = collected.diff_line_count
const touchedDomains = matchDomains(files)
const prior = numericPr ? collected.ledger.rounds : []
if (numericPr && collected.ledger.ledger_errors.length) {
  log(`Ledger has ${collected.ledger.ledger_errors.length} error(s): ${JSON.stringify(collected.ledger.ledger_errors)}`)
}
log(
  `Collected ${files.length} changed file(s); touched domains: ` +
    (touchedDomains.length ? touchedDomains.join(', ') : '(none)') +
    `; diff at ${diffPath} (${diffLineCount} lines)`
)

// The latest trusted record, including a still-frozen overridden round, is
// admission authority. An unflagged stop writes no new completed record.
if (numericPr && prior.length && prior[prior.length - 1].record.streak >= 2 && !override) {
  if (prior.length > 32) log(`Round display capped at 32 of ${prior.length}; full history was used for admission`)
  const last = prior[prior.length - 1].record
  const table = roundTable(prior, null).slice(-32)
  const residual = last.residual_classes ||
    residualClasses(last.findings.map((f) => ({ ...f, refuted: false })))
  const frozen = typedStop(`frozen: PR ${collected.pr_number} round ${prior.length} has streak ` +
    `${last.streak}; continue_past_freeze not supplied`, {
    code: 'frozen', pr_repo: collected.pr_repo, pr_number: collected.pr_number, prior_round: prior.length,
    streak: last.streak, underlying_verdict: last.underlying_verdict, touched_domains: touchedDomains,
    table, residual_classes: residual, ledger_errors: collected.ledger.ledger_errors,
  })
  frozen.rounds = { enabled: true, frozen: true, table,
    ledger_errors: collected.ledger.ledger_errors, prior_round: prior.length, prior_record: last,
    residual_classes: residual }
  throw frozen
}

// Trust is per captured head, never inferred from the PR author alone. The
// frozen admission check runs first, so an unflagged frozen PR remains a typed
// admission stop rather than a new failed round.
if (numericPr && prior.length) {
  checkTrustedHead(collected, trustedHead, collected.pr_repo, Number(target))
}

const selection = numericPr && prior.length
  ? buildManifest(files, prior, collected.selection, collected.head_sha, collected.base_sha)
  : { manifest: [], selection_error: null }
const needsRed = numericPr && prior.length > 0

phase('Lenses')
// The shell, not the agent, writes report.json: RedFileRead's re-read then
// checks the agent's copy against the runner's real output, not against itself.
const redReportPath = `${collected.scratch_dir}/report.json`
const redErrPath = `${collected.scratch_dir}/red-first.err`
const redTask = () => agent(
  [
    'Mechanical RedFirst stage: do not judge evidence or synthesize a report.',
    `Use absolute target repository ${collected.repo_root} at captured head ${collected.head_sha}.`,
    `Use ONLY trusted driver directory ${collected.driver_dir}; do not execute target-checkout drivers.`,
    `Use exact scratch files ${shellQuote(collected.scratch_dir + '/manifest.json')}, ` +
      `${shellQuote(collected.scratch_dir + '/files.txt')}, ${shellQuote(redReportPath)} and ` +
      `${shellQuote(redErrPath)} (no other directory).`,
    'Write manifest_path and files_path with the Write tool, or a single-quoted heredoc when Write ' +
      'is refused for the path.',
    `Write exactly this manifest JSON and return manifest_path: ${JSON.stringify(selection.manifest)}.`,
    `Write the full captured PR-wide file list ${JSON.stringify(files)} to files_path, one path per line.`,
    'Then run this exact command ONCE, verbatim, as a single Bash call given the largest timeout its ' +
      'Bash tool schema accepts (1800000 ms where BASH_MAX_TIMEOUT_MS allows it, otherwise the stock ' +
      '600000 ms; red-first runs full suites twice), so the shell itself stores the output: ' +
      `bash ${shellQuote(collected.driver_dir + '/red-first.sh')} ${shellQuote(collected.repo_root)} ` +
      `--head ${shellQuote(collected.head_sha)} --base-branch ${shellQuote(collected.base_sha)} ` +
      `--manifest ${shellQuote(collected.scratch_dir + '/manifest.json')} ` +
      `--files ${shellQuote(collected.scratch_dir + '/files.txt')} > ${shellQuote(redReportPath)} ` +
      `2> ${shellQuote(redErrPath)}; echo "EXIT:$?"`,
    `${shellQuote(redReportPath)} is the runner's own stdout: NEVER create, edit or rewrite it with ` +
      'Write, Edit or a heredoc, and never retype or repair its content.',
    'Return the integer printed after EXIT: as exit_code. Then Read the ENTIRE ' +
      `${shellQuote(redReportPath)} with the Read tool (page until complete) and return its parsed ` +
      'JSON unmodified as report, with report_path. On a nonzero exit, Read ' +
      `${shellQuote(redErrPath)} and return the last lines of ${shellQuote(redErrPath)} that name the ` +
      'failure, verbatim, as diagnostic. A missing command, nonzero exit, malformed ' +
      'JSON, or unreadable output is a stage failure, not an agent-created P2 finding. Never silently ' +
      'omit any manifest path.',
  ].join('\n'),
  { phase: 'RedFirst', model: 'sonnet', schema: {
    type: 'object', properties: {
      manifest_path: { type: 'string' }, files_path: { type: 'string' },
      report_path: { type: 'string' }, exit_code: { type: 'integer' }, report: { type: 'object' },
      diagnostic: { type: 'string' },
    },
    required: ['manifest_path', 'files_path', 'report_path', 'exit_code', 'report'],
  } }
)
const lensTasks = LENSES.map((lens) => () =>
  agent(buildLensPrompt(lens, target, repo, diffPath, diffLineCount,
    numericPr ? collected.repo_root : null, numericPr ? collected.head_sha : null), {
    phase: 'Lenses', label: lens.label, schema: FINDINGS_SCHEMA,
  }).then((result) => ({
    lens: lens.id, findings: (result && result.findings) || [],
    diff_lines_read: result ? result.diff_lines_read : null,
    ordinary_prose: result?.ordinary_prose,
  }))
)
const stageResults = await parallel(needsRed && !selection.selection_error
  ? [redTask, ...lensTasks] : lensTasks)
const redStage = needsRed && !selection.selection_error ? stageResults[0] : null
const lensResults = (needsRed && !selection.selection_error ? stageResults.slice(1) : stageResults).filter(Boolean)
if (lensResults.length < LENSES.length) {
  log(`WARNING: only ${lensResults.length}/${LENSES.length} lenses returned; coverage will fail.`)
}

let fileRead = null
if (needsRed && !selection.selection_error) {
  // red-first.sh exits 0 whenever it emits a complete report; any other exit
  // is a usage, metadata or checkout failure, never evidence. The caller sees
  // only the message, so the runner's own stderr lines travel in it.
  if (Number.isInteger(redStage?.exit_code) && redStage.exit_code !== 0) {
    const diagnostic = typeof redStage.diagnostic === 'string' && redStage.diagnostic
      ? `: ${redStage.diagnostic.slice(0, 2000)}` : ''
    throw new Error(`red-first-stage-failed: red-first.sh exited ${redStage.exit_code}; ` +
      `diagnostics in ${redErrPath}${diagnostic}`)
  }
  if (!redStage || redStage.exit_code !== 0 || !['manifest_path', 'files_path', 'report_path'].every((key) =>
    isRoundScratch(redStage[key], collected.scratch_dir,
      { manifest_path: 'manifest.json', files_path: 'files.txt', report_path: 'report.json' }[key])) ||
      !redStage.report) {
    throw new Error('red-first-stage-failed: missing file-backed mechanical RED report')
  }
  phase('RedFileRead')
  try {
    fileRead = await agent([
      'Read the ENTIRE contents of each of these three existing files with the Read tool; ' +
        'page until complete, do not use remembered agent output or synthesize missing data.',
      `Manifest JSON: ${redStage.manifest_path}. Full newline-separated file list: ${redStage.files_path}. ` +
        `Report JSON: ${redStage.report_path}.`,
      'Return the complete parsed manifest array as manifest, the full list of paths as files ' +
        '(one item per nonempty line), and the complete parsed report object as report. ' +
        'If ANY file is missing, invalid or partial, fail instead of guessing.',
    ].join('\n'), { phase: 'RedFileRead', model: 'sonnet', agentType: 'lean-reader',
      schema: { type: 'object', properties: {
        manifest: { type: 'array', items: { type: 'object' } },
        files: { type: 'array', items: { type: 'string' } }, report: { type: 'object' },
      }, required: ['manifest', 'files', 'report'] },
    })
  } catch (error) {
    throw new Error(`red-first-stage-failed: file read failed: ${error.message}`)
  }
  if (!fileRead || !sameData(fileRead.manifest, selection.manifest) ||
      !sameData(fileRead.files, files) || !sameData(fileRead.report, redStage.report)) {
    throw new Error('red-first-stage-failed: on-disk RED inputs/output missing, partial or divergent')
  }
}

phase('Judge')
checkLensCoverage(lensResults, LENSES.map((lens) => lens.id), diffLineCount)
let report = null
if (needsRed) {
  if (selection.selection_error) {
    report = selectionUnverifiable(files, prior, collected.head_sha, collected.base_sha,
      selection.selection_error)
  } else {
    report = fileRead.report
    checkRedReport(report, selection.manifest, collected.head_sha, collected.base_sha)
  }
}
// Collect's machine blob facts are the only evidence a path is absent at head
// (an empty head entry); a selection error leaves none to trust.
const removedAtHead = new Set(needsRed && !selection.selection_error
  ? collected.selection.blob_facts.filter((f) => f.head_blob === '').map((f) => f.path) : [])
const redFindings = report
  ? [...redFirstFindings(report), ...carriedNeverRed(prior, report, files, removedAtHead)] : []
const redFirst = composeRedFirst(report, redFindings, needsRed)
const lensJudged = judgeFindings(lensResults, touchedDomains)
const findings = numericPr ? mergeRedFindings(lensJudged.findings, redFindings) : lensJudged.findings
const underlying = numericPr ? computeVerdict(findings) : lensJudged.verdict
if (!numericPr) {
  const judged = { ...lensJudged, rounds: { enabled: false, reason: 'target is not a PR' } }
  log(`Verdict: ${judged.verdict} -- ${judged.findings.length} deduped finding(s) across ` +
    `${lensResults.length}/${LENSES.length} lens(es)`)
  return judged
}
const { record, score } = composeRecord(prior, collected, findings, underlying, redFirst, override,
  touchedDomains, lensResults)
const recordPath = `${collected.scratch_dir}/round.json`
let recordWritten = false
// pending_mismatch: true = this workflow compared the pending file read back
// with the composed record and they differ; false = compared and equal since
// the last Record agent, which can write the file, ran; null = not compared
// since then. The Record agent's own write_confirmed sets recordWritten but
// is not that comparison (a confirmed append without a readback stops for the
// same reason), so it leaves null. The default is evaluated per call.
let pendingCompared = false
// A reason can quote an agent's error message; bounding it keeps the summary's
// recovery paths and every routing field within typedStop's limits.
const recordFailure = (rawReason, pendingMismatch = pendingCompared ? false : null) => {
  const reason = clipText(rawReason, 1000)
  const state = recordWritten ? `record write confirmed at ${recordPath}` :
    `record location ${recordPath} (existence unconfirmed)`
  return typedStop(`ledger-write-failed: ${reason}; ${state}; captured ledger ${collected.ledger_path}`, {
    code: 'ledger-write-failed', reason, record_path: recordPath, ledger_path: collected.ledger_path,
    driver_dir: collected.driver_dir, pr_repo: collected.pr_repo, pr_number: collected.pr_number,
    record_written: recordWritten, pending_mismatch: pendingMismatch, verdict: record.verdict,
    underlying_verdict: underlying, touched_domains: touchedDomains,
  }, {
    record_path: recordPath, ledger_path: collected.ledger_path, driver_dir: collected.driver_dir,
    pr_repo: collected.pr_repo, pr_number: collected.pr_number, record_written: recordWritten,
  })
}
let confirmed = false
for (let attempt = 1; attempt <= 3 && !confirmed; attempt++) {
  // An earlier comparison says nothing about the file after this attempt's
  // Record agent had write access to it (verify lens at 82cab14f).
  pendingCompared = false
  phase('Record')
  let written = null
  let postError = null
  try {
    written = await agent([
      `Mechanical Record posting attempt ${attempt}/3. No judging, readback or recomputation.`,
      `Use Write (or a single-quoted heredoc when Write is refused for the path) to put EXACTLY ` +
        `the following JSON at ${recordPath} on the first attempt; ` +
        'on retry Read that SAME file and refuse to modify it if it differs. ' +
        'Return write_confirmed=true ONLY after verifying the full file content:',
      JSON.stringify(record),
      'Run this exact command ONCE, verbatim with its absolute path, as one shell command: ' +
        `python3 ${shellQuote(collected.driver_dir + '/review-rounds.py')} record ` +
        `--repo ${shellQuote(collected.pr_repo)} --pr ${collected.pr_number} ` +
        `--record ${shellQuote(recordPath)}; echo "EXIT:$?"`,
      'Silent output with EXIT:0 means it posted. Never run it a second time for any reason ' +
        '(posting is not idempotent; the script refuses a repeat and a lost response may already ' +
        'have appended). Return the real post_ok/post_error from that single run.',
      'Return the exact record_path, write_confirmed, post_ok and diagnostic on failure.',
    ].join('\n'), {
      phase: 'Record', model: 'sonnet', schema: {
        type: 'object', properties: {
          record_path: { type: 'string' }, write_confirmed: { type: 'boolean' },
          post_ok: { type: 'boolean' }, post_error: { type: 'string' },
        }, required: ['record_path', 'write_confirmed', 'post_ok'],
      },
    })
    if (written?.record_path === recordPath && written.write_confirmed === true) recordWritten = true
  } catch (error) {
    postError = error
  }
  // A different Bash-capable agent re-reads U1 after EVERY posting outcome,
  // including a thrown or ambiguous post. A failed read never authorizes retry.
  phase('Readback')
  let readback
  try {
    readback = await agent([
      `Run python3 ${shellQuote(collected.driver_dir + '/review-rounds.py')} confirm ` +
        `--repo ${shellQuote(collected.pr_repo)} --pr ${collected.pr_number} ` +
        `--ledger ${shellQuote(collected.ledger_path)} --record ${shellQuote(recordPath)}.`,
      'Return its printed JSON object unchanged as confirmation; fail on any CLI or parse ' +
        'failure (a missing pending file is a CLI failure). Separately Read the full pending file ' +
        `at ${recordPath} and return its parsed JSON as record_on_disk; omit record_on_disk if ` +
        'missing/unreadable. Do not infer posting success from the file.',
    ].join('\n'), { phase: 'Readback', model: 'sonnet', schema: {
      type: 'object', properties: { confirmation: { type: 'object' }, record_on_disk: { type: 'object' } },
      required: ['confirmation'],
    } })
  } catch (error) {
    throw recordFailure(`trusted readback failed after attempt ${attempt}: ${error.message}`)
  }
  if (!readback?.confirmation) throw recordFailure(`trusted readback unavailable after attempt ${attempt}`)
  try {
    confirmed = confirmOutcome(readback.confirmation, record, prior.length)
  } catch (error) {
    throw recordFailure(error.message)
  }
  // U1 compared the posted round with the pending file; an exact file match
  // with the composed record completes the confirmation.
  if (readback.record_on_disk !== undefined) {
    if (!sameData(readback.record_on_disk, record)) {
      throw recordFailure(`pending file differs from immutable record after attempt ${attempt}`, true)
    }
    recordWritten = true
    pendingCompared = true
  } else if (confirmed) {
    throw recordFailure(`round ${record.round} appended per compact readback, but the pending ` +
      'record file was not read back for exact comparison')
  }
  if (confirmed) break
  // A reported success that readback cannot yet see may still appear later;
  // reposting it would append a duplicate round.
  if (written?.post_ok === true) throw recordFailure('post reported success but exact readback is absent')
  if (postError) log(`Record posting attempt ${attempt} failed ambiguously: ${postError.message}; readback unchanged`)
  // U1 posts whatever the pending file holds, so another post needs this
  // attempt's own equal comparison; the Record agent's write_confirmed is not
  // one (Pro gate at e96e1eee).
  if (!pendingCompared) {
    throw recordFailure(`pending record file not compared after attempt ${attempt}; not reposting`)
  }
  if (!recordWritten || (written && (written.record_path !== recordPath ||
      typeof written.post_ok !== 'boolean' || (!written.post_ok && !written.post_error)))) {
    throw recordFailure(`posting outcome or record file unconfirmed after attempt ${attempt}`)
  }
}
if (!confirmed) throw recordFailure('three posting attempts exhausted with unchanged trusted history')
// Do not delete the immutable recovery record until the trusted ledger has
// echoed it exactly. A cleanup failure must not turn a posted round into an
// unrecorded failure that a retry might post twice.
const scratchPaths = [collected.ledger_path, ...(redStage
  ? [redStage.manifest_path, redStage.files_path, redStage.report_path, redErrPath] : []), recordPath]
let cleanupPending = scratchPaths
phase('Cleanup')
try {
  const cleanup = await agent([
    'Mechanical cleanup after confirmed ledger readback. Do not post, rerun, or change evidence.',
    `Only unlink these exact scratch files (no glob, no recursive deletion): ${JSON.stringify(scratchPaths)}.`,
    'Leave directories and unexpected file types alone. Check each path is absent afterward, ' +
      'and return pending as the subset still present; name any errors.',
  ].join('\n'), {
    phase: 'Cleanup', model: 'sonnet', schema: {
      type: 'object', properties: {
        pending: { type: 'array', items: { type: 'string' } },
        errors: { type: 'array', items: { type: 'string' } },
      }, required: ['pending'],
    },
  })
  if (Array.isArray(cleanup?.pending) &&
      cleanup.pending.every((path) => scratchPaths.includes(path)) &&
      new Set(cleanup.pending).size === cleanup.pending.length) {
    cleanupPending = cleanup.pending
    if (cleanup.errors?.length) log(`WARNING: round scratch cleanup: ${cleanup.errors.join('; ')}`)
  } else {
    log('WARNING: round scratch cleanup returned an invalid inventory')
  }
} catch (error) {
  log(`WARNING: round scratch cleanup failed: ${error.message}`)
}
if (cleanupPending.length) log(`WARNING: round scratch remains: ${JSON.stringify(cleanupPending)}`)
const table = roundTable(prior, record)
if (table.length > 32) log(`Round display capped at 32 of ${table.length}; full history was used for decisions`)
const rounds = {
  enabled: true, round: record.round, streak: score.streak, frozen: score.frozen,
  override, rerun: score.rerun, table: table.slice(-32),
  residual_classes: score.residual_classes, red_first: redFirst,
  ledger_errors: collected.ledger.ledger_errors, record_path: recordPath,
  ledger_path: collected.ledger_path, driver_dir: collected.driver_dir,
  scratch_cleanup_pending: cleanupPending,
}
log(`Verdict: ${record.verdict} -- ${findings.length} deduped finding(s) across ` +
  `${lensResults.length}/${LENSES.length} lens(es); round ${record.round} read back`)
return { verdict: record.verdict, underlying_verdict: underlying, findings,
  touched_domains: touchedDomains, rounds }
