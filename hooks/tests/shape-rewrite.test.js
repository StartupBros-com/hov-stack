'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { runHook, assertQuietPassThrough, mkTmp, rmTmp } = require('./lib/harness');
const { measureCpu } = require('./lib/timing');
const { assertPerfScaling } = require('./lib/perf-guard');
const { projectSlug } = require('../PostToolUseFailure/papercut-log.js');
const {
  run, detectShapes, reaches, stripWrappers,
  isUnbundledFlagCluster, isWordChar, isAlphaChar, reachWords,
} = require('../PreToolUse/shape-rewrite.js');
const { wordLiteralText } = require('../lib/shape-rewrite-reach.js');

const HOOK = 'PreToolUse/shape-rewrite.js';
const DOC = path.resolve(__dirname, '..', '..', 'harness', 'worktree-command-shapes.md');

// ---------------------------------------------------------------------------
// Fixtures: a fake worktree, so KTD3's cwd-proxy check finds a real segment.
// ---------------------------------------------------------------------------

function mkWorktree() {
  const root = mkTmp('shape-rw-repo-');
  const wt = path.join(root, '.claude', 'worktrees', 'demo-hook');
  fs.mkdirSync(wt, { recursive: true });
  return { root, wt };
}

function payload(command, over = {}) {
  return {
    hook_event_name: 'PreToolUse',
    tool_name: 'Bash',
    tool_input: { command },
    session_id: 'sess-0000-abcd1234',
    tool_use_id: 'toolu_01abc',
    ...over,
  };
}

// ===========================================================================
// U1: detectShapes — one shape per verifier-refused row (doc-parity: every
// example is taken verbatim from harness/worktree-command-shapes.md).
// ===========================================================================

test('detectShapes: command substitution in argument position is "cmdsub"', () => {
  assert.deepStrictEqual(detectShapes('echo $(echo p5)'), ['cmdsub']);
  assert.deepStrictEqual(detectShapes('echo $(date)'), ['cmdsub']);
});

test('detectShapes: backticks are "cmdsub" too', () => {
  assert.deepStrictEqual(detectShapes('echo `echo p24`'), ['cmdsub']);
});

test('detectShapes: a command-substitution used as an assignment VALUE is not "cmdsub" (PASS row)', () => {
  // Doc: "assignment values are not analyzed... discriminator is position, not
  // the variable's name or the inner command."
  assert.deepStrictEqual(detectShapes('V=$(date) printenv V'), []);
  assert.deepStrictEqual(detectShapes('P=$(pwd) printenv P'), []);
});

test('detectShapes: an assignment whose command-substitution VALUE is glued (shellTokens splits "FOO=" from the payload) still lets the following pkgmgr shape through (finding #9)', () => {
  // shellTokens() splits `FOO=$(date)` into the literal item "FOO=" and a
  // separate, non-literal command-substitution item. stripWrapperPrefix
  // must advance past both -- advancing past only "FOO=" re-reads the
  // substitution item as an unresolvable head and stops the strip one item
  // early, hiding the pkgmgr shape below it. Per the PASS row above, the
  // assignment's own value is not itself "cmdsub" (position, not the
  // presence of a substitution, is the discriminator), so this is
  // ['pkgmgr'] only, not ['cmdsub', 'pkgmgr'].
  assert.deepStrictEqual(detectShapes('FOO=$(date) pnpm --filter x lint'), ['pkgmgr']);
});

test('detectShapes: a standalone assignment statement whose VALUE is a command substitution is "cmdsub" (the variable is read in a later segment)', () => {
  // Discriminator vs. the PASS row above: nothing else follows the
  // assignment in THIS simple command (it ends at ;/&&/||/newline/EOF) --
  // the assignment IS the whole statement, not a value prefix consumed by
  // another command in the same segment.
  assert.deepStrictEqual(detectShapes('SCRATCH=$(mktemp -d /tmp/x); echo "$SCRATCH"'), ['cmdsub']);
  assert.deepStrictEqual(detectShapes('tip=$(git rev-parse HEAD); echo "$tip"'), ['cmdsub']);
  assert.deepStrictEqual(detectShapes('WT=$(git rev-parse --show-toplevel); echo "$WT"'), ['cmdsub']);
  assert.deepStrictEqual(detectShapes('SCRATCH=$(mktemp -d /tmp/x)'), ['cmdsub']);
  assert.deepStrictEqual(detectShapes('A=1 B=$(date); echo "$B"'), ['cmdsub']);
});

test('detectShapes: an env-assignment PREFIX to a real command in the same segment is still PASS, not "cmdsub" (planted negative, unchanged from the PASS row)', () => {
  assert.deepStrictEqual(detectShapes('V=$(date) printenv V'), []);
  assert.deepStrictEqual(detectShapes('FOO=$(date) pnpm --filter x lint'), ['pkgmgr']);
});

test('detectShapes: a parameter-expansion modifier is "varmod"', () => {
  assert.deepStrictEqual(detectShapes('echo ${HOME:-x}'), ['varmod']);
});

test('detectShapes: a bare ${VAR} with no modifier is not "varmod"', () => {
  assert.deepStrictEqual(detectShapes('echo ${HOME}'), []);
});

test('detectShapes: an unquoted-delimiter heredoc is "heredoc"', () => {
  assert.deepStrictEqual(detectShapes('cat <<EOF\nhello\nEOF'), ['heredoc']);
});

test('detectShapes: a quoted-delimiter heredoc is not "heredoc" (expansion is suppressed)', () => {
  assert.deepStrictEqual(detectShapes("cat <<'EOF'\nhello $(date)\nEOF"), []);
});

// CC's own worktree-isolation verifier refuses a QUOTED-delimiter heredoc
// whose body has a double quote nested inside curly braces as "too complex
// to verify". This is a work-around predicate, not a judgment derived from
// Claude Code source: the trigger shape is inferred from live probes,
// reproduced on Claude Code 2.1.280 on 2026-09-23 (`cat <<'EOF'` with body
// `{"a": 1}` refused, `{a: 1}` allowed), filed upstream as
// anthropics/claude-code#96253, with the shapes-table row proposed in
// dotfiles PR #1338 (open when this was written); whichever of #1338 and
// #1348 lands second updates that row. The match scope is any double
// quote at brace depth > 0 -- a JSON object body (`{"a": 1}`) is the
// common case, but a parameter-expansion default like `${VAR:-"x"}` and a
// brace group like `{ echo "hi"; }` inside a quoted heredoc are both
// refused by the verifier too, confirmed empirically, so this breadth is
// deliberate: narrowing to JSON-shaped bodies would be a regression. This
// is the missing detectShapes() trigger for the already-safe case (quoting
// suppresses expansion, and the reach logic already lets a heredoc like
// this feeding cat/tee/OUTPUT_ONLY_COMMANDS pass).
test('detectShapes: a quoted-delimiter heredoc with a double quote nested inside {} is "heredoc" (CC verifier refuses this despite the quoted delimiter -- reproduced live on 2.1.280, anthropics/claude-code#96253)', () => {
  assert.deepStrictEqual(detectShapes('cat <<\'EOF\'\n{"a": 1}\nEOF'), ['heredoc']);
});

// The match scope is any double quote at brace depth > 0, not JSON
// specifically -- a shell brace group containing a quoted string trips the
// same verifier refusal, confirmed empirically alongside the JSON case.
test('detectShapes: a quoted-delimiter heredoc with a non-JSON brace group containing a double quote is also "heredoc"', () => {
  assert.deepStrictEqual(detectShapes('cat <<\'EOF\'\n{ echo "hi"; }\nEOF'), ['heredoc']);
});

// Planted negative: a body with `{`/`}` but no `"` nested inside them (the
// existing line-103-style shape) must stay pass-through -- a predicate that
// flags every quoted heredoc, rather than specifically dquote-in-curly,
// would rewrite traffic that already passes today for no reason.
test('detectShapes: a quoted-delimiter heredoc body with {} but no double quote nested inside stays pass-through (planted negative)', () => {
  assert.deepStrictEqual(detectShapes("cat <<'EOF'\n{a: 1}\nEOF"), []);
});

// heredocBodyHasQuoteInBraces is depth-tracking, not a flat
// `body.includes('{') && body.includes('"')` check -- every case above
// pairs `{"a": 1}` against `{a: 1}`, so a naive both-present check would
// pass that suite unnoticed. These cases separate the two: a `"` outside
// the curly span (before it opens, or after it has closed) must NOT
// trigger, and nesting/multi-line bodies must still trigger.
test('detectShapes: heredocBodyHasQuoteInBraces tracks nesting depth, not just character presence', () => {
  // `"` sits inside {}/`}`-closed text, but at depth 0 by the time it's
  // reached (the braces close before the quote appears).
  assert.deepStrictEqual(detectShapes('cat <<\'EOF\'\n{a: 1} "unrelated"\nEOF'), []);
  // `"` sits before the curly span ever opens.
  assert.deepStrictEqual(detectShapes('cat <<\'EOF\'\n"unrelated" {a: 1}\nEOF'), []);
  // A stray `}` clamps depth back to 0 before the `"`, and the `{` that
  // follows the quote never nests it either -- depth is 0 at the `"`.
  assert.deepStrictEqual(detectShapes('cat <<\'EOF\'\n}"{\nEOF'), []);
  // The base nested case, restated here alongside its negatives.
  assert.deepStrictEqual(detectShapes('cat <<\'EOF\'\n{"a": 1}\nEOF'), ['heredoc']);
  // An extra level of nesting around the same quoted-in-curly span.
  assert.deepStrictEqual(detectShapes('cat <<\'EOF\'\n{ x: {"a": 1} }\nEOF'), ['heredoc']);
  // A multi-line JSON body -- the loop runs over the whole body string,
  // not line-by-line.
  assert.deepStrictEqual(detectShapes('cat <<\'EOF\'\n{\n  "a": 1\n}\nEOF'), ['heredoc']);
});

// #1365: the verifier refuses a single quote inside {} exactly as it does a
// double quote (live probes on CC 2.1.280, 2026-09-23: `{'a': 1}` refused,
// `{a: 1}` and `'a' {b}` allowed), and Python dict literals are the common
// source. Every double-quote case above must classify identically once its
// double quotes become single quotes, the negatives included.
test('detectShapes: a single quote inside {} classifies exactly like a double quote (#1365)', () => {
  const heredoc = (body) => `cat <<'EOF'\n${body}\nEOF`;
  const bodies = [
    ['{"a": 1}', ['heredoc']],
    ['{ echo "hi"; }', ['heredoc']],
    ['{ x: {"a": 1} }', ['heredoc']],
    ['{\n  "a": 1\n}', ['heredoc']],
    ['{a: 1} "unrelated"', []],
    ['"unrelated" {a: 1}', []],
    ['}"{', []],
  ];
  for (const [body, expected] of bodies) {
    assert.deepStrictEqual(detectShapes(heredoc(body)), expected, `precondition: ${JSON.stringify(body)}`);
    const single = body.replaceAll('"', "'");
    assert.deepStrictEqual(detectShapes(heredoc(single)), expected, JSON.stringify(single));
  }
});

// #1365's residual: the verifier's second quoted-heredoc trigger ignores the
// body. Each row is a live probe on CC 2.1.280, 2026-09-23, plain body
// `hello`: refused rows are "heredoc", rows that ran stay pass-through.
test('detectShapes: a redirect before << in a command entered through && or || is "heredoc", matching the live probes (#1365)', () => {
  const refused = [
    "mkdir -p /tmp/d && cat > /tmp/d/a.txt <<'EOF'\nhello\nEOF",
    "true && cat > /tmp/f.txt <<'EOF'\nhello\nEOF",
    "false || cat > /tmp/f.txt <<'EOF'\nhello\nEOF",
    "true && cat 2>/dev/null <<'EOF'\nhello\nEOF",
    "true &&\ncat > /tmp/f.txt <<'EOF'\nhello\nEOF",
    "true && cat >| /tmp/f.txt <<'EOF'\nhello\nEOF",
    "true && cat >> /tmp/f.txt <<'EOF'\nhello\nEOF",
    "true && cat 2>&1 <<'EOF'\nhello\nEOF",
    "true && cat < /dev/null <<'EOF'\nhello\nEOF",
    "true && cat &>/tmp/f.txt <<'EOF'\nhello\nEOF",
  ];
  const ran = [
    "true && cat <<'EOF'\nhello\nEOF",
    "true && cat <<'EOF' > /tmp/f.txt\nhello\nEOF",
    "true && tee /tmp/f.txt <<'EOF'\nhello\nEOF",
    "mkdir -p /tmp/d && cat <<'EOF'\nhello\nEOF",
    "echo hi; cat > /tmp/f.txt <<'EOF'\nhello\nEOF",
    "cat > /tmp/f.txt <<'EOF'\nhello\nEOF",
    "cat > /tmp/f.txt << 'EOF'\nhello\nEOF",
    "cat <<'EOF' | wc -l\nhello\nEOF",
    "false || cat <<'EOF'\nhello\nEOF",
    "cat > /tmp/f.txt <<'EOF'\nhello\nEOF\necho done",
    "true\ncat > /tmp/f.txt <<'EOF'\nhello\nEOF",
    "cat >| /tmp/f.txt <<'EOF'\nhello\nEOF",
    "echo hi > /tmp/x.txt && cat <<'EOF'\nhello\nEOF",
    "true && echo '>' <<'EOF'\nhello\nEOF",
    "true && printf '%s\\n' '>' '<<'",
  ];
  for (const cmd of refused) assert.deepStrictEqual(detectShapes(cmd), ['heredoc'], JSON.stringify(cmd));
  for (const cmd of ran) assert.deepStrictEqual(detectShapes(cmd), [], JSON.stringify(cmd));
});

// Not probed, so these are pinned to the implementation's reading: `<<-`, a
// double-quoted delimiter, and the redirects `<&`, `&>>`, and `<>` take the
// same path as the probed rows, and a `<<<` here-string is no heredoc.
test('detectShapes: the && redirect trigger covers <<-, "EOF", <&, &>>, and <>, and ignores a <<< here-string (#1365)', () => {
  assert.deepStrictEqual(detectShapes("true && cat >> /tmp/f.txt <<-'EOF'\n\thello\n\tEOF"), ['heredoc']);
  assert.deepStrictEqual(detectShapes('true && cat > /tmp/f.txt <<"EOF"\nhello\nEOF'), ['heredoc']);
  assert.deepStrictEqual(detectShapes("true && cat 0<&0 <<'EOF'\nhello\nEOF"), ['heredoc']);
  assert.deepStrictEqual(detectShapes("true && cat &>>/tmp/f.txt <<'EOF'\nhello\nEOF"), ['heredoc']);
  assert.deepStrictEqual(detectShapes("true && cat <>/tmp/f.txt <<'EOF'\nhello\nEOF"), ['heredoc']);
  assert.deepStrictEqual(detectShapes('true && cat > /tmp/f.txt <<< "hello"'), []);
});

// #1370 review: the redirect and the heredoc must be real operators. A
// quoted `'>'` or `'<<'` is an argument; rewriting such a command changed
// `$0` for a command the verifier runs (probed: `true && echo '>' <<'EOF'`
// and `true && printf '%s\n' '>' '<<'` both run).
test('detectShapes: quoted operator text after && is an argument, not a redirect or heredoc (#1370)', () => {
  assert.deepStrictEqual(detectShapes("true && printf '%s\\n' \"$0\" '>' '<<'"), []);
  assert.deepStrictEqual(detectShapes("true && echo \">\" <<'EOF'\nhello\nEOF"), []);
  assert.deepStrictEqual(detectShapes("true && echo \\> <<'EOF'\nhello\nEOF"), []);
  assert.deepStrictEqual(detectShapes("true && echo 'a >' '<<' <<'EOF'\nhello\nEOF"), []);
  // A `<<` with no delimiter is no heredoc for findHeredocs(), so none here.
  assert.deepStrictEqual(detectShapes('true && cat > /tmp/f.txt <<'), []);
});

// An unpaired apostrophe in a quoted body is data, not an open quote: it must
// not swallow the terminator or the next command.
test('detectShapes: an unpaired apostrophe inside {} is "heredoc" and the command after the terminator is still parsed (#1365)', () => {
  assert.deepStrictEqual(detectShapes("cat <<'EOF'\n{\"msg\": \"it's\"}\nEOF"), ['heredoc']);
  assert.deepStrictEqual(detectShapes("cat <<'EOF'\n{it's}\nEOF\necho $(date)"), ['cmdsub', 'heredoc']);
  assert.deepStrictEqual(detectShapes("cat <<'EOF'\nit's {fine}\nEOF"), []);
});

test('detectShapes: an interpreter fed by a QUOTED-delimiter heredoc on bare "-", with no other program-bearing argument, is "interp" (interp family)', () => {
  assert.deepStrictEqual(detectShapes("python3 - <<'EOF'\nprint(1)\nEOF"), ['interp']);
  assert.deepStrictEqual(detectShapes("python - <<'TAG'\nprint(1)\nTAG"), ['interp']);
  assert.deepStrictEqual(detectShapes("node - <<'EOF'\nconsole.log(1)\nEOF"), ['interp']);
  assert.deepStrictEqual(detectShapes("perl - <<'EOF'\nprint 1;\nEOF"), ['interp']);
  assert.deepStrictEqual(detectShapes("ruby - <<'EOF'\nputs 1\nEOF"), ['interp']);
});

test('detectShapes: an UNQUOTED delimiter stays "heredoc", not "interp" (planted negative -- it still expands $(...) in its body)', () => {
  assert.deepStrictEqual(detectShapes('python3 - <<EOF\nprint(1)\nEOF'), ['heredoc']);
});

test('detectShapes: python3 -c with a quoted inline program is not "interp" (planted negative -- a program-bearing flag, no heredoc at all)', () => {
  assert.deepStrictEqual(detectShapes('python3 -c "import os"'), []);
});

test('detectShapes: an interpreter running a script FILE fed by a quoted heredoc is not "interp" (planted negative -- the heredoc is not its program source)', () => {
  assert.deepStrictEqual(detectShapes("python3 script.py <<'EOF'\nignored\nEOF"), []);
});

test('detectShapes: a cd/git-prefixed chain still reports "interp" for the shape itself (planted negative belongs to the REACH check below, not detection -- detectShapes is shape-only and does not evaluate other segments)', () => {
  assert.deepStrictEqual(detectShapes("cd /home/user/dotfiles && python3 - <<'EOF'\nprint(1)\nEOF"), ['interp']);
  assert.deepStrictEqual(detectShapes("git status && python3 - <<'EOF'\nprint(1)\nEOF"), ['interp']);
});

test('detectShapes: a for-loop that uses its own loop variable is "loopvar"', () => {
  assert.deepStrictEqual(detectShapes('for i in 1 2; do echo p9-$i; done'), ['loopvar']);
});

test('detectShapes: a for-loop that never references its loop variable is not "loopvar"', () => {
  assert.deepStrictEqual(detectShapes('for i in 1 2; do echo static; done'), []);
});

test('detectShapes: a list item that contains "do"/"done" as a substring (e.g. "undone") does not defeat the do/done boundary search (finding #10)', () => {
  assert.deepStrictEqual(detectShapes('for x in undone abc; do echo $x; done'), ['loopvar']);
});

test('detectShapes: package-manager script shorthand/run/flags/exec forms are "pkgmgr" (using a script NOT owned by heavy-job-admission)', () => {
  // typecheck/build/tsc examples are heavy-job-admission's own targets (AE11,
  // asserted separately below) and correctly yield no shape here; "lint"/
  // "eslint" are not in heavy-job-admission's HEAVY_SCRIPTS set, so they
  // isolate the pkgmgr-shape detection itself from the heavy exclusion.
  assert.deepStrictEqual(detectShapes('pnpm lint'), ['pkgmgr']);
  assert.deepStrictEqual(detectShapes('pnpm run lint'), ['pkgmgr']);
  assert.deepStrictEqual(detectShapes('pnpm --filter startupbros lint'), ['pkgmgr']);
  assert.deepStrictEqual(detectShapes('pnpm exec eslint --version'), ['pkgmgr']);
  assert.deepStrictEqual(detectShapes('npx eslint --version'), ['pkgmgr']);
});

test('detectShapes: a with-value flag whose value is a command substitution does not throw off the trailing bare-subcommand count (finding #12)', () => {
  // pkgmgrShape's final branch compared `words.length` (only the STRING
  // tokens, counted across the WHOLE token stream) against `i` (a position
  // index into the mixed string/object `tokens` array) -- any
  // command-substitution token anywhere in the stream shifts that count off
  // by one, hiding a real trailing bare subcommand like "lint" here.
  assert.deepStrictEqual(detectShapes('pnpm --filter $(echo pkgname) lint'), ['cmdsub', 'pkgmgr']);
});

test('detectShapes: package-manager flags-only invocations are PASS, not "pkgmgr"', () => {
  assert.deepStrictEqual(detectShapes('pnpm --version'), []);
  assert.deepStrictEqual(detectShapes('pnpm --filter startupbros --version'), []);
  assert.deepStrictEqual(detectShapes('npx --version'), []);
  assert.deepStrictEqual(detectShapes('node --version'), []);
});

test('detectShapes: a package-manager operand used as plain text argument is PASS (echo --filter startupbros)', () => {
  assert.deepStrictEqual(detectShapes('echo --filter startupbros'), []);
});

test('detectShapes: a package-manager operand passed to a script (not as the command) is PASS', () => {
  assert.deepStrictEqual(detectShapes('/abs/path/count-rows.py pnpm typecheck'), []);
});

test('detectShapes: AE11 heavy-job-admission targets are excluded even though they parse as pkgmgr', () => {
  // Cross-file regression: heavy-job-admission already owns "pnpm build"/"pnpm test"-class
  // heavy commands; shape-rewrite must not also claim them (single-owner discipline).
  const { analyzeCommand } = require('../PreToolUse/heavy-job-admission.js');
  const heavyCandidates = ['pnpm build', 'pnpm test', 'pnpm run build'];
  for (const cmd of heavyCandidates) {
    if (analyzeCommand(cmd).heavy) {
      assert.deepStrictEqual(detectShapes(cmd), [], `expected ${JSON.stringify(cmd)} to be excluded as heavy`);
    }
  }
});

test('detectShapes: a trailing & disqualifies the whole call', () => {
  assert.deepStrictEqual(detectShapes('echo $(date) &'), []);
  assert.deepStrictEqual(detectShapes('pnpm typecheck &'), []);
});

test('detectShapes: a wrapper prefix (sudo/env/timeout/assignment) does not hide a shape', () => {
  assert.deepStrictEqual(detectShapes('sudo pnpm lint'), ['pkgmgr']);
  assert.deepStrictEqual(detectShapes('timeout 30 pnpm exec eslint'), ['pkgmgr']);
  assert.deepStrictEqual(detectShapes('env FOO=1 npx eslint'), ['pkgmgr']);
  assert.deepStrictEqual(detectShapes('FOO=1 pnpm lint'), ['pkgmgr']);
});

test('detectShapes: multiple shapes compound into one sorted, +-joined name', () => {
  assert.deepStrictEqual(detectShapes('for i in 1 2; do echo $i-$(date); done'), ['cmdsub', 'loopvar']);
});

test('detectShapes: AE10 a shell -c payload string is opaque text, no shape detected inside it', () => {
  assert.deepStrictEqual(detectShapes('bash -c "echo \\$(date)"'), []);
});

test('detectShapes: gh with JSON flags is PASS, not a shape (quoted content is opaque)', () => {
  assert.deepStrictEqual(detectShapes('gh pr view 1 --json number,title'), []);
});

test('detectShapes: staging/committing rows are PASS (no shape) on their own', () => {
  assert.deepStrictEqual(detectShapes('git add file.txt'), []);
  assert.deepStrictEqual(detectShapes('git commit -m "msg"'), []);
});

test('detectShapes: running a script by absolute path never triggers a shape from its internal $()', () => {
  assert.deepStrictEqual(detectShapes('/abs/path/count-rows.py'), []);
});

test('detectShapes: combined redirect to tmp scratch is PASS on its own (no refused shape)', () => {
  assert.deepStrictEqual(detectShapes('echo hi > /tmp/x.txt 2>&1'), []);
});

/** Pulls every inline-code span (`` `x` `` or double-backtick `` `` x `` ``) out of one markdown cell. */
function codeSpans(text) {
  const spans = [];
  const dbl = /``\s?([\s\S]*?)\s?``/g;
  let m;
  while ((m = dbl.exec(text))) spans.push(m[1]);
  const withoutDbl = text.replace(dbl, ' ');
  const single = /`([^`]+)`/g;
  while ((m = single.exec(withoutDbl))) spans.push(m[1]);
  return spans;
}

test('detectShapes: doc parity — every DENY example in worktree-command-shapes.md yields a non-empty shape or is a documented heavy-exclusion', () => {
  const doc = fs.readFileSync(DOC, 'utf8');
  const startMarker = '### DENY — "too complex to verify"';
  const start = doc.indexOf(startMarker);
  assert.ok(start !== -1, 'doc section header not found; has the doc moved?');
  const rest = doc.slice(start + startMarker.length);
  const end = rest.indexOf('\n### ');
  const section = end === -1 ? rest : rest.slice(0, end);
  const rows = section.split('\n').filter((l) => l.startsWith('|') && !l.startsWith('|---'));
  const examples = [];
  for (const row of rows) {
    const cells = row.split('|').map((c) => c.trim()).filter(Boolean);
    if (cells.length < 2 || cells[0] === 'Shape') continue;
    const spans = codeSpans(cells[1]);
    if (spans.length) examples.push(spans[0]); // the first span is always the probe command itself
  }
  assert.ok(examples.length >= 6, `expected to find several DENY examples in the doc, found ${examples.length}: ${JSON.stringify(examples)}`);
  const { analyzeCommand } = require('../PreToolUse/heavy-job-admission.js');
  // Known, documented gap in the extraction (not a detectShapes miss): the
  // doc row for a heredoc whose body has a quote inside `{}`
  // (anthropics/claude-code#96253) can only put the opener `cat <<'EOF'` in a
  // table cell, never the multi-line body. Since #1348 a quoted-delimiter
  // heredoc is flagged only by its BODY, so the body-less opener extracted
  // here can never trip detectShapes; the full shape is pinned by #1348's
  // detection tests in this file. This is the one documented example this
  // doc-parity check must not flag as silent.
  const KNOWN_UNDETECTED = new Set(["cat <<'EOF'"]);
  for (const cmd of examples) {
    if (KNOWN_UNDETECTED.has(cmd)) continue;
    let heavy = false;
    try { heavy = Boolean(analyzeCommand(cmd).heavy); } catch { heavy = false; }
    if (heavy) continue; // documented AE11 exclusion, not a detectShapes miss
    assert.notDeepStrictEqual(detectShapes(cmd), [], `doc DENY example produced no shape: ${JSON.stringify(cmd)}`);
  }
});

// ===========================================================================
// U1: reaches — the new "does this touch outside the roots" check.
// ===========================================================================

test('reaches: a plain command with no path arguments does not reach', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('echo $(date)', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: a substitution feeding a path-capable command\'s argument is unresolvable; the same feeding an output-only command is not (R4)', () => {
  const { root } = mkWorktree();
  try {
    // The payload recursion validates `cat list.txt` itself, never what it prints.
    assert.ok(reaches('cp $(cat list.txt) dest', [root]));
    assert.ok(reaches('cat $(basename x)', [root]));
    assert.strictEqual(reaches('echo $(date)', [root]), null);
    assert.strictEqual(reaches('printf %s $(basename x)', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: git is treated as reaching outright (AE9 sibling precedence)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('git commit -m "$(cat /home/user/dotfiles/CLAUDE.md)"', [root]));
  } finally { rmTmp(root); }
});

test('reaches: a wrapper option that takes a value cannot hide git from the reach check', () => {
  const { root } = mkWorktree();
  try {
    // The signal or kill-after VALUE is not the duration, and the duration is not the command.
    assert.ok(reaches('timeout -s TERM 30 git push origin main', [root]));
    assert.ok(reaches('timeout --signal TERM 30 git push', [root]));
    assert.ok(reaches('timeout -k 5s 30 git push', [root]));
    assert.ok(reaches('timeout --kill-after 5s 30 git push', [root]));
    assert.ok(reaches('sudo -u will git push', [root]));
    assert.ok(reaches('env -u GIT_DIR git push', [root]));
    assert.ok(reaches('env -C /tmp git push', [root]));
    assert.ok(reaches('nohup env -i timeout -s KILL 10 git fetch', [root]));
  } finally { rmTmp(root); }
});

test('reaches: an unrecognised wrapper option is uncertain and therefore reaches (fail closed)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('timeout -vs TERM 30 echo hi', [root]), 'combined short flags');
    assert.ok(reaches('sudo -n echo hi', [root]), 'sudo takes no options here');
    assert.ok(reaches('env -S "echo hi"', [root]), 'env -S is an opaque program');
    assert.ok(reaches('timeout 30 -s TERM echo hi', [root]), 'an option where the command name should be');
    assert.ok(reaches('timeout soon echo hi', [root]), 'a duration slot that is not a duration');
  } finally { rmTmp(root); }
});

test('reaches: known wrapper flags still strip cleanly, so a benign wrapped call is not over-refused', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('timeout --foreground 30 echo $(date)', [root]), null);
    assert.strictEqual(reaches('timeout -s TERM 30 echo $(date)', [root]), null);
    assert.strictEqual(reaches('timeout --kill-after=5s 30 echo $(date)', [root]), null);
    assert.strictEqual(reaches('env -i FOO=1 echo $(date)', [root]), null);
    assert.strictEqual(reaches('env -u FOO echo $(date)', [root]), null);
    assert.strictEqual(reaches('sudo echo $(date)', [root]), null);
    assert.strictEqual(reaches('FOO=1 nohup echo $(date)', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: a command name built from a bare/glued variable reference is an unresolvable reach (finding #4)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('g${EMPTY:-}it push origin main --force', [root]));
    assert.ok(reaches('$CMD push origin main', [root]));
    assert.ok(reaches('${CMD} push origin main', [root]));
  } finally { rmTmp(root); }
});

test('reaches: nice/time/command/builtin/stdbuf/setsid/doas wrappers do not hide git (finding #1)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('nice -n 10 git push origin main; echo $(date)', [root]));
    assert.ok(reaches('command git push origin main; echo $(date)', [root]));
    assert.ok(reaches('time git push origin main; echo $(date)', [root]));
    assert.ok(reaches('builtin git push origin main; echo $(date)', [root]));
    assert.ok(reaches('stdbuf -oL git push origin main; echo $(date)', [root]));
    assert.ok(reaches('setsid git push origin main; echo $(date)', [root]));
    assert.ok(reaches('doas git push origin main; echo $(date)', [root]));
  } finally { rmTmp(root); }
});

test('reaches: known nice/time/command/builtin/stdbuf/setsid/doas options still strip cleanly (not over-refused)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('nice -n 10 echo $(date)', [root]), null);
    assert.strictEqual(reaches('nice --adjustment=10 echo $(date)', [root]), null);
    assert.strictEqual(reaches('time -p echo $(date)', [root]), null);
    assert.strictEqual(reaches('command echo $(date)', [root]), null);
    assert.strictEqual(reaches('builtin echo $(date)', [root]), null);
    assert.strictEqual(reaches('stdbuf -oL -eL echo $(date)', [root]), null);
    assert.strictEqual(reaches('setsid -f echo $(date)', [root]), null);
    assert.strictEqual(reaches('doas echo $(date)', [root]), null);
  } finally { rmTmp(root); }
});

test('detectShapes and reaches see through the nice/time/command/builtin/stdbuf/setsid/doas wrapper prefixes (parity, finding #1c)', () => {
  const { root } = mkWorktree();
  const prefixes = ['nice -n 10', 'nice --adjustment=10', 'time -p', 'time --verbose', 'command', 'builtin', 'stdbuf -oL', 'setsid -f', 'doas'];
  try {
    for (const p of prefixes) {
      assert.deepStrictEqual(detectShapes(`${p} pnpm lint`), ['pkgmgr'], `detectShapes did not see through ${JSON.stringify(p)}`);
      assert.ok(reaches(`${p} git status`, [root]), `reaches did not see through ${JSON.stringify(p)}`);
    }
  } finally { rmTmp(root); }
});

test('reaches: a reach-checked command name outside the command position (a wrapper or an argument) is still classified as reaching (finding #1b)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('somealias git push origin main', [root]), 'an unrecognised wrapper carrying a literal "git" argument reaches');
    assert.ok(reaches('somealias gh pr checkout 123', [root]), 'an unrecognised wrapper carrying a literal "gh" argument reaches');
  } finally { rmTmp(root); }
});

test('detectShapes and reaches see through the same wrapper prefixes (parity)', () => {
  const { root } = mkWorktree();
  const prefixes = [
    'sudo', 'nohup', 'exec', 'timeout 30', 'timeout -s TERM 30', 'timeout --kill-after=5s 30',
    'env', 'env -i', 'env -u FOO', 'env FOO=1', 'FOO=1', 'FOO=1 timeout 30 env BAR=2',
  ];
  try {
    for (const p of prefixes) {
      // `pnpm lint`, not `pnpm typecheck`: typecheck is a heavy script the admission hook owns (AE11).
      assert.deepStrictEqual(detectShapes(`${p} pnpm lint`), ['pkgmgr'], `detectShapes did not see through ${JSON.stringify(p)}`);
      assert.ok(reaches(`${p} git status`, [root]), `reaches did not see through ${JSON.stringify(p)}`);
    }
  } finally { rmTmp(root); }
});

test('reaches: cd outside the roots, and pushd/popd anywhere, are treated as reaching outright (AE7)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('cd /home/user/dotfiles', [root]));
    assert.ok(reaches('pushd /tmp', [root]));
    assert.ok(reaches('popd', [root]));
  } finally { rmTmp(root); }
});

// A literal `cd` into an allowed root keeps the command in bounds, and every
// relative path after it is checked from there as well as from the worktree.
test('reaches: a literal cd into an allowed root stays in bounds; relative paths resolve from it', () => {
  const { root } = mkWorktree();
  const tmp = fs.realpathSync(os.tmpdir());
  const d = fs.mkdtempSync(path.join(tmp, 'srt-cd-'));
  const roots = [root, tmp];
  try {
    // In bounds: the CE-leaf idiom, a cd into the worktree, a redirect on cd.
    assert.strictEqual(reaches(`cd ${d}; cat > findings.json <<'EOF'\n{"findings": []}\nEOF`, roots), null);
    assert.strictEqual(reaches(`cd ${d} && for n in a b; do echo $n >> out.txt; done`, roots), null);
    assert.strictEqual(reaches(`cd "${d}" && cat findings.json | jq .`, roots), null);
    assert.strictEqual(reaches(`cd ${root} && echo hi > notes.txt`, roots), null);
    assert.strictEqual(reaches(`cd ${d} 2>/dev/null && ls`, roots), null);
    assert.strictEqual(reaches(`echo $(cd ${d} && cat f)`, roots), null);

    // Out of bounds: the target, or a relative path read from the new directory.
    assert.ok(reaches(`cd ${d} && cat ../../etc/passwd`, roots), 'a relative path escaping from the cd target');
    assert.ok(reaches(`cd ${d}; echo hi > ../../etc/srt-x`, roots), 'a relative redirect escaping from the cd target');
    assert.ok(reaches(`echo $(cd ${d} && cat ../../etc/passwd)`, roots), 'the cd target governs a nested payload too');
    assert.ok(reaches('cd /etc && cat passwd', roots));
    assert.ok(reaches(`cd ${d}/../../etc`, roots), 'a .. segment is refused even when it would resolve in bounds');
    assert.ok(reaches(`cd ${d}/./x`, roots), 'a . segment is refused');
    assert.ok(reaches('cd relative/dir', roots), 'a relative target is refused');
    assert.ok(reaches('cd', roots), 'a bare cd goes to $HOME');
    assert.ok(reaches('cd -', roots), 'cd - goes to $OLDPWD');
    assert.ok(reaches('cd ~', roots));
    assert.ok(reaches('cd "$D"', roots));
    assert.ok(reaches(`cd ${tmp}/srt-*`, roots), 'a glob target is refused');
    assert.ok(reaches(`cd -P ${d}`, roots), 'an option makes two operands');
    assert.ok(reaches(`cd ${d} /etc`, roots));
  } finally { rmTmp(root); fs.rmSync(d, { recursive: true, force: true }); }
});

// The fixture makes the cd target matter. The worktree is `<top>/w1/w2/w3`,
// `d` is `<top>/side/d`, and only those two (not all of /tmp) are roots. So
// `../w3/a/b` from the worktree is inside it, while from `d` the same text is
// `<top>/side/w3/a/b`, outside every root. An implementation that ignores
// accepted cd targets, or drops them on the way into a nested payload, accepts
// each refused `reaches` below (#1606 review: the earlier escape assertions
// escaped from the worktree too, so they passed either way).
function cdBaseFixture() {
  const top = fs.realpathSync(mkTmp('srt-cdbase-'));
  const wt = path.join(top, 'w1', 'w2', 'w3');
  const d = path.join(top, 'side', 'd');
  fs.mkdirSync(path.join(wt, 'a', 'b'), { recursive: true });
  fs.mkdirSync(d, { recursive: true });
  return { top, wt, d, roots: [wt, d] };
}

test('reaches: a relative path is checked from the accepted cd target, including inside nested payloads', () => {
  const { top, wt, d, roots } = cdBaseFixture();
  const rel = '../w3/a/b';
  const escaped = path.join(d, rel);
  try {
    // From the worktree alone the operand is in bounds, so a pass here proves the cd base is what refuses below.
    assert.strictEqual(reaches(`cat ${rel}`, roots), null);
    const want = new RegExp(`resolves outside every allowed root: ${escaped.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')}`);
    assert.match(reaches(`cd ${d} && cat ${rel}`, roots) || '', want, 'a plain segment');
    assert.match(reaches(`cd ${d}; echo hi > ${rel}/x`, roots) || '', want, 'a redirect target');
    assert.match(reaches(`echo $(cd ${d} && cat ${rel})`, roots) || '', want, 'inside a command substitution');
    assert.match(reaches(`cd ${d} && bash -c 'cat ${rel}'`, roots) || '', want, 'inside a bash -c payload');
    assert.match(reaches(`cd ${d} && cat <<EOF\n$(cat ${rel})\nEOF`, roots) || '', want, 'inside an unquoted heredoc body');
    // The union keeps the worktree as a base after the cd, so a path in bounds only from there still passes.
    assert.strictEqual(reaches(`cd ${d} && cat ${path.join(wt, 'a', 'b')}`, roots), null);
    // A wrapped cd sets the base too.
    assert.match(reaches(`sudo cd ${d}; cat ${rel}`, roots) || '', want, 'a wrapped cd');
    // Pinned ordering: a dynamic command name is refused before the cd exemption is consulted.
    assert.match(reaches(`$X ${d} && cat x`, roots) || '', /^command name is built from an unresolvable/);
  } finally { rmTmp(top); }
});

// `./cd` and `/x/cd` are executables, not the builtin, and still reach.
// `command cd` runs the builtin, so its target gets the same check as `cd`.
test('reaches: only the builtin cd is accepted', () => {
  const { top, d, roots } = cdBaseFixture();
  try {
    assert.strictEqual(reaches(`cd ${d}`, roots), null);
    assert.match(reaches(`./cd ${d}`, roots) || '', /^command "cd" is treated as reaching outright/);
    assert.match(reaches(`${d}/cd ${d}`, roots) || '', /^command "cd" is treated as reaching outright/);
    assert.strictEqual(reaches(`command cd ${d}`, roots), null);
    assert.match(reaches('command cd /etc && cat passwd', roots) || '', /^command "cd" is treated as reaching outright unless/);
  } finally { rmTmp(top); }
});

// Only characters bash leaves alone in an unquoted word are accepted in a cd
// target. Each refused target below is one bash would rewrite before entering it.
test('reaches: a cd target with extglob, brace or quoting syntax reaches', () => {
  const { top, d, roots } = cdBaseFixture();
  try {
    fs.mkdirSync(path.join(d, 'x'));
    assert.strictEqual(reaches(`cd ${d}/x`, roots), null);
    for (const target of [`${d}/@(x)`, `${d}/+(x)`, `${d}/!(y)`, `${d}/{x,y}`, `${d}/x*`, `${d}/[x]`, `$'${d}'`, `${d}/~x`]) {
      assert.ok(reaches(`cd ${target} && cat f`, roots), `target ${target}`);
    }
  } finally { rmTmp(top); }
});

// `..` after a symlink leaves the symlink's target, as the kernel applies it.
// Folding `..` lexically first read `<root>/link/../x` as `<root>/x`.
test('reaches: .. after a symlink is applied to the symlink target, absolute or relative', () => {
  const { top, wt, d, roots } = cdBaseFixture();
  try {
    fs.mkdirSync(path.join(top, 'outside', 'deep'), { recursive: true });
    fs.writeFileSync(path.join(top, 'outside', 'secret'), 'x');
    fs.symlinkSync(path.join(top, 'outside', 'deep'), path.join(d, 'link'));
    const outside = path.join(top, 'outside', 'secret');
    const want = new RegExp(`resolves outside every allowed root: ${outside.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')}`);
    assert.match(reaches(`cat ${d}/link/../secret`, roots) || '', want, 'absolute form');
    // Relative, the same text is also checked from the worktree. Its own `link`
    // stays inside it, so only the cd target's `link` can refuse.
    fs.mkdirSync(path.join(wt, 'in', 'deep'), { recursive: true });
    fs.symlinkSync(path.join(wt, 'in', 'deep'), path.join(wt, 'link'));
    assert.strictEqual(reaches('cat link/../secret', roots), null);
    assert.match(reaches(`cd ${d} && cat link/../secret`, roots) || '', want, 'relative form from the cd target');
    // A real in-bounds `..` (no symlink) is still accepted.
    fs.mkdirSync(path.join(d, 'p', 'q'), { recursive: true });
    assert.strictEqual(reaches(`cat ${d}/p/q/../q`, roots), null);
    // A `..` after a component that does not exist yet: the same command can
    // mkdir it, and the `..` then lands on real directories, here back on the
    // outward symlink. Resolved to `/`, so it reaches.
    assert.match(reaches(`mkdir ${d}/m && cat ${d}/m/../link/../secret`, roots) || '',
      /resolves outside every allowed root: \/$/, 'a .. after a missing component');
    // Descending into a component that does not exist yet is still fine.
    assert.strictEqual(reaches(`mkdir -p ${d}/new/dir && cat ${d}/new/dir/f`, roots), null);
    // A dangling in-root symlink is judged at its outside target, not as a missing in-root path.
    fs.symlinkSync(path.join(top, 'outside', 'not-yet'), path.join(d, 'dangling'));
    assert.match(reaches(`echo hi >> ${d}/dangling`, roots) || '',
      new RegExp(`resolves outside every allowed root: ${path.join(top, 'outside', 'not-yet').replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')}$`),
      'a write through a dangling symlink');
    // A dangling target that fails closed ends the walk. `up` -> `m/../..` is
    // `/` while `m` is missing; continuing from `/` would read the rest, the
    // worktree's own path, as in bounds, while after `mkdir m` the kernel
    // lands at `<top>/side` + that path, outside every root.
    fs.symlinkSync('m/../..', path.join(d, 'up'));
    assert.match(reaches(`mkdir ${d}/m && echo hi > ${d}/up${wt}/f`, roots) || '',
      /resolves outside every allowed root: \/$/, 'a dangling target that fails closed');
    // A dangling target that does not exist yet leaves the rest as text, so a
    // `..` after it fails closed like any `..` after a missing component.
    fs.symlinkSync(path.join(d, 'gone', 'x'), path.join(d, 'tomissing'));
    assert.match(reaches(`cat ${d}/tomissing/../secret`, roots) || '',
      /resolves outside every allowed root: \/$/, 'a .. after a missing dangling target');
    // A relative dangling target resolves from the link's directory, so one
    // that stays in a root is still accepted.
    fs.symlinkSync('newdir/f', path.join(d, 'rel'));
    assert.strictEqual(reaches(`echo hi > ${d}/rel`, roots), null);
    // A symlink loop stops at the hop bound and reaches.
    fs.symlinkSync(path.join(d, 'loopb'), path.join(d, 'loopa'));
    fs.symlinkSync(path.join(d, 'loopa'), path.join(d, 'loopb'));
    assert.match(reaches(`echo hi >> ${d}/loopa`, roots) || '',
      /resolves outside every allowed root: \/$/, 'a symlink loop');
  } finally { rmTmp(top); }
});

// An unreadable directory is not a missing one. `chmod 755 locked && cd
// locked/link` is judged before the chmod runs, while `locked` (mode 000) hides
// a symlink to outside the roots; reading EACCES as "missing" kept the rest as
// in-root text, and the chmod then exposed the symlink (#1606 review).
test('reaches: a path under an unreadable in-root directory fails closed, a missing one does not', (t) => {
  const { top, d, roots } = cdBaseFixture();
  const locked = path.join(d, 'locked');
  try {
    fs.mkdirSync(path.join(top, 'outside'), { recursive: true });
    fs.mkdirSync(locked);
    fs.symlinkSync(path.join(top, 'outside'), path.join(locked, 'link'));
    fs.chmodSync(locked, 0o000);
    try { fs.lstatSync(path.join(locked, 'link')); t.skip('mode 000 is not enforced here (root or no permission bits)'); return; } catch { /* enforced */ }
    const refused = /resolves outside every allowed root: \/$|treated as reaching outright/;
    assert.match(reaches(`chmod 755 ${locked} && cd ${locked}/link && cat passwd`, roots) || '', refused, 'cd');
    assert.match(reaches(`chmod 755 ${locked} && cat ${locked}/link/passwd`, roots) || '', refused, 'cat');
    assert.match(reaches(`chmod 755 ${locked} && echo hi > ${locked}/link/f`, roots) || '', refused, 'redirect');
    // A component that does not exist (ENOENT) still takes missing mode.
    assert.strictEqual(reaches(`mkdir -p ${d}/nope/x && cat ${d}/nope/x/f`, roots), null);
    assert.strictEqual(reaches(`mkdir ${d}/nope && cd ${d}/nope && cat f`, roots), null);
    // So does one below a regular file (ENOTDIR): nothing can be traversed there.
    fs.writeFileSync(path.join(d, 'plain'), 'x');
    assert.strictEqual(reaches(`cat ${d}/plain/f`, roots), null);
    // An over-long name cannot exist either (ENAMETOOLONG).
    assert.strictEqual(reaches(`cat ${d}/${'x'.repeat(5000)}`, roots), null);
  } finally {
    try { fs.chmodSync(locked, 0o755); } catch { /* not created */ }
    rmTmp(top);
  }
});

// A symlink inside an allowed root that points outside it is followed before
// the root check, for the cd target as for any other path.
test('reaches: cd through a symlink that leaves the roots reaches', () => {
  const { root } = mkWorktree();
  const tmp = fs.realpathSync(os.tmpdir());
  const d = fs.mkdtempSync(path.join(tmp, 'srt-cdl-'));
  const roots = [root, tmp];
  try {
    fs.symlinkSync('/etc', path.join(d, 'out'));
    assert.ok(reaches(`cd ${d}/out && cat passwd`, roots));
  } finally { rmTmp(root); fs.rmSync(d, { recursive: true, force: true }); }
});

test('reaches: gh pr checkout / gh repo clone|sync reach outright', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('gh pr checkout 123', [root]));
    assert.ok(reaches('gh repo clone owner/repo', [root]));
    assert.ok(reaches('gh repo sync', [root]));
  } finally { rmTmp(root); }
});

test('reaches: gh pr checkout / gh repo clone|sync reach outright even with a global flag before the subcommand pair (finding #5)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('gh --repo owner/repo pr checkout 123', [root]));
    assert.ok(reaches('gh -R owner/repo pr checkout 123', [root]));
    // NOTE: `gh pr --repo owner/repo checkout 123` (a flag splitting the "pr"
    // and "checkout" pair itself) stays out of scope: the assigned fix widens
    // WHERE the adjacent pair may sit in `core`, not the adjacency
    // requirement itself. Residual gap, not regressed by this change.
    assert.ok(reaches('gh --repo owner/repo repo clone other/repo', [root]));
    assert.ok(reaches('gh --repo owner/repo repo sync', [root]));
  } finally { rmTmp(root); }
});

test('reaches: gh read-verb calls are not path-capable -- a $var/--jq argument does not reach (gh-read no-path)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('gh pr view $n', [root]), null);
    assert.strictEqual(reaches('gh pr list --limit $n', [root]), null);
    assert.strictEqual(reaches('gh pr checks $n', [root]), null);
    assert.strictEqual(reaches('gh pr diff $n', [root]), null);
    assert.strictEqual(reaches('gh pr status --repo owner/$n', [root]), null);
    assert.strictEqual(reaches('gh issue view $n', [root]), null);
    assert.strictEqual(reaches('gh issue list --limit $n', [root]), null);
    assert.strictEqual(reaches('gh issue status', [root]), null);
    assert.strictEqual(reaches('gh run list --limit $n', [root]), null);
    assert.strictEqual(reaches('gh run view $n', [root]), null);
    assert.strictEqual(reaches('gh run watch $n', [root]), null);
    assert.strictEqual(reaches('gh repo view $n', [root]), null);
    assert.strictEqual(reaches('gh release list --limit $n', [root]), null);
    assert.strictEqual(reaches('gh release view $n', [root]), null);
    assert.strictEqual(reaches('gh label list', [root]), null);
    assert.strictEqual(reaches('gh workflow list', [root]), null);
    assert.strictEqual(reaches('gh workflow view $n', [root]), null);
    assert.strictEqual(reaches('gh auth status', [root]), null);
    assert.strictEqual(reaches('gh api repos/owner/repo/pulls/$n --jq .title', [root]), null);
    assert.strictEqual(reaches('gh search issues "$n" --repo owner/repo', [root]), null);
    assert.strictEqual(
      reaches('gh --repo owner/repo pr view $n', [root]),
      null,
      'a global flag before the subcommand pair still resolves (finding #5 reasoning)',
    );
  } finally { rmTmp(root); }
});

test('reaches: gh write-shaped verbs/flags keep today\'s behavior (planted negatives, gh-read no-path)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('gh pr checkout $n', [root]));
    assert.ok(reaches('gh run download $n', [root]));
    assert.ok(reaches('gh api -X POST repos/owner/repo/issues/$n/comments -f body=hi', [root]));
    assert.ok(reaches('gh pr edit $n --body-file -', [root]));
    // No $var at all in this exact literal call -- "today's behavior" for a
    // fully-static gh api call was already null pre-#1273 (nothing dynamic to
    // flag as unresolvable); the write-flag detection itself is exercised
    // meaningfully by the next assertion, which adds a $var.
    assert.strictEqual(reaches('gh api repos/x/y -f k=v', [root]), null);
    assert.ok(
      reaches('gh api repos/owner/repo/issues/$n -f body=hi', [root]),
      'a write-flagged api call with a $var stays reaching -- ghNoPath must be false here',
    );
  } finally { rmTmp(root); }
});

// P1 (adversarial review of PR #1295 round 2, finding 1): ghNoPathSegment()
// used to scan every adjacent literal pair ANYWHERE in the argument list, so
// a write verb whose ARGUMENT VALUES happened to contain read-verb tokens
// read as a no-path read. `gh issue edit $n --title search` matched the bare
// literal "search" sitting in a `--title` VALUE; `gh issue edit $n --body pr
// view` matched the adjacent pair "pr view" sitting in a `--body` VALUE.
// Both let an unresolved `$n` on a genuinely mutating `gh issue edit` pass
// through un-flagged. Fixed by reading the subcommand from a FIXED position
// (the first one or two bare words after skipping the leading global-flag
// run) instead of scanning the whole argument list.
test('reaches: gh subcommand detection is anchored to the subcommand position, not any adjacent literal pair (P1, adversarial review of PR #1295 round 2, finding 1)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(
      reaches('for n in 1 2; do gh issue edit $n --title search; done', [root]),
      'a "search" token sitting in a --title VALUE must not read as the gh-search read shape',
    );
    assert.ok(
      reaches('for n in 1 2; do gh issue edit $n --body pr view; done', [root]),
      'a "pr view" pair sitting in a --body VALUE must not read as the gh-read pr:view shape',
    );
  } finally { rmTmp(root); }
});

test('reaches: gh subcommand anchoring still resolves through a leading global flag (planted negatives, gh subcommand anchoring)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('gh --repo o/r pr view $n', [root]), null);
    assert.strictEqual(reaches('gh -R o/r issue list', [root]), null);
    assert.strictEqual(reaches('gh pr view $n --repo o/r', [root]), null);
  } finally { rmTmp(root); }
});

// P1 (adversarial review of PR #1295 round 2, finding 2): ghApiIsReadOnly()
// checked --input/--body-file only as exact tokens; gh (cobra/pflag) accepts
// the glued `--input=value` form identically to the space-separated one, and
// it was not checked at all, so a write-shaped `gh api` call with an
// unresolved `$n` in its path AND a glued --input= flag read as a no-path
// read.
test('reaches: gh api glued write-flag form (--input=/--body-file=) is caught the same as the unglued form (P1, adversarial review of PR #1295 round 2, finding 2)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(
      reaches('for n in 1 2; do gh api repos/x/y/issues/$n/comments --input=payload.json; done', [root]),
      'the glued --input= form must reach identically to --input payload.json',
    );
  } finally { rmTmp(root); }
});

test('reaches: gh api -X/--method GET is read-only; a bare POST with no other write flag still reaches, including glued forms (finding #7)', () => {
  const { root } = mkWorktree();
  try {
    // -X GET / --method GET, unglued and glued, stay read-only even with an
    // unresolved $n elsewhere in the call -- ghNoPath must be true here, or
    // the $n would flag it as reaching for an unrelated reason and this
    // test would pass for the wrong cause.
    assert.strictEqual(reaches('gh api repos/x/y/issues/$n -X GET', [root]), null);
    assert.strictEqual(reaches('gh api repos/x/y/issues/$n --method GET', [root]), null);
    assert.strictEqual(reaches('gh api repos/x/y/issues/$n -XGET', [root]), null);
    assert.strictEqual(reaches('gh api repos/x/y/issues/$n --method=GET', [root]), null);
    // A bare POST (unglued, glued, and long-flag) with no OTHER write flag
    // present must still reach -- POST is a write-shaped method on its own,
    // not merely a marker that co-occurs with -f/-F elsewhere.
    assert.ok(reaches('gh api repos/x/y/issues/$n -X POST', [root]));
    assert.ok(reaches('gh api repos/x/y/issues/$n -XPOST', [root]));
    assert.ok(reaches('gh api repos/x/y/issues/$n --method POST', [root]));
    assert.ok(reaches('gh api repos/x/y/issues/$n --method=POST', [root]));
  } finally { rmTmp(root); }
});

test('reaches: eval/xargs/parallel/awk/sed are opaque and treated as reaching', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('eval $(echo ls)', [root]));
    assert.ok(reaches('echo x | xargs echo', [root]));
    assert.ok(reaches('echo x | awk \'{print $1}\'', [root]));
    assert.ok(reaches('echo x | sed \'s/a/b/\'', [root]));
  } finally { rmTmp(root); }
});

test('reaches: find with -exec/-execdir reaches; find without it does not', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('find . -name "*.tmp" -exec rm {} \\;', [root]));
    assert.strictEqual(reaches('find . -name "*.tmp"', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: an inline interpreter program (python -c / node -e) reaches', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('python3 -c "import os"', [root]));
    assert.ok(reaches('node -e "1+1"', [root]));
    assert.ok(reaches('perl -e "1"', [root]));
    assert.ok(reaches('ruby -e "1"', [root]));
  } finally { rmTmp(root); }
});

test('reaches: an interpreter running a script FILE by path does not reach on that basis alone', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches(`python3 ${root}/count-rows.py`, [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: an interpreter reading from stdin (bare "-" or heredoc-fed) reaches', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('python3 -', [root]));
    assert.ok(reaches('node - <<EOF\n1\nEOF', [root]));
  } finally { rmTmp(root); }
});

test('reaches: an interpreter fed by a QUOTED-delimiter heredoc on bare "-" now reaches outright -- F1 revert (adversarial review of PR #1295 round 6)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("python3 - <<'EOF'\nprint(1)\nEOF", [root]));
    assert.ok(reaches("python - <<'TAG'\nprint(1)\nTAG", [root]));
    assert.ok(reaches("node - <<'EOF'\nconsole.log(1)\nEOF", [root]));
    assert.ok(reaches("perl - <<'EOF'\nprint 1;\nEOF", [root]));
    assert.ok(reaches("ruby - <<'EOF'\nputs 1\nEOF", [root]));
  } finally { rmTmp(root); }
});

test('reaches: an UNQUOTED-delimiter heredoc-fed interpreter still reaches (planted negative -- it expands $(...) in its body, so it is not inert data)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('python3 - <<EOF\nprint(1)\nEOF', [root]));
  } finally { rmTmp(root); }
});

test('reaches: -c/-e with an incidental heredoc on the same line still reaches (planted negative -- a program-bearing flag disqualifies the carve-out)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("python3 -c \"import sys\" <<'EOF'\nignored\nEOF", [root]));
  } finally { rmTmp(root); }
});

test('reaches: an interpreter running a script FILE fed by a quoted heredoc still reaches (planted negative -- the heredoc is not its program source, so the shape does not apply)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches(`python3 ${root}/script.py <<'EOF'\nignored\nEOF`, [root]));
  } finally { rmTmp(root); }
});

test('reaches: a git/cd-prefixed chain before a quoted heredoc-fed interpreter still reaches through the OTHER segment (planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("cd /home/user/dotfiles && python3 - <<'EOF'\nprint(1)\nEOF", [root]));
    assert.ok(reaches("git status && python3 - <<'EOF'\nprint(1)\nEOF", [root]));
  } finally { rmTmp(root); }
});

// F1 (adversarial review of PR #1295 round 6): the interp carve-out this
// section originally tested (a quoted-delimiter heredoc on bare "-" was
// exempted from "reaches outright" if its BODY passed a denylist scan for
// host-reaching literals/paths) is REVERTED, not hardened. The denylist
// approach was proven unsound rather than merely incomplete: three
// computed-payload constructions -- a chr()-built path fed to open() for
// read, a chr()-built path fed to open() for write, and
// getattr(os, 'sys'+'tem') dynamic dispatch built via string concatenation
// -- all evaded every entry on HEREDOC_BODY_LITERAL_DENY (no denylisted
// literal ever appears as a raw substring) and were live-reproduced against
// 682831d returning `reaches() -> null`, i.e. classified as safe and
// rewritten to `bash <script>` with no further scrutiny. A pattern/substring
// scan over a Turing-complete language's raw source text cannot be made
// sound against composed or computed constructions without actually parsing
// the target language, which is disproportionate for a shell-command-shape
// classifier and was not attempted -- per the reviewing brief's own
// instruction ("if you cannot articulate a sound gate precisely, take the
// revert"), the fix is to go back to treating ANY heredoc-fed bare "-" as
// reaching outright, regardless of body content. The denylist family
// (HEREDOC_BODY_LITERAL_DENY, HEREDOC_BODY_DENY_PATH_PREFIXES,
// normalizeHeredocPathToken, heredocBodyHasOutsidePath, heredocBodyReaches)
// is deleted from lib/shape-rewrite-reach.js in the same change, so the
// content-discriminating tests that used to live in this section (git/gh
// literal discrimination, network-egress and env-var-read primitive
// breadth, path-normalization edge cases, and the resolved-root allowance
// that let a same-worktree body path stay non-reaching) no longer exercise
// any code path that exists -- every one of those bodies reaches now,
// unconditionally, for the same reason (there is no carve-out left to test
// around). They are replaced below by: one test proving the exact PWNED
// reproduction still reaches post-revert, one test proving even a
// previously-"benign" body now reaches (the whole point of the revert), and
// three new exploit-reproduction tests using computed-at-runtime payloads
// (character codes, attribute lookup, string concatenation) rather than the
// literal payloads a denylist could have caught, per the review brief's
// explicit RED-FIRST instruction for F1.
test('reaches: interp carve-out heredoc body is no longer scrutinized for content -- the PWNED reproduction reaches because ALL such heredocs now reach outright (F1 revert, adversarial review of PR #1295 round 6)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(
      reaches(
        "python3 - <<'EOF'\nwith open('/home/user/dotfiles/PWNED_FROM_HEREDOC.md', 'w') as f:\n    f.write('pwned')\nEOF",
        [root],
      ),
      'a heredoc body writing an absolute path outside every allowed root must reach',
    );
  } finally { rmTmp(root); }
});

test('reaches: a previously-"benign" heredoc body (touching only /tmp or a worktree-relative path) now reaches too -- there is no body-content carve-out left (F1 revert, adversarial review of PR #1295 round 6)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(
      reaches("python3 - <<'EOF'\nimport json,sys\nd=json.load(open('/tmp/x.json'))\nprint(len(d))\nEOF", [root]),
      'a body touching only /tmp now reaches -- the interp carve-out no longer exists to exempt it',
    );
    assert.ok(
      reaches(`python3 - <<'EOF'\nprint(open('${root}/report.txt').read())\nEOF`, [root]),
      'a body touching only a worktree-root-relative path now reaches -- same reason',
    );
  } finally { rmTmp(root); }
});

// F1 exploit reproductions (adversarial review of PR #1295 round 6): each
// payload below builds its dangerous string at runtime (chr() character
// codes, or getattr()-based attribute lookup plus string concatenation)
// specifically so that no denylist literal would ever appear in the raw
// source text -- these are the constructions that defeated the now-removed
// denylist live against 682831d (`reaches() -> null` for all three) and are
// kept here as permanent regression tests proving the revert closes the gap
// unconditionally, not by extending the pattern list to cover these three
// specific shapes.
test('reaches: F1 exploit -- a chr()-built path read via open() reaches (computed payload, adversarial review of PR #1295 round 6)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(
      reaches(
        "python3 - <<'EOF'\n"
        + "p = ''.join([chr(47), chr(101), chr(116), chr(99), chr(47), chr(112), chr(97), chr(115), chr(115), chr(119), chr(100)])\n"
        + "print(open(p).read())\n"
        + "EOF",
        [root],
      ),
      'a chr()-built "/etc/passwd" read must reach even though no denylisted literal appears in the source text',
    );
  } finally { rmTmp(root); }
});

test('reaches: F1 exploit -- a chr()-built path write via open() reaches (computed payload, adversarial review of PR #1295 round 6)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(
      reaches(
        "python3 - <<'EOF'\n"
        + "p = chr(47)+chr(104)+chr(111)+chr(109)+chr(101)+chr(47)+chr(119)+chr(105)+chr(108)+chr(108)+chr(47)+chr(100)+chr(111)+chr(116)+chr(102)+chr(105)+chr(108)+chr(101)+chr(115)+chr(47)+chr(80)+chr(87)+chr(78)+chr(69)+chr(68)+chr(50)+chr(46)+chr(109)+chr(100)\n"
        + "with open(p, 'w') as f:\n"
        + "    f.write('pwned')\n"
        + "EOF",
        [root],
      ),
      'a chr()-built outside-root write must reach even though no denylisted literal appears in the source text',
    );
  } finally { rmTmp(root); }
});

test('reaches: F1 exploit -- getattr()-based os.system dynamic dispatch reaches (computed payload, adversarial review of PR #1295 round 6)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(
      reaches(
        "python3 - <<'EOF'\n"
        + "import os\n"
        + "fn = getattr(os, 'sys' + 'tem')\n"
        + "fn('id > ' + chr(47) + 'tmp' + chr(47) + 'x')\n"
        + "EOF",
        [root],
      ),
      'a getattr()-based os.system dispatch must reach even though the literal "os.system" never appears in the source text',
    );
  } finally { rmTmp(root); }
});


test('reaches: ln -s / cp -s create a symlink and are treated as reaching', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches(`ln -s ${root}/a ${root}/b`, [root]));
    assert.ok(reaches(`cp -s ${root}/a ${root}/b`, [root]));
  } finally { rmTmp(root); }
});

test('reaches: a redirect target outside every root reaches; inside a root it does not', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('echo hi > /etc/passwd', [root]));
    assert.strictEqual(reaches(`echo hi > ${root}/out.txt`, [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: >|, <>, and &>> redirect targets outside the roots reach through a symlink (finding #6)', () => {
  const { root } = mkWorktree();
  const outside = mkTmp('shape-rw-outside6-');
  try {
    const link1 = path.join(root, 'escape-link-a');
    const link2 = path.join(root, 'escape-link-b');
    const link3 = path.join(root, 'escape-link-c');
    fs.symlinkSync(outside, link1);
    fs.symlinkSync(outside, link2);
    fs.symlinkSync(outside, link3);
    assert.ok(reaches(`echo hi >| ${link1}/out.txt`, [root]), '>| (glued or spaced)');
    assert.ok(reaches(`echo hi >|${link1}/out.txt`, [root]), '>| glued to the target');
    assert.ok(reaches(`exec 3<> ${link2}/out.txt`, [root]), '<>');
    assert.ok(reaches(`echo hi &>> ${link3}/out.txt`, [root]), '&>>');
    assert.strictEqual(reaches(`echo hi >| ${root}/out.txt`, [root]), null, 'an in-root >| target does not reach');
  } finally { rmTmp(root); rmTmp(outside); }
});

// NOTE: the four assertions above already passed before the reachWords
// tokenizer/REDIRECT_TARGET_OPS change too -- a literal (non-dynamic,
// non-$VAR) redirect target is canonicalized and root-checked identically
// whether it is reached via the always=true redirect-target path or
// (pre-fix, through >|'s accidental segment split on the un-tokenized '|')
// via the generic argument scan, since findings #2/#3 made every literal
// word go through the same canonicalize-and-check logic either way. They
// are kept as symlink-escape regression locks, not failing-first tests.
// The assertion below is the genuine failing-first regression for finding
// #6: a `$VAR`-bearing target after `>&` behind an OUTPUT_ONLY_COMMANDS
// head (`printf`) is trusted (null) pre-fix, because `>&` was not in the
// redirect-target op set at all, so the target fell through to the
// generic (always=false) scan where printf's output-only exemption
// applies; `>&` targets must always reach regardless of the head command,
// since the redirect writes to a file, not to printf's own stdout.
test('reaches: a $VAR->& redirect target behind an output-only head always reaches (finding #6)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('printf x >& $ESCAPE_VAR/out.txt', [root]));
  } finally { rmTmp(root); }
});

test('reaches: >& and <& fd-duplication targets (a digit or "-") are not treated as paths (finding #6)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('echo hi >&2', [root]), null);
    assert.strictEqual(reaches('echo hi 1>&2', [root]), null);
    assert.strictEqual(reaches('exec 3>&-', [root]), null);
    assert.strictEqual(reaches('exec 3<&-', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: a >& target that is a real path (not an fd digit or "-") is still checked (finding #6)', () => {
  const { root } = mkWorktree();
  const outside = mkTmp('shape-rw-outside6b-');
  try {
    const link = path.join(root, 'escape-link-d');
    fs.symlinkSync(outside, link);
    assert.ok(reaches(`echo hi >& ${link}/out.txt`, [root]));
  } finally { rmTmp(root); rmTmp(outside); }
});

// finding #7: the tee special case must key off tee's own position in
// `core` (coreStart = seg.length - core.length), not raw segment index 0
// -- `sudo tee ...` and `env FOO=1 tee ...` put tee past index 0 in `seg`.
// A bare $VAR target already reached before this fix too (tee is not in
// OUTPUT_ONLY_COMMANDS, so the generic always=false scan already flags any
// hasVarRef argument for it); the genuine failing-first case is a PURE
// substitution target (`$(...)`  with no glued literal text): always=false
// trusts it unconditionally (its own command was independently validated,
// but the write path its output resolves to was not), while always=true
// -- which only engages when the tee-position check is correct -- never
// grants that trust for a write target.
test('reaches: sudo tee / env FOO=1 tee with a variable target reaches; an in-root literal target does not (finding #7)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('sudo tee $ESCAPE_VAR/out.txt', [root]), 'sudo tee, bare $VAR target');
    assert.ok(reaches('env FOO=1 tee $ESCAPE_VAR/out.txt', [root]), 'env FOO=1 tee, bare $VAR target');
    assert.ok(reaches('sudo tee $(compute_path)', [root]), 'sudo tee, pure-substitution target (the failing-first case)');
    assert.ok(reaches('env FOO=1 tee $(compute_path)', [root]), 'env FOO=1 tee, pure-substitution target (the failing-first case)');
    assert.strictEqual(reaches(`sudo tee ${root}/out.txt`, [root]), null, 'sudo tee, in-root literal target');
    assert.strictEqual(reaches(`env FOO=1 tee ${root}/out.txt`, [root]), null, 'env FOO=1 tee, in-root literal target');
  } finally { rmTmp(root); }
});

test('reaches: scratch dir, /tmp, and $HOME/.claude/jobs are non-reaching roots when passed', () => {
  const { root } = mkWorktree();
  const scratch = mkTmp('shape-rw-scratch-');
  try {
    assert.strictEqual(reaches(`echo hi > ${scratch}/out.txt`, [root, scratch]), null);
    assert.strictEqual(reaches(`echo hi > ${os.tmpdir()}/shaperw-x.txt`, [root, scratch, os.tmpdir()]), null);
  } finally { rmTmp(root); rmTmp(scratch); }
});

test('reaches: /dev/null and siblings are exempt from the redirect-target check', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('echo hi > /dev/null', [root]), null);
    assert.strictEqual(reaches(`diff ${root}/a /dev/null`, [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: a symlink target that resolves outside the roots reaches (canonicalization, not literal text)', () => {
  const { root } = mkWorktree();
  const outside = mkTmp('shape-rw-outside-');
  try {
    const link = path.join(root, 'escape-link');
    fs.symlinkSync(outside, link);
    assert.ok(reaches(`echo hi > ${link}/out.txt`, [root]));
  } finally { rmTmp(root); rmTmp(outside); }
});

test('reaches: an argument built from a variable/expression combined with a path is an unresolvable reach', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('echo hi > "$(dirname /etc)/x"', [root]));
    assert.ok(reaches('echo hi > "$UNKNOWN_DIR/x"', [root]));
  } finally { rmTmp(root); }
});

test('reaches: a substitution feeding a path-capable command reaches even when its payload is in-root, because the payload\'s OUTPUT is what names the path (R4)', () => {
  const { root } = mkWorktree();
  try {
    // `dirname out/report.txt` itself is harmless and in-root; what mkdir
    // receives is whatever it prints at runtime, which the hook cannot resolve.
    assert.ok(reaches('mkdir -p $(dirname out/report.txt)', [root]));
  } finally { rmTmp(root); }
});

test('reaches: an unresolved ${VAR:-x} generic argument reaches unless the command is output-only (finding #2)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('rm -rf ${HOME:-x}', [root]));
    assert.ok(reaches('X=/etc; rm -rf ${X:-nothing}', [root]));
    assert.strictEqual(reaches('echo ${HOME:-x}', [root]), null, 'echo cannot touch a path through an argument');
    assert.strictEqual(reaches('printf ${HOME:-x}', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: tr joins the output-only no-path set -- a $var argument does not reach; echo/printf keep today\'s behavior too (no-path variables, positives)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('tr -d "$CHARS"', [root]), null);
    assert.strictEqual(reaches('echo "$x"', [root]), null);
    assert.strictEqual(reaches('printf \'%s\' "$x"', [root]), null);
  } finally { rmTmp(root); }
});

// P1 containment hole (adversarial review of PR #1295, finding 1): jq, cut,
// sort, uniq, head, tail, and wc each take a FILE operand -- sort/uniq/tee
// can WRITE one (`sort -o file`, `uniq in out`) and the rest READ one
// (`head file`, `jq . file`, `wc -l file`, `cut -f1 file`). Adding any of
// them to the output-only no-path set (as the original #1273 work did)
// exempted that operand from the unresolvable-variable check, so a $var
// there could resolve to a read or write target OUTSIDE the worktree and
// still be rewritten -- a containment hole, not a missed optimization. Fixed
// by removing all seven from OUTPUT_ONLY_COMMANDS; every case below reached
// `null` (a false negative) before that fix.
test('reaches: sort/uniq/jq/cut/head/tail/wc are NOT output-only -- a $var in a file-operand position still reaches (containment hole, no-path variables)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('sort -o $out data.txt', [root]), 'sort -o names a write target');
    assert.ok(reaches('uniq $infile $outfile', [root]), 'uniq\'s second operand is a write target');
    assert.ok(reaches('D=$(sort -o "$OUT" data.txt)', [root]), 'the same reach check applies inside an assignment-substitution payload (assignment substitution)');
    assert.ok(reaches('head $f', [root]));
    assert.ok(reaches('jq . $f', [root]));
    assert.ok(reaches('wc -l $f', [root]));
    assert.ok(reaches('cut -d, -f1 "$LINE"', [root]));
    assert.ok(reaches('tail -n1 "$X"', [root]));
  } finally { rmTmp(root); }
});

// `date` shares the same file-operand-semantics violation `sort`/`cut`/etc.
// were removed for above: `date -f FILE` reads dates line-by-line from
// FILE, so an unresolvable `$VAR` there is a read of unknown content, not
// output-only text. Live-reproduced: `date -f <file-with-non-date-lines>`
// echoes those lines verbatim to stderr (ce-code-review round on 2b279d2,
// finding #4).
test('reaches: date is not output-only -- an unresolvable variable in date\'s -f file operand reaches (finding #4)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('date -f "$VAR" +%s', [root]));
    assert.ok(reaches('date -d "$VAR"', [root]));
  } finally { rmTmp(root); }
});

// checkPathWord has no flag-awareness at all -- `outputOnly` bypasses the
// unresolvable-variable check unconditionally, the same hole `date` had.
// test/[/[[ take the identical -f/-e/-r/-w/-x/-s file-test operators, so
// they share it too; removed for the same reason, not merely by analogy.
test('reaches: test/[/[[ are not output-only -- an unresolvable variable in a file-test operand reaches (finding #4)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('test -f "$VAR"', [root]));
    assert.ok(reaches('[ -e "$VAR" ]', [root]));
    assert.ok(reaches('[[ -r "$VAR" ]]', [root]));
  } finally { rmTmp(root); }
});

test('reaches: a variable reaching any other command\'s argument still reaches (planted negatives, no-path variables)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('for f in *.md; do cat "$f"; done', [root]));
    assert.ok(reaches('sed -n 1p $S/x', [root]));
    assert.ok(reaches('bash "$SCRIPT"', [root]));
    assert.ok(reaches('git -C "$WT" status', [root]));
  } finally { rmTmp(root); }
});

test('reaches: a no-path/gh-read-verb command sitting behind a for/if-body keyword resolves through the loop variable (gh-read no-path, no-path variables, "or loop variable")', () => {
  const { root } = mkWorktree();
  try {
    // `do`/`then`/`else`/`elif` are shell compound-statement syntax, not
    // commands -- segment() only breaks on punctuation chain ops, so the
    // real command sits one slot after the keyword in the SAME segment.
    // Mined refusals include exactly this shape (`for n in ...; do gh pr
    // view $n; done`); before stripping these keywords as no-op wrapper
    // prefixes, "gh"/"echo" read as an ARGUMENT rather than the segment's
    // head, which hid them from the no-path dispatch entirely.
    assert.strictEqual(reaches('for n in 2997 3000; do gh pr view $n; done', [root]), null);
    assert.strictEqual(reaches('for n in 2997 3000; do gh pr view "$n" --json number; done', [root]), null);
    assert.strictEqual(reaches('for i in 1 2; do echo p9-$i; done', [root]), null);
    assert.strictEqual(reaches('if true; then gh pr view $n; fi', [root]), null);
  } finally { rmTmp(root); }
});

// #1317: an unquoted newline is a command separator. reachWords() used to
// read it as plain whitespace, so every later line became more arguments to
// the first line's command -- behind an output-only `echo`, a variable path
// on a later line skipped the unresolvable-variable check. Each of these
// returned null (rewritable) before the fix; the `;` form never did.
test('reaches: a newline separates commands, so a variable path on a later line reaches even behind an output-only first line (#1317)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('echo "$(date)"\nrm -rf "$TARGET"', [root]), 'rm on line 2 is its own command');
    assert.ok(reaches('echo "$(date)"\ntee "$OUT"', [root]));
    assert.ok(reaches('echo "$(date)"\ncp "$SRC" "$DST"', [root]));
    assert.ok(reaches('for f in a b; do\n  echo "=== $f ==="\n  cp "$f" "$DEST"\ndone', [root]), 'the loop-body idiom: echo header, then a command on the loop variable');
    assert.ok(reaches('echo x\nD=/etc\nrm -rf "$D/x"', [root]));
    assert.ok(reaches('echo x\nfind . -exec rm {} \\;', [root]), 'find -exec on a later line is its own find call');
    // The `;` forms, which were always refused, stay refused.
    assert.ok(reaches('echo "$(date)"; rm -rf "$TARGET"', [root]));
  } finally { rmTmp(root); }
});

test('reaches: a newline after |, &&, || or ( continues the command, so piped stdin and chained reaches are kept (#1317)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('echo x |\nbash', [root]), 'bash still reads the pipe as its script');
    assert.ok(reaches('echo x |\n\n  sh', [root]));
    assert.ok(reaches('echo "$(date)" &&\nrm -rf "$T"', [root]));
    assert.ok(reaches('true ||\nrm -rf "$T"', [root]));
    // Backslash-newline is a line continuation: bash reads `echo a rm "$X"`,
    // so rm really is an echo argument there.
    assert.strictEqual(reaches('echo a \\\nrm "$X"', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: line-per-command bodies are checked per line, so an output-only line keeps its variables (#1317, positives)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('cat README.md\necho "$(date) $X"', [root]), null);
    assert.strictEqual(reaches('for n in 1 2; do\n  echo "=== $n ==="\n  gh pr view $n --json number\ndone', [root]), null);
    assert.strictEqual(reaches('ls\n\necho done', [root]), null, 'blank lines are harmless');
  } finally { rmTmp(root); }
});

test('reachWords: an unquoted newline is a "\\n" op; a quoted or backslash-escaped one is not (#1317)', () => {
  const ops = (cmd) => reachWords(cmd).filter((e) => e.type === 'op').map((e) => e.value);
  assert.deepStrictEqual(ops('a\nb'), ['\n']);
  assert.deepStrictEqual(ops('a |\nb'), ['|']);
  assert.deepStrictEqual(ops('a;\nb'), [';']);
  assert.deepStrictEqual(ops('\na\n\n\nb\n'), ['\n', '\n']);
  assert.deepStrictEqual(ops('echo "a\nb"'), []);
  assert.deepStrictEqual(ops("echo 'a\nb'"), []);
  assert.deepStrictEqual(ops('echo a \\\nb'), []);
  assert.deepStrictEqual(ops('a &\nb'), ['&']);
  assert.deepStrictEqual(ops('(\nb'), ['(']);
});

// #1317 review: a word-start `#` refuses outright. Read as words, a comment
// between `|` and the newline made the newline a separator, so `bash` on the
// next line lost its piped stdin, and a quote in a comment swallowed every
// later line. Skipping comments instead is wrong wherever bash does not read
// `#` as one (extglob, `(( ))`, `${ }`, `$[ ]`): the rest of that line runs.
test('reaches: a word-start # refuses outright, so a comment can neither cut a pipe nor hide a line (#1317 review)', () => {
  const { root } = mkWorktree();
  try {
    const script = 'printf \'%s\' "$(printf \'rm -rf /etc/x\')"';
    assert.ok(reaches(`${script} | # run it\nbash`, [root]), 'bash reads the pipe as its script');
    assert.ok(reaches(`${script} |\n# run it\nbash`, [root]), 'a comment-only line between the pipe and bash');
    assert.ok(reaches('echo "$(date)" # don\'t\nrm -rf "$TARGET"', [root]));
    assert.ok(reaches('# it\'s a note\necho "$(date)"\nrm -rf "$TARGET"', [root]));
    assert.ok(reaches('echo "$(date)" # see <<\'EOF\'\nrm -rf "$TARGET"\nEOF', [root]), 'a heredoc operator inside a comment');
    assert.ok(reaches('shopt -s extglob\necho "$(date)" @(#x); rm -rf "$TARGET"', [root]), 'extglob: # is pattern text, and rm runs');
    assert.ok(reaches('echo "$(date)"; (( # )); rm -rf "$TARGET"', [root]), 'arithmetic: # is expression text, and rm runs');
    assert.ok(reaches('echo "$(date)" # stamp\nls', [root]), 'even a harmless comment refuses');
    // Only a word-start, unquoted, unescaped # counts.
    assert.strictEqual(reaches('echo "$(date)" a#b "#c" \'#d\' \\#e $# ${#X} ${X#p}', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: a # in an unquoted heredoc body is data, so it does not refuse, and its $( ) is still checked (#1317 review)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('cat > notes.md <<EOF\n# Title\nEOF\necho "$(date)"', [root]), null);
    assert.ok(reaches('cat > notes.md <<EOF\n# $(rm -rf /etc/x)\nEOF\necho "$(date)"', [root]));
    assert.ok(reaches('cat > notes.md <<EOF\n# title $(touch "$T")\nEOF\necho "$(date)"', [root]));
    assert.strictEqual(reaches('cat > notes.md <<\'EOF\'\n# $(rm -rf /etc/x)\nEOF\necho "$(date)"', [root]), null, 'a quoted body expands nothing');
  } finally { rmTmp(root); }
});

test('reachWords: marks a word-start # in source and keeps it as text; # inside a word, in quotes, escaped or in a heredoc body is not marked (#1317 review)', () => {
  const ops = (cmd) => reachWords(cmd).filter((e) => e.type === 'op').map((e) => e.value);
  assert.strictEqual(reachWords('a | # note\nb').hashWord, true);
  assert.deepStrictEqual(ops('a | # note\nb'), ['|', '\n']);
  assert.strictEqual(reachWords('# x').hashWord, true);
  assert.strictEqual(reachWords('a#b "#c" \'#d\' \\#e $# ${#x} ${x#y}').hashWord, undefined);
  assert.strictEqual(reachWords('# x', { heredocBody: true }).hashWord, undefined);
});

test('reaches: a path-capable command behind a for/if-body keyword still reaches (planted negatives)', () => {
  const { root } = mkWorktree();
  try {
    // Loop-keyword stripping must not launder a path-capable command or an
    // outright-reaching one just because it sits behind "do"/"then".
    assert.ok(reaches('for f in *.md; do cat "$f"; done', [root]));
    assert.ok(reaches('for n in 1 2; do git checkout "$n"; done', [root]));
    assert.ok(reaches('if true; then gh pr checkout $n; fi', [root]));
  } finally { rmTmp(root); }
});

test('reaches: else/elif keyword-headed segments resolve through the keyword the same way do/then do, both positive and planted-negative (ce-code-review #11/#14)', () => {
  const { root } = mkWorktree();
  try {
    // Only do/then were ever exercised (mutation-confirmed: deleting the
    // else/elif entries left all tests green); this discriminates them.
    assert.strictEqual(reaches('if false; then echo a; else gh pr view $n; fi', [root]), null);
    assert.strictEqual(reaches('if false; then echo a; elif gh pr view $n; then echo b; fi', [root]), null);
    assert.ok(reaches('if false; then echo a; else git push; fi', [root]));
    assert.ok(reaches('if false; then echo a; elif git push; then echo b; fi', [root]));
  } finally { rmTmp(root); }
});

test('reaches: a plain relative-path argument that resolves outside the roots through a symlink reaches (finding #3)', () => {
  const { root } = mkWorktree();
  const outside = mkTmp('shape-rw-outside3-');
  try {
    fs.writeFileSync(path.join(outside, 'secret.txt'), 'TOP SECRET');
    fs.symlinkSync(outside, path.join(root, 'escape-link'));
    assert.ok(reaches('cat escape-link/secret.txt; echo $(date)', [root]));
    assert.strictEqual(reaches('cat report.txt; echo $(date)', [root]), null, 'a plain in-root relative argument still passes');
  } finally { rmTmp(root); rmTmp(outside); }
});

test('reaches: a bare "~" or "~/..." argument resolves against the home directory before the root check (finding #2/#3 tilde handling)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('cat ~/.ssh/id_rsa; echo $(date)', [root]), '~/... resolves outside every root here');
    assert.ok(reaches('cat ~otheruser/secret; echo $(date)', [root]), '~otheruser cannot be resolved and is an unresolvable reach');
  } finally { rmTmp(root); }
});

test('reaches: recurses into a command-substitution payload', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('echo $(git status)', [root]));
    assert.strictEqual(reaches('echo $(date)', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: a standalone assignment statement whose value is an in-root command substitution does not reach; the bound variable is read (output-only) in a later segment', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches(`SCRATCH=$(mktemp -d ${root}/x); echo "$SCRATCH"`, [root]), null);
    assert.strictEqual(reaches('SCRATCH=$(mktemp -d /tmp/x); echo "$SCRATCH"', [root, '/tmp']), null);
  } finally { rmTmp(root); }
});

test('reaches: a standalone assignment statement whose substitution names git still reaches (planted negative -- R-git is out of scope here)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('tip=$(git rev-parse HEAD); echo "$tip"', [root]));
    assert.ok(reaches('WT=$(git rev-parse --show-toplevel); echo "$WT"', [root]));
  } finally { rmTmp(root); }
});

test('reaches: a standalone assignment statement whose substitution resolves outside every root still reaches (planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('D=$(mktemp -d /etc/x); echo "$D"', [root]));
  } finally { rmTmp(root); }
});

test('reaches: an env-assignment PREFIX to a real command in the same segment keeps today\'s behavior (planted negative, unchanged)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('V=$(git status) echo hi', [root]));
  } finally { rmTmp(root); }
});

test('reaches: the gh-read-verb assignment pattern (mined refusal family) is no longer reaching (R-var + gh-read + standalone-assignment combined)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(
      reaches('sha=$(gh pr view $n --repo owner/repo --json headRefOid --jq .headRefOid); echo "$sha"', [root]),
      null,
    );
  } finally { rmTmp(root); }
});

test('reaches: recurses into a bash -c / -lc payload', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('bash -c "cd /home/user/dotfiles"', [root]));
    assert.strictEqual(reaches('bash -c "echo p15b-ok"', [root]), null);
  } finally { rmTmp(root); }
});

test('reaches: an unquoted heredoc body is scanned for reach; a quoted one is opaque text', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('cat <<EOF\n$(git status)\nEOF', [root]));
    assert.strictEqual(reaches("cat <<'EOF'\n$(git status)\nEOF", [root]), null);
  } finally { rmTmp(root); }
});

// P1 index desync (adversarial review of PR #1295, finding 2): reachWords()
// tokenized a `<<<` here-string as a spurious `<<` op (the first two chars)
// followed by a lone `<` op, even though findHeredocs() correctly does not
// count `<<<` as a heredoc at all (the char after its own `<<` is another
// `<`, which can never become a delimiter). heredocOpToInfo maps each real
// `<<`/`<<-` op to findHeredocs()'s array by a SEQUENTIAL counter, so that
// spurious `<<` shifted every later heredoc's quoted/unquoted record by one.
// A `<<<` before an interpreter's own heredoc(s) therefore mapped the
// interpreter's UNQUOTED (expansion-capable, so not inert data) heredoc to
// the NEXT heredoc's quoted record, making the interp carve-out treat a
// reaching command as non-reaching -- a regression versus main, where this
// exact command stayed reaching (the interp carve-out did not exist yet).
// Fixed by giving `<<<` its own distinct op token in reachWords(), so it
// never satisfies the `<<`/`<<-` op check heredocOpToInfo keys on.
test('reaches: a <<< here-string before a heredoc-fed interpreter does not desync heredocOpToInfo (index desync, interp family)', () => {
  const { root } = mkWorktree();
  try {
    // cat's <<<"hi" is not a real heredoc at all (findHeredocs excludes it);
    // python3's own FIRST heredoc (<<EOF) is UNQUOTED, so it is not inert --
    // the whole call must still reach through the interp carve-out.
    assert.ok(reaches("cat <<<\"hi\"; python3 - <<EOF <<'TAG2'\nDANGER\nEOF\nignored\nTAG2", [root]));
  } finally { rmTmp(root); }
});

test('reaches: a here-string-only positive is unaffected by the <<< tokenizer fix -- a plain output-only $var argument fed via <<< does not reach (index desync, no-path variables)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('tr a-z A-Z <<< "$x"', [root]), null);
  } finally { rmTmp(root); }
});

// P0 (ce-code-review round on 2b279d2, finding #1): a quoted `<<`/`<<-`
// heredoc body fed to a command with no explicit heredoc rule (ssh, psql,
// and every other stdin-reading client this hook does not name) used to be
// invisible end to end -- excluded from the generic token scan because it
// is a heredoc body, and never literal-scanned because only
// INLINE_INTERPRETERS gets that treatment. Default-deny closes this: any
// such command is now reaching outright. The first segment below is a
// genuinely rewritable shape (argument-position command substitution,
// present pre-#1273 too) paired in the SAME command with a second segment
// that feeds a quoted heredoc to ssh -- proof the default-deny fires
// per-segment, not just when the whole command is otherwise suspicious.
test('reaches: a quoted heredoc fed to a command with no explicit heredoc rule (ssh/psql) reaches outright by default, even alongside an otherwise-rewritable segment (P0, finding #1)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("echo $(basename foo) && ssh host <<'EOF'\ncat /etc/shadow\nEOF", [root]));
    assert.ok(reaches("psql -f - <<'SQL'\nselect 1;\nSQL", [root]));
  } finally { rmTmp(root); }
});

// The default-deny is scoped to `<<`/`<<-` only (finding #1's resolved
// design decision): `<<<` and plain `<` targets are ordinary tokens the
// generic-argument/redirect-target scan already covers, and an unquoted
// `<<`/`<<-` body is already unconditionally recursed into above. A quoted
// heredoc fed to a safe data sink (cat/tee/OUTPUT_ONLY_COMMANDS -- none of
// which execute their stdin as code, and whose own write targets are
// checked separately) is deliberately NOT reaching; this is the exact
// carve-out that keeps the two pre-existing green tests above (`cat
// <<'EOF'...`, `tr ... <<< "$x"`) passing.
test('reaches: the quoted-heredoc default-deny does not fire for a safe data sink (cat/tee/OUTPUT_ONLY_COMMANDS), planted negative (finding #1)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches("cat <<'EOF'\nharmless data\nEOF", [root]), null);
    assert.strictEqual(reaches(`tee ${root}/out.txt <<'EOF'\nharmless data\nEOF`, [root]), null);
    assert.strictEqual(reaches("echo hi <<'EOF'\nharmless data\nEOF", [root]), null);
  } finally { rmTmp(root); }
});

// The new dquote-in-curly heredoc shape (detectShapes trigger only, above)
// is re-judged by the SAME existing reach logic as any other heredoc: a
// safe sink (cat/tee) still reaches null via the pre-existing safe-sink
// carve-out, and a command with no explicit heredoc rule (ssh/psql) still
// gets a reason via the pre-existing default-deny (both unchanged by this
// fix, per the issue's acceptance criteria).
test('reaches: a quoted heredoc with a double quote nested in {} feeding a safe sink (cat/tee) still reaches null; feeding ssh/psql still returns a reason', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('cat <<\'EOF\'\n{"a": 1}\nEOF', [root]), null);
    assert.strictEqual(reaches(`tee ${root}/out.json <<'EOF'\n{"a": 1}\nEOF`, [root]), null);
    assert.ok(reaches('ssh host <<\'EOF\'\n{"a": 1}\nEOF', [root]));
    assert.ok(reaches('psql -f - <<\'SQL\'\n{"a": 1}\nSQL', [root]));
  } finally { rmTmp(root); }
});

// Planted negative from the issue: a redirect target OUTSIDE both the
// worktree root and /tmp is still denied by reach's pre-existing generic
// redirect-target check, regardless of the new heredoc-body shape or the
// safe-sink carve-out -- a rewrite that skipped the reach check here would
// escape the worktree.
test('reaches: a dquote-in-curly heredoc feeding a safe sink is still denied when its OWN redirect target is outside every root and /tmp (planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('cat <<\'EOF\' > /home/user/x.json\n{"a": 1}\nEOF', [root]));
  } finally { rmTmp(root); }
});

// The SHELLS residual (bash/sh/zsh/dash/ksh, below) and the interpreter
// residual (python3/node/perl/ruby fed on bare "-", INLINE_INTERPRETERS)
// already detect and unconditionally deny a heredoc-fed shell/interpreter
// regardless of quoting or body content -- this fix must not change that
// outcome for either family, even though detectShapes now also adds
// "heredoc" alongside "bareexec"/"interp" for these commands (the OUTCOME,
// not the shape-name set, is the contract here).
test('reaches: a dquote-in-curly heredoc fed to bash or python3 still reaches outright, unchanged (SHELLS/interpreter residual, planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('bash <<\'EOF\'\n{"a": 1}\nEOF', [root]));
    assert.ok(reaches('python3 - <<\'EOF\'\n{"a": 1}\nEOF', [root]));
  } finally { rmTmp(root); }
});

// #1365 acceptance: the single-quote body is judged by the same reach logic.
// Into cat/tee under the worktree, /tmp, or ~/.claude/jobs it is rewritable;
// fed to a shell, an interpreter on stdin, or a command with no heredoc rule,
// or redirected outside every root, it still reaches.
test('reaches: a single quote inside {} gets the same reach verdicts as a double quote (#1365)', () => {
  const { root } = mkWorktree();
  // The roots run() passes: worktree, os.tmpdir(), and ~/.claude/jobs.
  const tmp = fs.realpathSync(os.tmpdir());
  const jobsDir = path.join(os.homedir(), '.claude', 'jobs');
  const roots = [root, tmp, jobsDir];
  try {
    assert.strictEqual(reaches("cat <<'EOF'\n{'a': 1}\nEOF", roots), null);
    assert.strictEqual(reaches(`tee ${root}/d.json <<'EOF'\n{'a': 1}\nEOF`, roots), null);
    assert.strictEqual(reaches(`cat <<'EOF' > ${tmp}/srt-1365.json\n{'a': 1}\nEOF`, roots), null);
    assert.strictEqual(reaches(`cat <<'EOF' > ${jobsDir}/srt-1365/tmp/d.json\n{'a': 1}\nEOF`, roots), null);
    assert.ok(reaches("bash <<'EOF'\n{'a': 1}\nEOF", roots));
    assert.ok(reaches("python3 - <<'EOF'\nd = {'a': 1}\nEOF", roots));
    assert.ok(reaches("ssh host <<'EOF'\n{'a': 1}\nEOF", roots));
    assert.ok(reaches("cat <<'EOF' > /etc/srt-1365.json\n{'a': 1}\nEOF", roots));
    assert.ok(reaches("tee /etc/srt-1365.json <<'EOF'\n{'a': 1}\nEOF", roots));
  } finally { rmTmp(root); }
});

// The scratch-file idiom the && redirect trigger now detects is rewritable
// only while both halves stay inside the roots.
test('reaches: mkdir -p d && cat > d/f <<\'EOF\' is rewritable inside the roots and reaches outside them (#1365)', () => {
  const { root } = mkWorktree();
  const tmp = fs.realpathSync(os.tmpdir());
  const roots = [root, tmp];
  try {
    assert.strictEqual(reaches(`mkdir -p ${tmp}/srt-d && cat > ${tmp}/srt-d/a.sh <<'EOF'\necho hi\nEOF`, roots), null);
    assert.strictEqual(reaches(`mkdir -p ${root}/d && cat > ${root}/d/a.txt <<'EOF'\nhello\nEOF`, roots), null);
    assert.ok(reaches("mkdir -p /etc/srt-d && cat > /etc/srt-d/a.txt <<'EOF'\nhello\nEOF", roots));
    assert.ok(reaches(`mkdir -p ${tmp}/srt-d && cat > /etc/srt-a.txt <<'EOF'\nhello\nEOF`, roots));
    assert.ok(reaches(`mkdir -p ${tmp}/srt-d && bash > ${tmp}/srt-d/o.txt <<'EOF'\necho hi\nEOF`, roots));
  } finally { rmTmp(root); }
});

// A shell in SHELLS (bash/sh/zsh/dash/ksh) fed by ANY heredoc -- quoted or
// unquoted -- is bash -c smuggling and reaches outright, full stop (finding
// #1's SHELLS residual). Unlike the generic default-deny, this does not
// wait on "is it quoted": an unquoted heredoc's LITERAL script body (no
// $()/backtick substitution to trip the top-level recursive scan) would
// otherwise run unaudited.
test('reaches: a heredoc fed to a shell (bash/sh/zsh) reaches outright regardless of quoting (finding #1, SHELLS residual)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("bash <<'EOF'\necho hi\nEOF", [root]));
    assert.ok(reaches('bash <<EOF\necho hi\nEOF', [root]));
    assert.ok(reaches("sh <<-'EOF'\n\techo hi\n\tEOF", [root]));
  } finally { rmTmp(root); }
});

// `<<-` (the dash-heredoc form, whose terminator may be indented with tabs)
// must tokenize and map through heredocOpToInfo identically to `<<` -- a
// tokenizer lock-in test so a future change to op parsing cannot silently
// stop recognising `<<-` as a heredoc op.
test('reaches: <<- (dash-heredoc) is recognised identically to << for both the default-deny and the safe-sink exception (finding #1, tokenizer lock-in)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("ssh host <<-'EOF'\n\tcat /etc/shadow\n\tEOF", [root]));
    assert.strictEqual(reaches("cat <<-'EOF'\n\tharmless data\n\tEOF", [root]), null);
  } finally { rmTmp(root); }
});

// Finding #12: hasInterpStdinShape (detectShapes' shape test) and
// reachesWithin's own carve-out predicate used to be two independently
// tokenized copies of the same "bare `-` argument, no other program-bearing
// operand" rule. A segment with TWO heredocs feeding the same interpreter
// call (one is the delimiter word for the FIRST op, which must be excluded
// from the "other operand" scan, exactly the case the shared predicate now
// computes once) exercises both call sites against the identical shape.
// F1 (adversarial review of PR #1295 round 6): the reach outcome below
// flipped from null to reaching when the carve-out this shape used to feed
// was reverted outright -- shape DETECTION (hasInterpStdinShape, still
// unified per finding #12) is unaffected and still classifies this segment
// as 'interp'; only the downstream reach decision for that shape changed.
test('reaches: a segment with two heredocs feeding one interpreter call classifies identically via the shared shape predicate (finding #12)', () => {
  const { root } = mkWorktree();
  try {
    assert.deepStrictEqual(
      detectShapes("python3 - <<'EOF' <<'TAG2'\nprint(1)\nEOF\nignored\nTAG2"),
      ['interp'],
    );
    assert.ok(reaches("python3 - <<'EOF' <<'TAG2'\nprint(1)\nEOF\nignored\nTAG2", [root]));
  } finally { rmTmp(root); }
});

// Finding #1 (adversarial review of PR #1295 round 3): reachesWithin()
// analyzed each pipe-separated segment in isolation, with no memory of
// whether a segment's stdin came from a preceding real `|`. A bare,
// argument-less `bash`/`sh` fed via a pipe reads that piped stdin as its
// own script -- identical in effect to the -c-payload and heredoc-fed
// cases already covered above -- so `echo '<payload>' | bash` and the
// "safe sink" variant `cat <<'EOF' | bash` (cat/tee/OUTPUT_ONLY_COMMANDS
// are exempt from the heredoc-body scan on the premise they never execute
// their own stdin, which stays true here -- it's the SECOND segment, fed
// BY that stdout, that executes it) both bypassed every reach check.
// `segment()` now returns `{ tokens, pipedStdin }` per segment, tracking
// whether a real `|` (never `||`, which chains on exit status) immediately
// preceded it. Live red evidence (captured before this fix, in-session):
// both `reaches()` calls below returned `null` against dfc75de.
test('reaches: a bare shell fed via a real pipe reads that stdin as its own script and reaches outright (finding #1)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("echo $(basename x) && echo 'touch /etc/PWNED' | bash", [root]));
    assert.ok(reaches("cat <<'EOF' | bash\ntouch /etc/PWNED\nEOF\n", [root]));
  } finally { rmTmp(root); }
});

// Planted negatives for finding #1: a shell fed a REAL positional
// script-file argument, or an explicit `-c` payload, does not read piped
// stdin as its program -- the pipe's presence alone must not overreach.
test('reaches: a piped shell with a real script-file argument or an explicit -c payload is unaffected by the finding #1 fix (planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('echo x | bash script.sh', [root]), null);
    assert.strictEqual(reaches("echo x | bash -c 'echo hi'", [root]), null);
  } finally { rmTmp(root); }
});

// Finding #1's INLINE_INTERPRETERS residual: the same "reads piped stdin as
// its own program" gap applies to a zero-argument interpreter (`python3`
// with no `-`/-c/heredoc at all) fed via a pipe -- isInterpStdinArgShape()
// requires an explicit bare `-` token and returns false for a wholly empty
// argument list, so a bare `python3` fell through every existing check.
test('reaches: a zero-argument interpreter fed via a real pipe reads that stdin as its program and reaches outright (finding #1, INLINE_INTERPRETERS residual)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("echo 'import os; os.system(\"touch /etc/PWNED\")' | python3", [root]));
    assert.strictEqual(reaches('echo x | python3 script.py', [root]), null);
  } finally { rmTmp(root); }
});

// Finding #2 (adversarial review of PR #1295 round 3): ghApiIsReadOnly()
// only recognized write-shapedness via literal flag text; a bare shell
// variable in argument position (`$FLAG`) is never tokenized as dynamic by
// this codebase's own reachWords(), so it read as inert literal text,
// exempting the whole call (and, via ghNoPath, its OTHER unresolved
// arguments too) from every reach check. Live red evidence (captured this
// session against a frozen dfc75de snapshot): `reaches()` below returned
// `null` before the fix.
test('reaches: a bare shell variable as a gh api argument is treated as write-shaped, unconditionally (finding #2)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('for n in 1 2; do gh api repos/x/y/issues/$n $FLAG; done', [root]));
  } finally { rmTmp(root); }
});

// Findings #3/#6 (adversarial review of PR #1295 round 3): the old gh
// dispatch only hardcoded two literal verb pairs (`pr checkout`,
// `repo clone`/`repo sync`) as unconditionally reaching; every OTHER verb
// -- including gh's own real built-in alias `co` (for `pr checkout`) and a
// case where an interposed unrecognized global flag shifts the anchored
// subcommand position (finding #6, REFUTED as independently exploitable
// with real gh syntax, but sharing the exact same root cause) -- fell
// through to the generic per-argument scan and read as safe whenever every
// argument was a resolvable literal. ghReachesOutright() replaces the
// hardcoded pair check: any verb not positively recognized as a read shape
// (GH_READ_VERB_PAIRS) is write-shaped, unconditionally, closing both at
// once in the shared resolver rather than growing an alias table the next
// alias would defeat. Live red evidence (captured this session against a
// frozen dfc75de snapshot): both `reaches()` calls below returned `null`
// before the fix.
test('reaches: an unrecognized gh verb -- including gh\'s own "co" alias and an anchor shifted by an interposed unrecognized flag -- is write-shaped, unconditionally (findings #3/#6)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('X=$(pwd); gh co 123', [root]));
    assert.ok(reaches('X=$(pwd); gh --bogus zzz pr checkout 123', [root]));
  } finally { rmTmp(root); }
});

// Finding #4 (adversarial review of PR #1295 round 3): SEGMENT_HEAD_KEYWORDS
// stripping (`do`/`then`/`else`/`elif`) used to run on wordLiteralText(),
// which strips quote characters before the keyword-set test -- so a REAL,
// quoted command literally named `do` or `then` (verified against real
// bash: `"do" echo hi` execs a program named `do`, unlike the unquoted
// syntax-error form) was misread as loop/if-keyword noise and stripped,
// leaving the actual command name one slot later misclassified. Only a
// genuinely UNQUOTED occurrence is ever real shell syntax and safe to
// strip; reachWords() now tags each word's `quoted` flag and
// stripWordWrappers() only strips when that flag is false. Live red
// evidence (captured this session against a frozen dfc75de snapshot): both
// `reaches()` calls below returned `null` before the fix.
test('reaches: a quoted "do"/"then" command name is not stripped as a loop/if keyword (finding #4)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('X=$(pwd); "do" echo $SECRET_PATH', [root]));
    assert.ok(reaches('X=$(pwd); "then" echo $SECRET_PATH', [root]));
  } finally { rmTmp(root); }
});

// Planted negative for finding #4: a genuinely UNQUOTED `do`/`then` inside
// real loop/if syntax must keep stripping exactly as before -- the fix is
// scoped to quoting, not to disabling the strip.
test('reaches: an unquoted do/then inside real loop/if syntax keeps stripping as before (finding #4, planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('for n in 1 2; do gh pr view $n; done', [root]), null);
  } finally { rmTmp(root); }
});

// Finding #1 (adversarial review of PR #1295 round 5), same defect class as
// round 4's finding #2: ghApiIsReadOnly()'s per-argument scan resolved a
// word carrying a $(...) command substitution to `null` via litAt() and
// then silently `continue`d past it, instead of failing closed the same way
// it already did for a bare $VAR/${VAR} word in the identical position --
// `--$(echo field)=x` and `-$(echo X) DELETE` are exactly as unresolvable at
// static-analysis time as a bare variable, just spelled differently. A
// LITERAL path segment isolates this from the separate (and already-covered)
// unresolved-path-variable check below it. Live red evidence (this session,
// against a real pre-round-5 snapshot read via `git show HEAD:...` for both
// shape-rewrite.js and lib/shape-rewrite-reach.js): both reaches() calls
// below returned `null` before the fix.
test('reaches: gh api write-flag detection is not defeated by wrapping the flag in command substitution (finding #1)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('gh api repos/o/r/issues/5 --$(echo field)=malicious-value', [root]));
    assert.ok(reaches('gh api repos/o/r/issues/5 -$(echo X) DELETE', [root]));
  } finally { rmTmp(root); }
});

// The findings.md end-to-end repro: an UNRESOLVED $n path segment, combined
// with the obfuscated flag. Before the fix, ghApiIsReadOnly() wrongly
// returned true for the obfuscated-flag call, which made ghNoPathSegment
// true and threaded noPathOverride=true into checkPathWord for every word in
// the segment -- exempting even the unresolved $n from the unresolved-
// variable path check that would otherwise have caught it on its own. Live
// red evidence (this session, same pre-round-5 snapshot): returned `null`
// before the fix.
test('reaches: gh api $()-obfuscated write flag does not also exempt an unresolved path variable in the same call (finding #1, end-to-end)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('gh api repos/o/r/issues/$n --$(echo field)=malicious-value', [root]));
  } finally { rmTmp(root); }
});

// Finding #2 (adversarial review of PR #1295 round 5): the round-3 finding
// #1 piped-stdin default-deny proves a real script-file argument is present
// by checking for any non-flag word -- but `/dev/stdin` (and `/dev/fd/0`,
// `/proc/self/fd/0`) IS the piped stdin, just spelled as an operand, and was
// independently allowlisted in DEVICE_ALLOW besides, so it passed the
// "has an operand" test and skipped the piped-stdin check entirely. Live red
// evidence (this session, pre-round-5 snapshot): both reaches() calls below
// returned `null`, and detectShapes() returned `[]`, before the fix.
test('reaches: piped-stdin default-deny is not defeated by /dev/stdin as the explicit script argument (finding #2)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("echo 'touch pwned-outside' | bash /dev/stdin", [root]));
    assert.ok(reaches("echo 'import os; os.system(1)' | python3 /dev/stdin", [root]));
    assert.deepStrictEqual(detectShapes("echo 'touch pwned-outside' | bash /dev/stdin"), ['bareexec']);
  } finally { rmTmp(root); }
});

// Planted negative for finding #2: a stdin-alias path PLUS a genuine second
// operand is not the piped-stdin-as-script shape at all (there IS a real
// operand, the alias path is just an incidental extra one) and must stay
// unaffected in both the old and new code.
test('reaches: /dev/stdin alongside a genuine second operand is unaffected by the finding #2 fix (planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('echo x | bash /dev/stdin real.sh', [root]), null);
  } finally { rmTmp(root); }
});

// Finding #3 (adversarial review of PR #1295 round 5), same defect class as
// finding #2 above (a guard that checks only the bare/unwrapped form):
// segment()'s curPipedStdin tracking unconditionally reset to
// `e.value === '|'` on every SHELL_CHAIN_OPS transition, including `(`/`)`
// -- themselves chain-op members for segmentation purposes but structurally
// transparent grouping punctuation, not a fresh command boundary. `cmd |
// (bash)` clobbered the just-set pipedStdin=true back to false the instant
// it saw `(`, so the wrapped bash segment evaluated as if it started fresh.
// Live red evidence (this session, pre-round-5 snapshot): both reaches()
// calls below returned `null` before the fix.
test('reaches: piped-stdin default-deny is not defeated by wrapping the shell/interpreter in a subshell group (finding #3)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("echo 'touch pwned-outside' | (bash)", [root]));
    assert.ok(reaches("echo 'x' | (python3)", [root]));
  } finally { rmTmp(root); }
});

// Finding #1 (adversarial review of PR #1295 round 7), a third instance of
// finding #3's defect class one level down: round 5 only stopped `(`/`)`
// themselves from clobbering a just-set pipedStdin=true -- it never modeled
// group NESTING, so any OTHER chain op inside that still-open group (`;`,
// `&&`, `||`, a bare `{ ...; }` group) hit the unconditional
// `curPipedStdin = e.value === '|'` reassignment and clobbered it anyway.
// `echo x | (true; bash)` associated `bash`'s segment with pipedStdin=false
// because the interior `;` reset the association before `bash` was ever
// reached -- worse than a wrong reach *reason*, detectShapes() returned only
// `['varmod']` for every case below: the 'bareexec' shape was never even
// detected, since hasBareExecShape() reads the same segment() output. Live
// red evidence (this session, against 246216b, via a temporary revert of
// this file's segment() back to the round-6 shipped version -- the
// coordinator's own independent repro, reproduced byte-for-byte):
//   reaches("echo ${HOME:-x}; echo 'id' | (true; bash)", [root])       -> null
//   reaches("echo ${HOME:-x}; echo 'id' | (: ; sh)", [root])           -> null
//   reaches("echo ${HOME:-x}; echo 'id' | (sleep 0; python3)", [root]) -> null
//   reaches("echo ${HOME:-x}; echo 'id' | { true; bash; }", [root])   -> null
//   reaches("echo ${HOME:-x}; echo 'id' | (true && bash)", [root])    -> null
//   detectShapes(...) for every line above -> ['varmod'] (no 'bareexec')
// segment() now tracks actual group-nesting depth (`(`/`)`, and a bare
// `{`/`}` command-group word -- `{`/`}` are never tokenized as an 'op' at
// all; only a whitespace-delimited standalone `{` or `}` word gets this
// treatment, which is exactly bash's own grouping syntax) plus the depth at
// which the current piped association was established, so a chain op only
// clears it once we're back at that same depth -- not still nested inside
// the group the pipe fed.
test('reaches: piped-stdin default-deny is not defeated by a multi-statement group after the pipe -- (;), (&&), and a bare {;} group (finding #1, round 7)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches("echo ${HOME:-x}; echo 'id' | (true; bash)", [root]));
    assert.ok(reaches("echo ${HOME:-x}; echo 'id' | (: ; sh)", [root]));
    assert.ok(reaches("echo ${HOME:-x}; echo 'id' | (sleep 0; python3)", [root]));
    assert.ok(reaches("echo ${HOME:-x}; echo 'id' | { true; bash; }", [root]));
    assert.ok(reaches("echo ${HOME:-x}; echo 'id' | (true && bash)", [root]));
    assert.deepStrictEqual(detectShapes("echo ${HOME:-x}; echo 'id' | (true; bash)"), ['bareexec', 'varmod']);
    assert.deepStrictEqual(detectShapes("echo ${HOME:-x}; echo 'id' | { true; bash; }"), ['bareexec', 'varmod']);
  } finally { rmTmp(root); }
});

// Planted negative for finding #1 (round 7): once the group that received
// the piped stdin actually CLOSES, a command after it (same depth, no
// longer nested) must not inherit the association -- only the interior of
// a still-open group is protected. Both bare bash forms (no operand, no
// pipe of their own) isolate the depth-reset logic specifically: with the
// association wrongly kept alive past the group's close, either would
// misreach exactly like the round-7 bug this fixes.
test('reaches: a command after a piped group closes does not inherit that group\'s piped-stdin association (finding #1, round 7, planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.strictEqual(reaches('echo x | (true); bash', [root]), null);
    assert.strictEqual(reaches('(echo x | true); bash', [root]), null);
  } finally { rmTmp(root); }
});

// Finding #5 (adversarial review of PR #1295 round 5): excludeHeredocBodies()
// fused the kept text before and after a heredoc's body with no separator --
// a heredoc immediately followed (next line, no chain operator) by a
// write-shaped command was concatenated into ONE unparseable word, hiding
// the trailing command from every downstream reach check entirely (not just
// misclassifying it: reachWords() never even sees "gh" as a separate token).
// This is the exact bug this doc (harness/worktree-command-shapes.md)
// previously described as "unrelated to finding #1's repro" and deferred as
// out of scope -- that framing is corrected in this same round's doc
// addendum. Live red evidence (this session, pre-round-5 snapshot): returned
// `null` before the fix.
test('reaches: a heredoc immediately followed by a write-shaped command is not glued into one inert word (finding #5)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('cat <<EOF\nharmless body\nEOF\ngh pr merge 123 --squash\n', [root]));
  } finally { rmTmp(root); }
});

// Controls for finding #5: the same trailing gh pr merge call already
// reached correctly with no heredoc present at all, and with an explicit `;`
// separator -- isolating the bug to the heredoc-glue path specifically,
// not to gh pr merge's own reach classification.
test('reaches: gh pr merge reaches on its own and with an explicit separator, isolating finding #5 to the heredoc-glue path (planted negative)', () => {
  const { root } = mkWorktree();
  try {
    assert.ok(reaches('gh pr merge 123 --squash', [root]));
    assert.ok(reaches('cat <<EOF\nharmless body\nEOF\n;gh pr merge 123 --squash\n', [root]));
  } finally { rmTmp(root); }
});

// Finding #6, correctness half (adversarial review of PR #1295 round 5):
// fixing hasInterpStdinShape()'s O(n^2) scaling (the finding's headline
// complaint) required a forward-pass segStart computation over
// findHeredocs()'s own per-heredoc records -- which surfaced a second,
// independent, pre-existing bug in findHeredocs() itself, not one of the
// six findings on its own but blocking this finding's own "near-linear
// scaling" verification goal: heredocs sharing one operator line
// (`cmd <<'A' <<'B'`) each recomputed their body-search start from the
// shared line's end instead of from where the PRECEDING heredoc's search
// actually stopped, so a later heredoc's terminator search could stop at a
// line inside an EARLIER heredoc's own still-open body that happens to
// match the later delimiter's text. Here, A's true body contains a line
// that reads exactly "B" -- with the bug, B's search (mis-)started at the
// very top of A's body and stopped at that embedded "B" line, corrupting
// B's parsed boundary so severely that the real `| bash` immediately after
// A's own true close became invisible to detectShapes()/reaches() entirely
// (not merely misclassified -- absent). Live red evidence (this session,
// pre-round-5 snapshot AND the isolated post-grouping-fix/pre-findHeredocs-fix
// snapshot): detectShapes() returned `[]` and reaches() returned `null`
// before the findHeredocs fix.
test('reaches: shared-line heredocs whose earlier body text collides with a later delimiter do not mask a trailing piped bash (finding #6, findHeredocs correctness)', () => {
  const { root } = mkWorktree();
  try {
    const cmd = "cat <<'A' <<'B' | bash\nfirst_of_A\nB\nsecond_of_A\nA\nreal_body_of_B\nB\n";
    assert.deepStrictEqual(detectShapes(cmd), ['bareexec']);
    assert.ok(reaches(cmd, [root]));
  } finally { rmTmp(root); }
});

// Finding #4 (adversarial review of PR #1295 round 5): detectShapes() had no
// signal at all for a bare shell/interpreter reading its own pipe or heredoc
// as its program, so `run()`'s `if (!shapes.length) return rawInput;` never
// even called reaches() for any of these six forms -- each is exactly one of
// the PR's own motivating live-red examples. This test asserts the actual,
// verified content of the fix: detectShapes() now includes 'bareexec' for
// all six, AND, once that gate opens, reaches()'s own pre-existing logic
// (unchanged by this finding) correctly classifies every one of them as
// reaching. It deliberately does NOT assert anything about run()'s final
// pass/reject action for these six inputs specifically: reachesWithin()
// judges every hasBareExecShape-covered form as reaching UNCONDITIONALLY
// (verified empirically, not assumed -- none of the six is path-dependent),
// so run() returns pass-through for them both before and after this fix,
// identically; the fix's live effect is closing the dead detectShapes()==[]
// gate itself (a prerequisite for reaches() to run at all, now and for any
// future, possibly path-conditional, addition to reachesWithin's rules for
// these shapes), not a changed outcome for these particular six commands.
test('detectShapes/reaches: bare shell/interpreter pipe-or-heredoc forms are no longer invisible to the reach-check pipeline (finding #4)', () => {
  const { root } = mkWorktree();
  try {
    const cases = [
      "cat <<'EOF' | bash\ntouch pwned\nEOF\n",
      "echo 'touch pwned' | bash",
      "echo 'import os' | python3",
      "ssh host <<'EOF'\ncat /etc/shadow\nEOF",
      "psql <<'EOF'\nselect 1;\nEOF",
      "bash -s <<'EOF'\necho hi\nEOF",
    ];
    for (const cmd of cases) {
      assert.deepStrictEqual(detectShapes(cmd), ['bareexec'], `detectShapes should flag: ${JSON.stringify(cmd)}`);
      assert.ok(reaches(cmd, [root]), `reaches should classify as reaching: ${JSON.stringify(cmd)}`);
    }
  } finally { rmTmp(root); }
});

// ===========================================================================
// U2: run — the PreToolUse rewrite entry point.
// ===========================================================================

// Cleans up after BOTH a synchronous callback (cleanup runs before returning)
// and an async one (cleanup waits for the promise to settle first) -- a plain
// try/finally around an async fn() would run rmTmp() immediately, since the
// finally block does not itself await the pending promise, deleting the
// scratch/worktree dirs while the spawned hook process is still using them.
function withScratch(fn) {
  const { root, wt } = mkWorktree();
  const scratch = mkTmp('shape-rw-scratch-');
  const cleanup = () => { rmTmp(scratch); rmTmp(root); };
  let result;
  try {
    result = fn({ root, wt, scratch });
  } catch (e) {
    cleanup();
    throw e;
  }
  if (result && typeof result.then === 'function') {
    return result.then(
      (v) => { cleanup(); return v; },
      (e) => { cleanup(); throw e; },
    );
  }
  cleanup();
  return result;
}

test('run: AE1 a plain command-substitution call is rewritten to bash <script>, script prints the receipt then runs the command', () => {
  withScratch(({ wt, scratch }) => {
    const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    const hso = out.hookSpecificOutput;
    assert.strictEqual(hso.hookEventName, 'PreToolUse');
    assert.strictEqual('permissionDecision' in hso, false);
    assert.ok(hso.permissionDecisionReason.includes('signature: guard_blocked:shape-rewrite:cmdsub'));
    assert.match(hso.updatedInput.command, /^bash .*shape-rewrite-cmdsub-toolu_01abc\.sh$/);
    const scriptPath = hso.updatedInput.command.slice('bash '.length);
    const body = fs.readFileSync(scriptPath, 'utf8');
    assert.ok(body.startsWith('#!/usr/bin/env bash\n'));
    assert.ok(body.includes(hso.permissionDecisionReason));
    assert.ok(body.trim().endsWith('echo $(date)'));
  });
});

test('run: AE6 a rewritten script executes and its stdout starts with the receipt line', () => {
  withScratch(({ wt, scratch }) => {
    const p = payload('echo hello-shape-rewrite', { cwd: wt, scratchpad_dir: scratch });
    // Force a shape via a harmless cmdsub wrapper so this exercises detection + execution together.
    p.tool_input.command = 'echo $(echo hello-shape-rewrite)';
    const out = JSON.parse(run(JSON.stringify(p)));
    const scriptPath = out.hookSpecificOutput.updatedInput.command.slice('bash '.length);
    const result = execFileSync('bash', [scriptPath], { encoding: 'utf8' });
    const lines = result.trimEnd().split('\n');
    assert.strictEqual(lines[0], out.hookSpecificOutput.permissionDecisionReason);
    assert.strictEqual(lines[1], 'hello-shape-rewrite');
  });
});

test('run: AE12 a silent-success original command produces only the receipt line when the script runs', () => {
  withScratch(({ wt, scratch }) => {
    // `true` is output-only (rewritable with a substitution argument) and prints nothing.
    const p = payload('true $(date)', { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    const scriptPath = out.hookSpecificOutput.updatedInput.command.slice('bash '.length);
    const result = execFileSync('bash', [scriptPath], { encoding: 'utf8' });
    assert.strictEqual(result, out.hookSpecificOutput.permissionDecisionReason + '\n');
  });
});

test('run: a heredoc in the original survives verbatim in the script body, including its delimiter', () => {
  withScratch(({ wt, scratch }) => {
    const cmd = "cat <<EOF\nline one\nline two\nEOF";
    const p = payload(cmd, { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    const scriptPath = out.hookSpecificOutput.updatedInput.command.slice('bash '.length);
    const body = fs.readFileSync(scriptPath, 'utf8');
    assert.ok(body.includes(cmd), 'the original heredoc text must appear byte-for-byte');
    const result = execFileSync('bash', [scriptPath], { encoding: 'utf8' });
    assert.ok(result.includes('line one\nline two'));
  });
});

// Semantics-preservation: the rewrite must not change what the command
// actually does. Runs the ORIGINAL command directly and the REWRITTEN
// `bash <script>` form the hook produces, and compares stdout byte for
// byte -- closing the stdin/quoting-semantics risk the issue names for a
// JSON-shaped heredoc body.
test('run: a quoted heredoc with a JSON body ({"a": 1}) is rewritten to bash <script>, and the rewritten form\'s stdout is byte-identical to the original command (semantics preservation)', () => {
  withScratch(({ wt, scratch }) => {
    const cmd = 'cat <<\'EOF\'\n{"a": 1}\nEOF';
    const original = execFileSync('bash', ['-c', cmd], { encoding: 'utf8' });
    const p = payload(cmd, { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    assert.ok(out.hookSpecificOutput, 'must be rewritten: the dquote-in-curly body is now a detected heredoc shape');
    assert.match(out.hookSpecificOutput.updatedInput.command, /^bash .*\.sh$/);
    const scriptPath = out.hookSpecificOutput.updatedInput.command.slice('bash '.length);
    const rewritten = execFileSync('bash', [scriptPath], { encoding: 'utf8' });
    const receiptLine = out.hookSpecificOutput.permissionDecisionReason;
    assert.ok(rewritten.startsWith(`${receiptLine}\n`), 'rewritten stdout must start with the receipt line');
    const rewrittenPayload = rewritten.slice(receiptLine.length + 1);
    assert.strictEqual(rewrittenPayload, original, 'rewritten script stdout (after the receipt line) must match the original command byte for byte');
  });
});

// #1365: a Python body whose only quote inside {} is a single quote (the
// double-quoted "it's" sits outside the braces, so the old double-quote
// predicate never fired on it), rewritten and run, prints the same bytes.
test('run: a quoted heredoc with a single-quoted dict body is rewritten, and its stdout is byte-identical to the original (#1365)', () => {
  withScratch(({ wt, scratch }) => {
    const cmd = "cat <<'EOF'\nd = {'a': 1}\nprint(\"it's\")\nEOF";
    const original = execFileSync('bash', ['-c', cmd], { encoding: 'utf8' });
    const out = JSON.parse(run(JSON.stringify(payload(cmd, { cwd: wt, scratchpad_dir: scratch }))));
    assert.ok(out.hookSpecificOutput, 'must be rewritten: a single quote inside {} is a detected heredoc shape');
    const scriptPath = out.hookSpecificOutput.updatedInput.command.slice('bash '.length);
    const rewritten = execFileSync('bash', [scriptPath], { encoding: 'utf8' });
    const receiptLine = out.hookSpecificOutput.permissionDecisionReason;
    assert.strictEqual(rewritten, `${receiptLine}\n${original}`);
  });
});

// #1365: the scratch-file idiom, rewritten and run, writes the same bytes.
test('run: mkdir -p d && cat > d/f <<\'EOF\' under the worktree is rewritten and writes byte-identical content (#1365)', () => {
  withScratch(({ wt, scratch }) => {
    const body = "#!/usr/bin/env bash\necho \"it's $HOME\" `date`\n";
    const cmd = (dir) => `mkdir -p ${dir} && cat > ${dir}/a.sh <<'EOF'\n${body}EOF`;
    const origDir = path.join(wt, 'orig');
    execFileSync('bash', ['-c', cmd(origDir)]);
    const newDir = path.join(wt, 'new');
    const out = JSON.parse(run(JSON.stringify(payload(cmd(newDir), { cwd: wt, scratchpad_dir: scratch }))));
    assert.ok(out.hookSpecificOutput, 'must be rewritten: a redirect before << after && is a detected heredoc shape');
    execFileSync('bash', [out.hookSpecificOutput.updatedInput.command.slice('bash '.length)]);
    assert.strictEqual(fs.readFileSync(path.join(newDir, 'a.sh'), 'utf8'), fs.readFileSync(path.join(origDir, 'a.sh'), 'utf8'));
    assert.strictEqual(fs.readFileSync(path.join(newDir, 'a.sh'), 'utf8'), body);
  });
});

// Same semantics-preservation check, but with a redirect into a file under
// the worktree instead of stdout -- the safe-sink carve-out covers `cat`'s
// argv but the ACTUAL bytes written on disk must still match too.
test('run: a quoted JSON-body heredoc redirected into a file under the worktree writes byte-identical content before and after the rewrite (semantics preservation)', () => {
  withScratch(({ wt, scratch }) => {
    const origTarget = path.join(wt, 'orig.json');
    const rewrittenTarget = path.join(wt, 'rewritten.json');
    const cmdFor = (target) => `cat <<'EOF' > ${target}\n{"a": 1}\nEOF`;
    execFileSync('bash', ['-c', cmdFor(origTarget)]);
    const p = payload(cmdFor(rewrittenTarget), { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    assert.ok(out.hookSpecificOutput, 'must be rewritten: cat is a safe sink and the redirect target is inside the worktree root');
    const scriptPath = out.hookSpecificOutput.updatedInput.command.slice('bash '.length);
    execFileSync('bash', [scriptPath]);
    assert.strictEqual(fs.readFileSync(rewrittenTarget, 'utf8'), fs.readFileSync(origTarget, 'utf8'));
  });
});

test('run: AE4 a command that reaches outside the roots (git) is left as pass-through, not rewritten', async () => {
  await withScratch(async ({ wt, scratch }) => {
    const p = payload('git commit -m "$(cat /home/user/dotfiles/CLAUDE.md)"', { cwd: wt, scratchpad_dir: scratch });
    assertQuietPassThrough(await runHook(HOOK, p));
  });
});

test('run: an echo-led multi-line command with a variable path on a later line is left as pass-through (#1317)', async () => {
  await withScratch(async ({ wt, scratch }) => {
    const p = payload('echo "$(date)"\nrm -rf "$TARGET"', { cwd: wt, scratchpad_dir: scratch });
    assertQuietPassThrough(await runHook(HOOK, p));
  });
});

test('run: a generated script piped past a comment into bash on the next line is left as pass-through (#1317 review)', async () => {
  await withScratch(async ({ wt, scratch }) => {
    const p = payload('printf \'%s\' "$(printf \'rm -rf /etc/x\')" | # run it\nbash', { cwd: wt, scratchpad_dir: scratch });
    assertQuietPassThrough(await runHook(HOOK, p));
  });
});

test('run: a command with no refused shape is left as pass-through', async () => {
  await withScratch(async ({ wt, scratch }) => {
    const p = payload('echo hello', { cwd: wt, scratchpad_dir: scratch });
    assertQuietPassThrough(await runHook(HOOK, p));
  });
});

test('run: SHAPE_REWRITE_DISABLE=1 in the hook process env disables rewriting entirely', async () => {
  await withScratch(async ({ wt, scratch }) => {
    const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: scratch });
    assertQuietPassThrough(await runHook(HOOK, p, { env: { SHAPE_REWRITE_DISABLE: '1' } }));
  });
});

test('run: SHAPE_REWRITE_DISABLE=1 appearing only in the COMMAND TEXT does not disable anything', () => {
  withScratch(({ wt, scratch }) => {
    const p = payload('SHAPE_REWRITE_DISABLE=1 echo $(date)', { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    assert.ok(out.hookSpecificOutput, 'must still rewrite: only the process env disables, never command text');
  });
});

test('run: an unwritable scratch directory is a pass-through, not a crash', async () => {
  await withScratch(async ({ wt, scratch }) => {
    fs.chmodSync(scratch, 0o500);
    try {
      const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: scratch });
      assertQuietPassThrough(await runHook(HOOK, p));
    } finally {
      fs.chmodSync(scratch, 0o700);
    }
  });
});

test('run: a scratch path containing whitespace is a pass-through (the unquoted `bash <path>` form would split)', async () => {
  await withScratch(async ({ wt, scratch }) => {
    const spaced = path.join(scratch, 'has space');
    fs.mkdirSync(spaced, { recursive: true });
    const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: spaced });
    assertQuietPassThrough(await runHook(HOOK, p));
    assert.deepStrictEqual(fs.readdirSync(spaced), [], 'no script file is written for a whitespace path');
  });
});

test('run: falls back to $CLAUDE_JOB_DIR/tmp when the input has no scratchpad_dir', async () => {
  await withScratch(async ({ wt, scratch }) => {
    const jobDir = path.join(scratch, 'job-1');
    const p = payload('echo $(date)', { cwd: wt });
    delete p.scratchpad_dir;
    const res = await runHook(HOOK, p, { env: { CLAUDE_JOB_DIR: jobDir } });
    const out = JSON.parse(res.stdout);
    assert.ok(out.hookSpecificOutput, 'expected a rewrite using $CLAUDE_JOB_DIR/tmp');
    assert.ok(out.hookSpecificOutput.updatedInput.command.includes(path.join(jobDir, 'tmp')));
  });
});

test('run: with neither scratchpad_dir nor $CLAUDE_JOB_DIR set, the hook passes through', async () => {
  await withScratch(async ({ wt }) => {
    const p = payload('echo $(date)', { cwd: wt });
    delete p.scratchpad_dir;
    const env = { ...process.env };
    delete env.CLAUDE_JOB_DIR;
    assertQuietPassThrough(await runHook(HOOK, p, { env: { CLAUDE_JOB_DIR: '' } }));
  });
});

test('run: a command near the argv-length ceiling is written into the script whole (byte-exact)', () => {
  withScratch(({ wt, scratch }) => {
    const filler = 'x'.repeat(50000);
    const cmd = `echo $(date) ${filler}`;
    const p = payload(cmd, { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    const scriptPath = out.hookSpecificOutput.updatedInput.command.slice('bash '.length);
    const body = fs.readFileSync(scriptPath, 'utf8');
    assert.ok(body.endsWith(cmd + '\n'), 'the long command must be reproduced byte-for-byte, not truncated');
  });
});

test('run: the 24-hour prune removes an old shape-rewrite- file and leaves a fresh one and an unrelated file alone', () => {
  withScratch(({ wt, scratch }) => {
    const oldFile = path.join(scratch, 'shape-rewrite-cmdsub-toolu_stale.sh');
    const freshFile = path.join(scratch, 'shape-rewrite-cmdsub-toolu_fresh.sh');
    const unrelated = path.join(scratch, 'notes.txt');
    fs.writeFileSync(oldFile, '#!/usr/bin/env bash\necho old\n');
    fs.writeFileSync(freshFile, '#!/usr/bin/env bash\necho fresh\n');
    fs.writeFileSync(unrelated, 'keep me');
    const old25h = Date.now() / 1000 - 25 * 3600;
    fs.utimesSync(oldFile, old25h, old25h);
    fs.utimesSync(unrelated, old25h, old25h);

    const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: scratch });
    run(JSON.stringify(p));

    assert.strictEqual(fs.existsSync(oldFile), false, 'old shape-rewrite- file must be pruned');
    assert.strictEqual(fs.existsSync(freshFile), true, 'fresh shape-rewrite- file must survive');
    assert.strictEqual(fs.existsSync(unrelated), true, 'a non-shape-rewrite- file must never be pruned');
  });
});

test('run: AE9 sibling precedence — shape-rewrite alone passes the git-bearing call through (its own reach check finds "git")', async () => {
  // Plan text (U2 test scenarios): "the cross-hook precedence itself is the
  // live sibling-precedence probe, not a harness test" -- git-guard's SIDE of
  // AE9 needs a real git repository to evaluate branch state and is exercised
  // by git-guard's own suite plus the live probe, not duplicated here.
  await withScratch(async ({ wt, scratch }) => {
    const p = payload('git commit -m "$(cat /home/user/dotfiles/CLAUDE.md)"', { cwd: wt, scratchpad_dir: scratch });
    assertQuietPassThrough(await runHook(HOOK, p));
  });
});

test('run: a command outside any .claude/worktrees/<name> cwd is left as pass-through (KTD3 isolation proxy)', async () => {
  const dir = mkTmp('shape-rw-notworktree-');
  try {
    const p = payload('echo $(date)', { cwd: dir, scratchpad_dir: mkTmp('shape-rw-scratch2-') });
    assertQuietPassThrough(await runHook(HOOK, p));
  } finally { rmTmp(dir); }
});

test('run: the script file is written with owner-only permissions', () => {
  withScratch(({ wt, scratch }) => {
    const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    const scriptPath = out.hookSpecificOutput.updatedInput.command.slice('bash '.length);
    const mode = fs.statSync(scriptPath).mode & 0o777;
    assert.strictEqual(mode, 0o600);
  });
});

test('run: a scratch-path collision (the tool_use_id-derived script path already exists) fails open and leaves the existing file untouched (finding #13)', () => {
  withScratch(({ wt, scratch }) => {
    const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: scratch });
    // Same shapeName ("cmdsub") + same default tool_use_id ("toolu_01abc")
    // as payload()'s default -> the exact scriptPath run() will compute.
    const scriptPath = path.join(scratch, 'shape-rewrite-cmdsub-toolu_01abc.sh');
    const preexisting = '#!/usr/bin/env bash\necho pre-existing-script-content\n';
    fs.writeFileSync(scriptPath, preexisting, { mode: 0o600 });
    const rawInput = JSON.stringify(p);
    const out = run(rawInput);
    assert.strictEqual(out, rawInput, 'a colliding scratch path must fail open (pass-through), never rewrite');
    assert.strictEqual(fs.readFileSync(scriptPath, 'utf8'), preexisting, 'the pre-existing script content must be left untouched');
  });
});

test('run: the rewrite JSON has no permissionDecision field at all (rewrite, not allow/deny)', () => {
  withScratch(({ wt, scratch }) => {
    const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: scratch });
    const out = JSON.parse(run(JSON.stringify(p)));
    assert.strictEqual('permissionDecision' in out.hookSpecificOutput, false);
  });
});

test('run: a rewrite logs a shape-rewrite:<shapes> friction record with the matching signature', () => {
  withScratch(({ root, wt, scratch }) => {
    const store = mkTmp('shape-rw-papercut-');
    try {
      const p = payload('echo $(date)', { cwd: wt, scratchpad_dir: scratch, session_id: 'sess-friction-abcd1234' });
      const oldEnv = process.env.PAPERCUT_STORE;
      process.env.PAPERCUT_STORE = store;
      try {
        run(JSON.stringify(p));
      } finally {
        if (oldEnv === undefined) delete process.env.PAPERCUT_STORE; else process.env.PAPERCUT_STORE = oldEnv;
      }
      const f = path.join(store, `${projectSlug(wt)}.jsonl`);
      const recs = fs.readFileSync(f, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
      assert.strictEqual(recs.length, 1);
      assert.strictEqual(recs[0].sig, 'guard_blocked:shape-rewrite:cmdsub');
    } finally { rmTmp(store); }
  });
});

// The run() scaling guard's sizes. Pro-gate round 2 on PR #1839 (2026-10-16,
// run 38971417579): sampling 100 lines, the small median was 18.6 CPU ms and
// the 400-line median 120 ms, 6.449x against the 6x bound, on a light-lane
// runner where the hooks suite took the same 63 s as main's green run at the
// PR's base and the reaches() heredoc guard below ran faster. Nothing on
// run()'s path is superlinear: reaches() costs 0.07-0.11 CPU ms per line
// from 400 to 6400 lines, flat. The other guards in this file sample 2000
// and 25000 lines; this one sampled 100, the family's only sub-20 ms small
// sample, where one cache-cold or descheduled trial moves a 7-sample median.
// Both sizes now sit in the flat-slope regime (medians 34-41 and 138-165 CPU
// ms here, ratio 3.4-4.0 quiet and 3.1-4.4 under a 28-wide memory-thrashing
// load); the 4x scale and the 6x bound are unchanged.
const RUN_REWRITE_GUARD = { n: 400, scale: 4, maxRatio: 6 };
const FLAT_SLOPE_FROM_LINES = 400;

test('run: the scaling guard samples in the flat-slope regime with its 4x scale and 6x bound unchanged (pro-gate round 2 on #1839)', () => {
  assert.ok(
    RUN_REWRITE_GUARD.n >= FLAT_SLOPE_FROM_LINES,
    `the small sample must be at least ${FLAT_SLOPE_FROM_LINES} lines, where run()'s per-line cost is flat; got ${RUN_REWRITE_GUARD.n}`,
  );
  assert.strictEqual(RUN_REWRITE_GUARD.scale, 4, 'the scale is the one the 6x bound was set for');
  assert.strictEqual(RUN_REWRITE_GUARD.maxRatio, 6, 'the bound is not widened: 4x input must stay under 6x cost');
});

test('run: in-process rewrites scale near-linearly with command count (excluding node startup)', () => {
  withScratch(({ wt, scratch }) => {
    // There is no registered 50ms limit; the hard hook timeout is 5s.
    // run() is synchronous (including its fs calls) and spawns nothing.
    // Unique IDs make EVERY sample write a rewrite instead of measuring
    // the old warmup's scratch-path-collision fallback on its second call.
    // Unlike the other guards, run() sweeps, mkdirs, realpaths and WRITES
    // the scratch script: synchronous I/O whose blocked time CPU
    // measurement cannot see, while the external 5 s timeout is wall clock
    // and fires regardless (Pro round 2 P1). wallSanityMs binds every
    // sample's wall time; 1 s of the 5 s is reserved for the node startup
    // and module load the in-process measurement excludes (~20 ms here).
    let id = 0;
    assertPerfScaling({
      ...RUN_REWRITE_GUARD,
      sanityMs: 5000,
      wallSanityMs: 4000,
      label: 'run() command-substitution rewrites',
      measure: (n) => {
        const p = payload('echo $(date)\n'.repeat(n), {
          cwd: wt,
          scratchpad_dir: scratch,
          tool_use_id: `toolu_perf_${id++}`,
        });
        const raw = JSON.stringify(p);
        const { result, elapsedMs } = measureCpu(() => run(raw), {
          cpuClock: true,
        });
        assert.notStrictEqual(
          result,
          raw,
          'every sample must finish and rewrite, never pass through',
        );
        assert.match(
          JSON.parse(result).hookSpecificOutput.updatedInput.command,
          /^bash /,
        );
        return elapsedMs;
      },
    });
  });
});

// Finding #6 (adversarial review of PR #1295 round 5), performance half.
// hasInterpStdinShape() (new in round 4) did a from-scratch backward
// retokenization per quoted heredoc with no bound other than distance to the
// previous chain operator -- O(n^2) in heredoc count. Fixing it surfaced a
// second, independent O(n^2) sink in findHeredocs() itself (documented above
// and covered by its own correctness test, "shared-line heredocs ... finding
// #6, findHeredocs correctness"): each heredoc sharing one operator line
// re-walked all prior body+delimiter lines to find its own terminator. Both
// are fixed; this test guards the *scaling shape*, not a single absolute
// number, against either sink being reintroduced: a genuine O(n^2)
// regression grows time by roughly (4x)^2 = 16x for a 4x input increase,
// while the fixed, near-linear code grows well under that. Live red evidence
// (this session, against the true pre-round-5 snapshot built via `git show
// HEAD:...` for both modified files, n=500/2000/8000 heredocs):
// old 22.4ms/310.7ms/5219.6ms (quadratic: ~13.9x then ~16.8x per 4x step);
// new 1.3ms/4.1ms/20.1ms (~3.2x then ~4.9x per 4x step, and 259.7x faster
// than old at n=8000). Thresholds below are set generously above the
// measured fixed-code ratio (and generously below the ~16x quadratic
// signature) to avoid CI timing flakiness while still catching a real
// quadratic regression. Runs in-process via detectShapes() directly --
// spawns nothing (see the no-child-process structural test below).
function genGluedHeredocs(n) {
  const opens = [];
  for (let i = 0; i < n; i += 1) opens.push(`<<'H${i}'`);
  let cmd = `cat ${opens.join(' ')}\n`;
  for (let i = 0; i < n; i += 1) cmd += `body${i}\nH${i}\n`;
  return cmd;
}

// The glued-heredocs guard's sizes (#39). PR #38's push run 39856196983
// failed it at 7.716x and 6.085x against the 6x bound with no hook code
// changed. At 2000 -> 8000 heredocs the fixed code reads ~5.2-5.5x on a quiet
// host, as it did at this guard's origin (the ~4.9x above, then under a 12x
// bound; the move to perf-guard.js set 6x at the same sizes), and 4.23-8.18x
// under a 36-deep load on 28 CPUs, 6 of 10 runs over 6x. Per-heredoc CPU
// rises with n (1.9 us at 500, 5.9 us at 32000; cause not attributed), so a
// longer sample at 2000 does not cure it: 4 scans per sample still read
// 6.11x once in 10. At 500 -> 2000 with 32 scans per sample (small median
// ~41 CPU ms, above the sub-20 ms size the run() guard's history names as
// noisy) the same replica read 3.74-4.64x, 0 of 10 over, while a planted
// per-heredoc re-split of every earlier body line (the original sink's
// shape) read 13.22-13.86x. The 4x scale and the 6x bound are unchanged.
// The trade is sensitivity: a quadratic term's share of the cost is about 4x
// smaller at 500 heredocs than at 2000. That rescan on every 16th heredoc
// still reads 6.73-7.14x here and fails; on every 64th it reads 4.92-5.34x
// and passes, where the old point failed it 4 of 5 times at the same load
// (and failed unchanged code 6 of 10 times at load 36). Growth that appears
// only above 2000 heredocs is not measured here.
const GLUED_HEREDOC_GUARD = { n: 500, reps: 32, scale: 4, maxRatio: 6 };
const GLUED_HEREDOC_MAX_N = 500;
const GLUED_HEREDOC_MIN_SAMPLE = 16000; // heredocs scanned per small sample

test('detectShapes: the glued-heredocs guard samples where its 6x bound has headroom, with its 4x scale and bound unchanged (#39)', () => {
  assert.ok(
    GLUED_HEREDOC_GUARD.n <= GLUED_HEREDOC_MAX_N,
    `the small size must be at most ${GLUED_HEREDOC_MAX_N} heredocs, below the sizes where the fixed code's ratio nears 6x; got ${GLUED_HEREDOC_GUARD.n}`,
  );
  assert.ok(
    GLUED_HEREDOC_GUARD.n * GLUED_HEREDOC_GUARD.reps >= GLUED_HEREDOC_MIN_SAMPLE,
    `the small sample must scan at least ${GLUED_HEREDOC_MIN_SAMPLE} heredocs (n x reps), so one cold trial cannot move its median; got ${GLUED_HEREDOC_GUARD.n * GLUED_HEREDOC_GUARD.reps}`,
  );
  assert.strictEqual(GLUED_HEREDOC_GUARD.scale, 4, 'the scale is the one the 6x bound was set for');
  assert.strictEqual(GLUED_HEREDOC_GUARD.maxRatio, 6, 'the bound is not widened: 4x input must stay under 6x cost');
});

test('detectShapes: many heredocs sharing one operator line scale near-linearly, not quadratically (finding #6, performance)', (t) => {
  const { n, reps, scale, maxRatio } = GLUED_HEREDOC_GUARD;
  // A constant marker makes a completed scan distinguishable from the []
  // deadline fallback, without changing the heredoc counts or 4x growth step.
  const small = 'echo $(date); ' + genGluedHeredocs(n);
  const large = 'echo $(date); ' + genGluedHeredocs(scale * n); // 4x heredocs
  const sample = (input) =>
    measureCpu(() => detectShapes(input), { cpuClock: true });
  // One guard sample is `reps` scans of the same prebuilt input. Its total is
  // what the per-call 5000 ms sanity bound checks, so every scan is under it.
  const sampleScans = (input) =>
    measureCpu(() => {
      const results = [];
      for (let i = 0; i < reps; i += 1) results.push(detectShapes(input));
      return results;
    }, { cpuClock: true });

  detectShapes(small); // warm up
  detectShapes(large);

  // Regression probe: jump wall time after the helper's epoch read and the
  // parser's deadline creation, before its first checkpoint. A CPU-clock
  // sample must finish the scan rather than count a fast deadline bailout.
  const now = Date.now;
  let wallReads = 0;
  try {
    Date.now = () => now() + (wallReads++ >= 2 ? 10000 : 0);
    assert.deepStrictEqual(sample(small).result, ['cmdsub']);
  } finally {
    Date.now = now;
  }

  const { message } = assertPerfScaling({
    n,
    scale,
    maxRatio,
    sanityMs: 5000,
    label: `detectShapes() glued heredocs, ${reps} scans per sample`,
    measure: (size) => {
      const { result, elapsedMs } = sampleScans(size === n ? small : large);
      assert.strictEqual(result.length, reps);
      for (const scan of result)
        assert.deepStrictEqual(
          scan,
          ['cmdsub'],
          'a deadline bailout is not a completed scan',
        );
      return elapsedMs;
    },
  });
  // Green runs record the ratio too: a CI reading at or over 6x here means
  // the sizing above was the wrong diagnosis.
  t.diagnostic(message);
});

// ===========================================================================
// F2 (adversarial review of PR #1295 round 6): shape-rewrite.js had no
// internal execution-time budget despite TWO rounds (round 4 and round 5,
// see finding #6 above) fixing O(n^2) parsing sinks in this same file --
// each fix closed a specific known sink, but nothing backstops a FUTURE
// regression from running unchecked into the hook's external 5000ms CLI
// timeout (a PreToolUse command hook that times out fails OPEN, not closed:
// the timed-out call proceeds unblocked, so an unbounded analysis is a
// bypass path, not just a latency one). Mirrors fanout-admission.js's own
// ANALYSIS_BUDGET_MS/checkBudget/deadline
// pattern (PR #1294) rather than inventing a new one. These two tests mirror
// that PR's own pair: a performance regression guard proving a large-but-
// legitimate input finishes comfortably inside the budget, and a
// deterministic budgetMs:-1 test proving the fail-closed path is reachable
// and returns the documented value.
// ===========================================================================

test('reaches: legitimate heredoc-count commands scale near-linearly, unaffected by the F2 backstop (adversarial review of PR #1295 round 6)', () => {
  const { root } = mkWorktree();
  try {
    // reaches(), its heredoc parsing and flag checks are synchronous and
    // spawn nothing; CPU-clock deadlines cannot turn descheduling into a
    // fast fail-closed fallback. The sole absolute bound is the 5s timeout.
    assertPerfScaling({
      n: 2000,
      scale: 4,
      maxRatio: 6,
      sanityMs: 5000,
      label: 'reaches() glued heredocs',
      measure: (n) => {
        const command = genGluedHeredocs(n);
        const { result, elapsedMs } = measureCpu(
          () => reaches(command, [root]),
          { cpuClock: true },
        );
        assert.strictEqual(
          result,
          null,
          'a legitimate command must finish checking, never fail closed on budget',
        );
        return elapsedMs;
      },
    });
  } finally {
    rmTmp(root);
  }
});

test('reaches: a forced-past deadline (budgetMs: -1) fails closed -- treated as reaching outright rather than run unchecked (F2, adversarial review of PR #1295 round 6)', () => {
  const { root } = mkWorktree();
  try {
    // Deadline is forced into the past via the options override (not the
    // env-var tunable, which is read once at module load) -- deterministic
    // and instant, no large fixture required, mirroring fanout-admission's
    // own `{ budgetMs: -1 }` test. Any non-trivial command exercises the
    // check since checkBudget() runs at reachesWithin's very first call.
    const result = reaches("echo hi; echo bye; echo three; echo four", [root], { budgetMs: -1 });
    assert.ok(
      result,
      'a budget-exceeded reach analysis must fail CLOSED (a truthy reach reason), never null/falsy, or run() would offer a rewrite for a command it never finished checking',
    );
    assert.match(String(result), /budget|exceeded/i, 'the fail-closed reason should name what happened, not read as an ordinary reach classification');
  } finally { rmTmp(root); }
});

// Finding #2 (adversarial review of PR #1295 round 7): the SHELLS `-c` flag
// check (`/^-\w*c\w*$/`) and the pre-existing ln/cp symlink-flag check
// (`/^-[a-zA-Z]*[sf][a-zA-Z]*$/`) both backtrack quadratically on a dense
// run of the allowed char class (containing the target char many times)
// followed by a terminator that makes the whole match fail. Reviewer
// measured, on the live functions: `'-' + 'c'.repeat(320000) + '!'` took
// 24.3s in a SINGLE .test() call; 1.5s at n=80000; an alternating 'ac'
// pattern for the ln/cp form hit 3.0s at n=80000 (~160KB, a plausible
// single Bash argument). checkBudget() cannot preempt this -- it only runs
// BETWEEN segment iterations, and the blowup is inside one synchronous
// regex call. Live red evidence (this session, against 246216b, via a
// same-round scratch copy `shape-rewrite.OLD.js` of the pre-fix file,
// removed before this commit): `bash -${'c'.repeat(40000)}!` took 388ms
// and `ln -${'s'.repeat(40000)}!` took 434ms pre-fix, both collapsing to
// under 5ms post-fix (isUnbundledFlagCluster(), a single linear scan with
// no backtracking to exploit). This test guards the *scaling shape* at a
// size chosen to keep CI fast while still failing hard on a real quadratic
// reintroduction (a regression would land above 1s here, matching the
// n=80000 measurements above; the fixed code measures single-digit ms).
test('reaches: the SHELLS -c and ln/cp flag-cluster checks are linear, not quadratic, in argument length (finding #2, ReDoS)', () => {
  const { root } = mkWorktree();
  try {
    // These checks live inside synchronous reaches(); neither launches the
    // shell command it inspects. Fourfold argument growth must stay below
    // 6x CPU cost, well below the 16x signature of quadratic backtracking.
    for (const [head, flag] of [
      ['bash', 'c'],
      ['ln', 's'],
    ]) {
      assertPerfScaling({
        n: 25000,
        scale: 4,
        maxRatio: 6,
        sanityMs: 5000,
        label: `reaches() ${head} -${flag} flag-cluster check`,
        measure: (n) => {
          const command = `${head} -${flag.repeat(n)}!`;
          const { result, elapsedMs } = measureCpu(
            () => reaches(command, [root]),
            { cpuClock: true },
          );
          assert.strictEqual(
            result,
            null,
            'an inert flag argument must finish checking, never fail closed on budget',
          );
          return elapsedMs;
        },
      });
    }
  } finally {
    rmTmp(root);
  }
});

test('run: no test in this file spawns a bare "node -e" child process outside the harness runHook', () => {
  const src = fs.readFileSync(__filename, 'utf8');
  assert.doesNotMatch(src, /execFileSync\(['"]node['"]|spawnSync\(['"]node['"]|require\(['"]child_process['"]\)\.exec\(/);
});

test('stripWrappers: skips sudo/env/timeout/assignment prefixes and stops at the first dynamic token', () => {
  const { shellTokens } = require('../PreToolUse/heavy-job-admission.js');
  assert.deepStrictEqual(stripWrappers(shellTokens('sudo pnpm typecheck')), ['pnpm', 'typecheck']);
  assert.deepStrictEqual(stripWrappers(shellTokens('timeout 30 pnpm exec tsc')), ['pnpm', 'exec', 'tsc']);
  assert.deepStrictEqual(stripWrappers(shellTokens('FOO=1 pnpm typecheck')), ['pnpm', 'typecheck']);
});

// ===========================================================================
// Differential fuzz: isUnbundledFlagCluster() vs. the two original regexes
// it replaced (round-7 finding #2 of PR #1295's adversarial review). Round
// 7's PR body claimed "proven exactly equivalent to both original regexes
// via a 200,026-case differential fuzz (0 mismatches)", but that script was
// never committed -- round 8 flagged this as exactly the standard round 6's
// own finding #4 applied to coverage percentages: an unreproducible number
// belongs to nobody, even when (as here, independently re-confirmed by the
// round-8 reviewer's own re-implementation) the underlying claim is true.
// This is the committed replacement. It is deliberately bounded, not
// 200,026 cases: this fuzz's job is proving CORRECTNESS (same verdict as
// the original regex on every input), a property that short strings
// exercise just as well as long ones. Proving the LINEAR-TIME claim (the
// actual reason isUnbundledFlagCluster exists) is a different property
// already covered above by the dedicated 100,000-char timing test, which
// needs adversarially large input on purpose. Mixing the two concerns into
// one giant-input fuzz would make this test slow for no added correctness
// coverage.
// ===========================================================================

// mulberry32: a small, public-domain, deterministic PRNG. Given the same
// seed it reproduces the exact same sequence forever, in any process -- the
// entire point of a *committed* fuzz: a future mismatch is reproducible by
// re-running this file, not a one-off number from a session nobody can
// re-open.
function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Character pools biased toward the edges the original regexes actually
// cared about: the two target-char sets in BOTH cases (only lowercase is a
// real target -- neither original regex carries the `i` flag, so case
// sensitivity is a live boundary, not a formality), allowed-but-not-target
// chars, and chars outside the allowed class entirely (so most generated
// strings are non-matches, not matches -- a fuzz that only ever generates
// hits proves nothing about the negative space).
const FUZZ_WORD_POOL = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_';
const FUZZ_ALPHA_POOL = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
// Includes a bare '-' deliberately: a dash that is NOT the leading char is
// just an ordinary disallowed-in-neither-class character, a boundary case
// in its own right (e.g. "-c-c" contains the target 'c' twice around a
// dash that is not itself a word char).
const FUZZ_NON_ALLOWED_POOL = '!@#$%^&*()+=[]{}|\\;:\'",.<>/?~` \t-';
const FUZZ_TARGET_C = 'cC';
const FUZZ_TARGET_SF = 'sSfF';

function fuzzRandChar(rand, pool) {
  return pool[Math.floor(rand() * pool.length)];
}

// One candidate literal: length 0-16, first char '-' most of the time (the
// shape under test) but sometimes not (the "doesn't even start with a
// dash" boundary already covered explicitly below, reinforced here at
// random), remaining chars drawn from a mix that keeps target chars,
// allowed-non-target chars, and disallowed chars all appearing often
// enough to matter.
function fuzzGenCandidate(rand) {
  const len = Math.floor(rand() * 17); // 0..16 inclusive
  let s = '';
  if (len > 0) {
    s += rand() < 0.85 ? '-' : fuzzRandChar(rand, FUZZ_WORD_POOL + FUZZ_NON_ALLOWED_POOL);
  }
  for (let i = 1; i < len; i += 1) {
    const r = rand();
    if (r < 0.15) s += fuzzRandChar(rand, FUZZ_TARGET_C);
    else if (r < 0.30) s += fuzzRandChar(rand, FUZZ_TARGET_SF);
    else if (r < 0.65) s += fuzzRandChar(rand, FUZZ_WORD_POOL);
    else if (r < 0.85) s += fuzzRandChar(rand, FUZZ_ALPHA_POOL);
    else s += fuzzRandChar(rand, FUZZ_NON_ALLOWED_POOL);
  }
  return s;
}

// The two ORIGINAL regexes this predicate replaced (finding #2, round 7) --
// copied here verbatim, never imported from the production module, so a
// future edit to the live code can never accidentally edit its own oracle
// out from under this test.
const FUZZ_REGEX_C = /^-\w*c\w*$/;
const FUZZ_REGEX_SF = /^-[a-zA-Z]*[sf][a-zA-Z]*$/;

function fuzzCompareOne(s) {
  const mismatches = [];
  const regexC = FUZZ_REGEX_C.test(s);
  const funcC = isUnbundledFlagCluster(s, isWordChar, 'c');
  if (regexC !== funcC) {
    mismatches.push({
      variant: 'SHELLS -c (isWordChar, target "c")', input: s, regex: regexC, func: funcC,
    });
  }
  const regexSF = FUZZ_REGEX_SF.test(s);
  const funcSF = isUnbundledFlagCluster(s, isAlphaChar, 'sf');
  if (regexSF !== funcSF) {
    mismatches.push({
      variant: 'ln/cp -sf (isAlphaChar, target "sf")', input: s, regex: regexSF, func: funcSF,
    });
  }
  return mismatches;
}

test('isUnbundledFlagCluster: differential fuzz against both original regexes, deterministic seed (round-8 finding #1 of PR #1295 -- the round-7 fuzz claim was never committed)', () => {
  const FUZZ_SEED = 0xC0FFEE; // arbitrary, fixed forever: changing it would break reproducibility for no benefit
  const FUZZ_CASE_COUNT = 20000; // short strings (len <= 16): runs in well under a second, verified below
  const rand = mulberry32(FUZZ_SEED);

  // Explicit boundary cases, on top of the random sweep: empty string,
  // just a dash, a doubled dash, single-char clusters in both cases, both
  // target sets in both orders and both cases, a non-dash-leading string,
  // a mid-string dash, whitespace and a literal backslash as disallowed
  // chars, and the classic ReDoS-shaped "allowed run then a terminator".
  const FUZZ_BOUNDARY_CASES = [
    '', '-', '--', '-c', '-C', '-s', '-S', '-f', '-F', '-sf', '-fs', '-SF',
    '-Cc', '-cC', 'c', 'sf', '-x', '-xyz', '-xcx', '-XCX', '---c', '-c-',
    '-c-c', '-s_f', '-CS', '-abc', '-ABC', '-s!', '-c ', '- c', '-\t',
    '-\\', '-c\\', '-ccccccccc!', '-sssssssss!',
  ];

  const mismatches = [];
  for (const s of FUZZ_BOUNDARY_CASES) mismatches.push(...fuzzCompareOne(s));

  const t0 = Date.now();
  for (let i = 0; i < FUZZ_CASE_COUNT; i += 1) {
    mismatches.push(...fuzzCompareOne(fuzzGenCandidate(rand)));
  }
  const elapsedMs = Date.now() - t0;

  assert.ok(
    elapsedMs < 5000,
    `fuzz sweep of ${FUZZ_CASE_COUNT} generated cases took ${elapsedMs}ms, expected well under 5s -- CI-bounded by design (short strings only; the dedicated ReDoS timing test above already covers the 100,000-char adversarial-length case)`,
  );

  assert.deepStrictEqual(
    mismatches,
    [],
    `found ${mismatches.length} mismatch(es) between isUnbundledFlagCluster() and its original regex out of ${FUZZ_BOUNDARY_CASES.length} boundary cases + ${FUZZ_CASE_COUNT} generated cases at seed 0x${FUZZ_SEED.toString(16)} (reproduce by re-running this test file): ${JSON.stringify(mismatches.slice(0, 10))}`,
  );
});

// ===========================================================================
// reachWords: `<<-EOF` tokenizer correctness (round-8 adversarial review of
// PR #1295, finding #4). Refuted as a SECURITY finding by the round-8
// reviewer: hasHeredocRedirect (shape-rewrite.js, both call sites) counts
// `<<`/`<<-` op ENTRIES only -- it never inspects which exact string a
// token carries -- and heredocOpToInfo pairs each such op entry with
// findHeredocs()'s heredoc-info array SEQUENTIALLY, by position, never by
// matching delimiter text. Both mechanisms are blind to whether the glued
// word reads "-EOF" or "EOF", so the bug never changed a reach decision.
// It is still a genuine tokenizer defect: findHeredocs() (which drives the
// actual body/delimiter parsing) already treats `<<-` as one operator via
// its own `/<<-?/g`, and multiple call sites elsewhere in this file already
// check `e.value === '<<-'` defensively -- a check that, before this fix,
// could never once be true, because reachWords() never produced that
// value.
// ===========================================================================

test('reachWords: <<-EOF tokenizes as op "<<-" + word "EOF" (finding #4, tokenizer correctness only -- refuted as a security finding)', () => {
  const tokens = reachWords("cat <<-EOF\nbody text\nEOF");
  const heredocOp = tokens.find((t) => t.type === 'op' && t.value.startsWith('<<'));
  assert.ok(heredocOp, 'expected a "<<"-family op token in the stream');
  assert.strictEqual(
    heredocOp.value,
    '<<-',
    `expected the heredoc operator token to be the single string "<<-" (matching findHeredocs()'s own /<<-?/g), got "${heredocOp.value}" -- this is exactly the pre-fix bug: the dash gets glued onto the following word instead of the operator`,
  );
  const opIdx = tokens.indexOf(heredocOp);
  const delimWord = tokens[opIdx + 1];
  assert.strictEqual(delimWord.type, 'word', 'expected a word token immediately after the heredoc operator (the delimiter)');
  assert.strictEqual(
    wordLiteralText(delimWord),
    'EOF',
    `expected the delimiter word's literal text to be "EOF" with the dash consumed by the operator, got "${wordLiteralText(delimWord)}"`,
  );
});
