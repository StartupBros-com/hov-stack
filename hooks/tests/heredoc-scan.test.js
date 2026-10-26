'use strict';
/**
 * Tests for hooks/lib/heredoc-scan.js (dotfiles #1853).
 *
 * The oracle is real bash. Every command runs in a scratch directory with an
 * executable `mark` on PATH that logs its argument, so the log is the set of
 * marks bash executed. The scanner is sound for a command when every logged
 * mark appears in some piece executedPieces returns; it is precise for a mark
 * built as data when no piece shows it.
 *
 * Three parts:
 * - the bash-fact table: one case per fact in the lib header, each asserting
 *   which marks bash runs, so a fact that stops holding fails here;
 * - a seeded fuzz over the same positions (data bodies with odd quotes, shell
 *   bodies, unquoted-body substitutions, compound commands piped into a shell,
 *   functions, files written then run, process substitutions, substitution
 *   command words, while-read loops, comments, line continuations), nested
 *   two deep;
 * - agreement with shape-rewrite's findHeredocs on the inputs both read the
 *   same way (no comments, arithmetic, substitutions or quotes in bodies).
 */

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const { mkTmp, rmTmp } = require('./lib/harness');
const { measureCpu } = require('./lib/timing');
const { assertPerfScaling } = require('./lib/perf-guard');
const { executedPieces, scanHeredocs, NestingTooDeep, MAX_NESTING } = require('../lib/heredoc-scan.js');
const { findHeredocs } = require('../PreToolUse/shape-rewrite.js');

const HAS_BASH = spawnSync('bash', ['-c', 'true']).status === 0;
const NO_BASH = HAS_BASH ? false : 'bash is not on PATH';

// Only a completed invocation with its expected status can supply marker evidence.
function runMarks(command, { expectedStatus = 0, timeout = 5000 } = {}) {
  const dir = mkTmp('heredoc-oracle-');
  try {
    const bin = path.join(dir, 'bin');
    const work = path.join(dir, 'work');
    fs.mkdirSync(bin);
    fs.mkdirSync(work);
    fs.writeFileSync(path.join(bin, 'mark'), '#!/bin/sh\nprintf "%s\\n" "$1" >> "$MARKLOG"\n', { mode: 0o755 });
    const log = path.join(dir, 'marks.log');
    const result = spawnSync('bash', ['-c', command], {
      cwd: work,
      env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, MARKLOG: log },
      stdio: ['ignore', 'pipe', 'pipe'],
      encoding: 'utf8',
      timeout,
    });
    const detail = `bash oracle: command=${JSON.stringify(command)} status=${result.status} expectedStatus=${expectedStatus} signal=${result.signal} error=${result.error || 'none'} stdout=${JSON.stringify(result.stdout)} stderr=${JSON.stringify(result.stderr)}`;
    assert.ok(!result.error, detail);
    assert.strictEqual(result.signal, null, detail);
    assert.strictEqual(result.status, expectedStatus, detail);
    return fs.existsSync(log) ? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean) : [];
  } finally {
    rmTmp(dir);
  }
}

test('#1895 oracle: successful commands may produce marks or no marks', { skip: NO_BASH }, () => {
  assert.deepStrictEqual(runMarks('mark A; mark B'), ['A', 'B']);
  assert.deepStrictEqual(runMarks('printf "expected warning\\n" >&2'), []);
});

test('#1895 oracle: an unexpected exit cannot pass with empty or matching marks', { skip: NO_BASH }, () => {
  for (const command of ['printf "oracle failure\\n" >&2; exit 7', 'mark A; printf "oracle failure\\n" >&2; exit 7']) {
    assert.throws(() => runMarks(command), (error) => {
      assert.match(error.message, /status=7/);
      assert.ok(error.message.includes(`stderr=${JSON.stringify('oracle failure\n')}`));
      assert.ok(error.message.includes(JSON.stringify(command)));
      return true;
    });
  }
});

test('#1895 oracle: intentional failures require the exact declared status', { skip: NO_BASH }, () => {
  assert.deepStrictEqual(runMarks('exit 2', { expectedStatus: 2 }), []);
  assert.throws(() => runMarks('exit 7', { expectedStatus: 2 }), /status=7/);
  assert.throws(() => runMarks(':', { expectedStatus: 2 }), /status=0/);
});

test('#1895 oracle: a signal is not empty successful execution', { skip: NO_BASH }, () => {
  assert.throws(() => runMarks('printf "oracle signal\\n" >&2; kill -TERM $$'), (error) => {
    assert.match(error.message, /signal=SIGTERM/);
    assert.ok(error.message.includes(`stderr=${JSON.stringify('oracle signal\n')}`));
    return true;
  });
});

test('#1895 oracle: a timeout cannot validate partial marker output', { skip: NO_BASH }, () => {
  assert.throws(() => runMarks('mark A; printf "oracle timeout\\n" >&2; while :; do :; done', { timeout: 200 }), (error) => {
    assert.match(error.message, /ETIMEDOUT/);
    assert.ok(error.message.includes(`stderr=${JSON.stringify('oracle timeout\n')}`));
    return true;
  });
});

test('#1895 oracle: a spawn failure is not an empty marker log', { skip: NO_BASH }, () => {
  const previousPath = process.env.PATH;
  try {
    process.env.PATH = '';
    assert.throws(() => runMarks(':'), /ENOENT/);
  } finally {
    if (previousPath === undefined) delete process.env.PATH;
    else process.env.PATH = previousPath;
  }
});

function visible(pieces, id) {
  const re = new RegExp(`\\bmark ${id}\\b`);
  return pieces.some((p) => re.test(p.text));
}

// The quote state a lexer reaching text[at] is in: none, sq, ansi or dq.
function quoteStateAt(text, at) {
  let state = 'none';
  for (let k = 0; k < at; k += 1) {
    const c = text[k];
    if (state === 'none') {
      if (c === '\\') k += 1;
      else if (c === "'") state = 'sq';
      else if (c === '"') state = 'dq';
      else if (c === '$' && text[k + 1] === "'") {
        state = 'ansi';
        k += 1;
      }
    } else if (state === 'sq') {
      if (c === "'") state = 'none';
    } else if (c === '\\') {
      k += 1;
    } else if ((state === 'ansi' && c === "'") || (state === 'dq' && c === '"')) {
      state = 'none';
    }
  }
  return state;
}

// A mark a guard lexing the pieces would read as a command: outside quotes,
// or inside double quotes only right after `$(` or a backquote. Plain
// visible() would also accept a mark that an odd quote left in a piece hides.
function lexVisible(pieces, id) {
  const re = new RegExp(`\\bmark ${id}\\b`, 'g');
  return pieces.some((p) => [...p.text.matchAll(re)].some((m) => {
    const state = quoteStateAt(p.text, m.index);
    return state === 'none' || (state === 'dq' && /(?:\$\(|`)$/.test(p.text.slice(0, m.index)));
  }));
}

// [name, command, { runs: marks bash runs, hidden: marks no piece may show,
//   seen: marks a piece must show although bash does not run them,
//   racy: marks bash may or may not run before the call ends,
//   status: expected outer-shell exit status for intentional errors (default 0) }]
const FACTS = [
  // Delimiter: the quote-removed word; any quoting makes the body literal.
  ['delimiter a"b', 'cat <<"a\\"b" >/dev/null\nit\'s\na"b\nmark A', { runs: ['A'] }],
  ['delimiter $EOF', 'cat <<"\\$EOF" >/dev/null\nit\'s\n$EOF\nmark A', { runs: ['A'] }],
  ['delimiter keeps \\z', 'cat <<"a\\zb" >/dev/null\nit\'s\na\\zb\nmark A', { runs: ['A'] }],
  ["delimiter $'EOF'", "cat <<$'EOF' >/dev/null\nit's\nEOF\nmark A", { runs: ['A'] }],
  ['delimiter "E"OF', 'cat <<"E"OF >/dev/null\nit\'s\nEOF\nmark A', { runs: ['A'] }],
  ['empty delimiter ends at an empty line', 'cat <<"" >/dev/null\nit\'s\n\nmark A', { runs: ['A'] }],
  ['quoted body is literal', "cat <<'EOF' >/dev/null\n$(mark A)\nEOF\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['backslash body is literal', 'cat <<\\EOF >/dev/null\n`mark A`\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['unquoted body substitutions run', "cat <<EOF >/dev/null\n'$(mark A)'\n`mark B`\n\\$(mark C)\nEOF\nmark D", { runs: ['A', 'B', 'D'], hidden: ['C'] }],
  // `<<` in arithmetic is a shift; `<<1` outside it is a heredoc.
  ['$(( )) shift', 'echo $((1<<2)) >/dev/null\nmark A', { runs: ['A'] }],
  ['variable shift', 'x=1; y=2; echo $((x<<y)) >/dev/null\nmark A', { runs: ['A'] }],
  ['(( )) shift', '(( x = 1<<2 ))\nmark A', { runs: ['A'] }],
  ['for (( shift', 'for ((i=0<<1; i<1; i++)); do :; done\nmark A', { runs: ['A'] }],
  ['$[ ] shift', 'echo $[1<<2] >/dev/null\nmark A', { runs: ['A'] }],
  ['<<1 is a heredoc', 'cat <<1 >/dev/null\nmark A\n1\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['<<< is a here-string', 'cat <<< "x" >/dev/null\nmark A', { runs: ['A'] }],
  ['quoted << is a word', 'echo "<<EOF" \'<<EOF\' >/dev/null\nmark A', { runs: ['A'] }],
  // A comment starts at a word-initial `#`, after an operator too.
  ['comment line', "# it's a note <<EOF\nmark A", { runs: ['A'] }],
  ['trailing comment', "true # it's <<EOF\nmark A", { runs: ['A'] }],
  // bash rejects the empty redirect; the odd quote after `>#` must still not hide line 2.
  ['comment after an operator', "echo hi >#f it's\nmark A", { runs: [], seen: ['A'], status: 2 }],
  ['a#b is a word', 'cat a#b <<EOF 2>/dev/null\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['$# is a word', 'cat $# <<EOF 2>/dev/null\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['${#x} is a word', 'x=ab; cat ${#x} <<EOF 2>/dev/null\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  // Bodies start at the first unquoted newline, and carry past `$(cat <<EOF)`.
  ['quoted newline does not start a body', 'cat <<EOF "a\nb" 2>/dev/null\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['body carries past )', 'x=$(cat <<EOF)\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  // Inside $( ), `EOF)` ends the body and the substitution.
  ['comsub EOF)', 'x=$(cat <<EOF\nmark A\nEOF)\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['comsub EOF )', 'x=$(cat <<EOF\nmark A\nEOF )\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['comsub EOF); x', 'x=$(cat <<EOF\nmark A\nEOF); mark B', { runs: ['B'], hidden: ['A'] }],
  ['comsub EOF; is body', 'x=$(cat <<EOF\nmark A\nEOF;\nEOF\n); mark B', { runs: ['B'], hidden: ['A'] }],
  ['comsub EOF x is body', 'x=$(cat <<EOF\nmark A\nEOF x\nEOF\n); mark B', { runs: ['B'], hidden: ['A'] }],
  ['subshell EOF) is body', '(cat <<EOF >/dev/null\nmark A\nEOF)\nEOF\n); mark B', { runs: ['B'], hidden: ['A'] }],
  ['backquote EOF) is body', 'x=`cat <<EOF\nmark A\nEOF)\nEOF\n`; mark B', { runs: ['B'], hidden: ['A'] }],
  // An unterminated body runs to the end of the command.
  ['unterminated data body', 'cat <<EOF >/dev/null\nmark A', { runs: [], hidden: ['A'] }],
  ['unterminated shell body', 'bash <<EOF\nmark A', { runs: ['A'] }],
  // Pipes on the opening line, before or after the body.
  ['cat | bash', "cat <<'EOF' | bash\nmark A\nEOF", { runs: ['A'] }],
  ['cat | newline body bash', "cat <<'EOF' |\nmark A\nEOF\nbash", { runs: ['A'] }],
  ['cat | newline body sort', "cat <<'EOF' |\nmark A\nEOF\nsort >/dev/null\nmark B", { runs: ['B'], hidden: ['A'] }],
  // Several heredocs on one line read their bodies in operator order.
  ['two data bodies', 'cat <<A >/dev/null; cat <<B >/dev/null\nmark X\nA\nmark Y\nB\nmark Z', { runs: ['Z'], hidden: ['X', 'Y'] }],
  ['data then shell body', 'cat <<A >/dev/null; bash <<B\nmark X\nA\nmark Y\nB\nmark Z', { runs: ['Y', 'Z'], hidden: ['X'] }],
  ['<<- strips tabs', 'cat <<-EOF >/dev/null\n\tmark A\n\tEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  // Consumers.
  ['bash body', "bash <<'EOF'\nmark A\nEOF", { runs: ['A'] }],
  ['sh body', "sh <<'EOF'\nmark A\nEOF", { runs: ['A'] }],
  ['source /dev/stdin', "source /dev/stdin <<'EOF'\nmark A\nEOF", { runs: ['A'] }],
  ['env and timeout wrappers', "env bash <<'A'\nmark X\nA\ntimeout 5 bash <<'B'\nmark Y\nB", { runs: ['X', 'Y'] }],
  ['nice cat is data', "nice cat <<'EOF' >/dev/null\nmark A\nEOF\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['unknown command keeps its body', "nosuchcmd1853 <<'EOF'\nmark A\nEOF", { runs: [], seen: ['A'], status: 127 }],
  ['done <<', "while read -r l; do $l; done <<'EOF'\nmark A\nEOF", { runs: ['A'] }],
  ['| while read', "cat <<'EOF' | while read -r l; do $l; done\nmark A\nEOF", { runs: ['A'] }],
  ['substitution command word', "$(cat <<'EOF'\nmark A\nEOF\n)", { runs: ['A'] }],
  ['data body', "cat > notes.md <<'EOF'\nmark A\nEOF\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['odd apostrophe in a data body', "cat > notes.md <<'EOF'\nit's\nEOF\nmark A", { runs: ['A'] }],
  ['odd " in a "$( )" body', 'echo "$(cat <<\'EOF\'\nsay "hi\nEOF\n)" >/dev/null && mark A', { runs: ['A'] }],
  ['apostrophe in an assigned substitution', "msg=$(cat <<'EOF'\nit's\nEOF\n)\nmark A", { runs: ['A'] }],
  ['odd quote stays inside its runnable piece', "bash <<'EOF'\necho it's\nEOF\nmark A", { runs: ['A'] }],
  ['nested data body in a shell body', "bash <<'OUT'\ncat > notes.md <<'IN'\nmark A\nIN\nmark B\nOUT", { runs: ['B'], hidden: ['A'] }],
  ['nested shell body', "bash <<'OUT'\nbash <<'IN'\nmark A\nIN\nOUT", { runs: ['A'] }],
  ['runner inside a body substitution', "cat <<EOF >/dev/null\n$(bash <<'IN'\nmark A\nIN\n)\nEOF\nmark B", { runs: ['A', 'B'] }],
  ['data inside a body substitution', "cat <<EOF >/dev/null\n$(cat <<'IN'\nmark A\nIN\n)\nEOF\nmark B", { runs: ['B'], hidden: ['A'] }],
  // Compound commands: piped into a shell they run, piped into data they do not.
  ['{ } | bash', "{ cat <<'EOF'\nmark A\nEOF\n} | bash", { runs: ['A'] }],
  ['( ) | bash', "( cat <<'EOF'\nmark A\nEOF\n) | bash", { runs: ['A'] }],
  ['if | bash', "if true; then cat <<'EOF'\nmark A\nEOF\nfi | bash", { runs: ['A'] }],
  ['for | sh', "for i in 1; do cat <<'EOF'\nmark A\nEOF\ndone | sh", { runs: ['A'] }],
  ['case | bash', "case x in x) cat <<'EOF'\nmark A\nEOF\n;; esac | bash", { runs: ['A'] }],
  ['case (x) | sort', "case x in (x) cat <<'EOF'\nmark A\nEOF\n;; esac | sort >/dev/null\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['( ) | sort', "( cat <<'EOF'\nmark A\nEOF\n) | sort >/dev/null\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['if | sort', "if true; then cat <<'EOF'\nmark A\nEOF\nfi | sort >/dev/null\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['for | sort', "for i in 1; do cat <<'EOF'\nmark A\nEOF\ndone | sort >/dev/null\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['{ } | sort | uniq', "{ cat <<'EOF'\nmark A\nEOF\n} | sort | uniq >/dev/null\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['bare ( )', "( cat <<'EOF' >/dev/null\nmark A\nEOF\n)\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['if cat is data', "if cat <<'EOF' >/dev/null\nmark A\nEOF\nthen :; fi\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['{ } > file', "{ cat <<'EOF'\nmark A\nEOF\n} > notes.md\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['function body', "f() { cat <<'EOF'\nmark A\nEOF\n}; f | bash", { runs: ['A'] }],
  // A file written in the call and run later in it, matched by basename.
  ['bash s.sh', "cat > s.sh <<'EOF'\nmark A\nEOF\nbash s.sh", { runs: ['A'] }],
  ['bash < s.sh', "cat > s.sh <<'EOF'\nmark A\nEOF\nbash < s.sh", { runs: ['A'] }],
  ['cat s.sh | bash', "cat > s.sh <<'EOF'\nmark A\nEOF\ncat s.sh | bash", { runs: ['A'] }],
  ['source s.sh', "cat > s.sh <<'EOF'\nmark A\nEOF\nsource s.sh", { runs: ['A'] }],
  ['. ./s.sh', "cat <<'EOF' > s.sh\nmark A\nEOF\n. ./s.sh", { runs: ['A'] }],
  ['tee s.sh', "tee s.sh >/dev/null <<'EOF'\nmark A\nEOF\nbash s.sh", { runs: ['A'] }],
  ['dynamic target', "cat > \"$PWD/s.sh\" <<'EOF'\nmark A\nEOF\nbash \"$PWD/s.sh\"", { runs: ['A'] }],
  ['{ } > s.sh', "{ cat <<'EOF'\nmark A\nEOF\n} > s.sh; bash s.sh", { runs: ['A'] }],
  ['"$( )" > s.sh', "echo \"$(cat <<'EOF'\nmark A\nEOF\n)\" > s.sh; bash s.sh", { runs: ['A'] }],
  ['written then bash < notes', "cat <<'EOF' >notes.md\nmark A\nEOF\n{ cat notes.md; } | bash", { runs: ['A'] }],
  ['written then read as data', "cat > notes.md <<'EOF'\nmark A\nEOF\nwc -l notes.md >/dev/null\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['written before the heredoc does not count', "bash s.sh 2>/dev/null; cat > s.sh <<'EOF'\nmark A\nEOF", { runs: [], hidden: ['A'] }],
  // A file named inside a string another shell runs; matched part by part.
  ["sh -c 'cat s.sh|sh'", "cat <<'EOF' > s.sh\nmark A\nEOF\nsh -c 'cat s.sh|sh'", { runs: ['A'] }],
  ["env -S 'bash s.sh'", "cat <<'EOF' > s.sh\nmark A\nEOF\nenv -S 'bash s.sh'", { runs: ['A'] }],
  ['xargs sh < <(echo s.sh)', "cat <<'EOF' > s.sh\nmark A\nEOF\nxargs sh < <(echo s.sh)", { runs: ['A'] }],
  ['echo s.sh | xargs sh', "cat <<'EOF' > s.sh\nmark A\nEOF\necho s.sh | xargs sh", { runs: ['A'] }],
  ['named inside a DATA word stays data', "cat > notes.md <<'EOF'\nmark A\nEOF\necho \"see notes.md\" >/dev/null\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['named inside an unknown command word is kept', "cat > notes.md <<'EOF'\nmark A\nEOF\nnosuchcmd1853 \"see notes.md\" 2>/dev/null", { runs: [], seen: ['A'], status: 127 }],
  // A shell startup file runs in a later shell without being named.
  ['.bashrc then bash -i', "cat >> .bashrc <<'EOF'\nmark A\nEOF\nHOME=$PWD bash -ic true 2>/dev/null", { runs: ['A'] }],
  ['.bashrc with no later shell is kept', "tee -a .bashrc >/dev/null <<'EOF'\nmark A\nEOF", { runs: [], seen: ['A'] }],
  // Output process substitutions run their target; the call may end first.
  ['> >(bash)', "cat <<'EOF' > >(bash)\nmark A\nEOF\nsleep 0.2", { racy: ['A'] }],
  ['tee >(bash)', "tee >(bash) >/dev/null <<'EOF'\nmark A\nEOF\nsleep 0.2", { racy: ['A'] }],
  // Line continuations: bash removes backslash-newline before it reads
  // operators and delimiters, and joins the lines of an unquoted body before
  // comparing each with the delimiter.
  ['continuation inside <<', 'cat <\\\n<EOF >/dev/null\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['continuation inside << feeding bash', 'bash <\\\n<EOF\nmark A\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['continuation inside <<< is a here-string', 'cat <\\\n<\\\n<EOF >/dev/null\nmark A', { runs: ['A'] }],
  ['continuation before the dash', 'cat <<\\\n-EOF >/dev/null\n\tmark A\n\tEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['continuation inside the delimiter leaves it unquoted', 'cat <<E\\\nOF >/dev/null\n$(mark A)\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['continuation before the delimiter leaves it unquoted', 'cat <<\\\nEOF >/dev/null\n$(mark A)\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['continuation inside a double-quoted delimiter', 'cat <<"E\\\nOF" >/dev/null\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['continuation inside a single-quoted delimiter is literal', "cat <<'E\\\nOF' >/dev/null\nmark A\nEOF\nmark B\nE\\\nOF\nmark C", { runs: [], hidden: ['A', 'B', 'C'] }],
  ['continuation before a substitution', 'echo $\\\n(mark A) >/dev/null; mark B', { runs: ['A', 'B'] }],
  ['continuation inside << in a substitution', 'x=$(cat <\\\n<EOF\nmark A\nEOF\n); mark B', { runs: ['B'], hidden: ['A'] }],
  ['unquoted body: a continued line swallows the delimiter', 'cat <<EOF >/dev/null\nx \\\nEOF\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['unquoted body: an apostrophe after a swallowed delimiter hides nothing', "cat <<EOF >/dev/null\nx \\\nEOF\nit's\nEOF\nmark A", { runs: ['A'] }],
  ['quoted body: a trailing backslash is literal', "cat <<'EOF' >/dev/null\nx \\\nEOF\nmark A\nEOF\nmark B", { runs: ['A', 'B'] }],
  ['unquoted body: a delimiter split by a continuation ends it', 'cat <<EOF >/dev/null\nEO\\\nF\nmark A\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['quoted body: a split delimiter is body', "cat <<'EOF' >/dev/null\nEO\\\nF\nmark A\nEOF\nmark B", { runs: ['B'], hidden: ['A'] }],
  ['unquoted body: an even run of backslashes does not continue', 'cat <<EOF >/dev/null\nx \\\\\nEOF\nmark A\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['unquoted body: an odd run of backslashes continues', 'cat <<EOF >/dev/null\nx \\\\\\\nEOF\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['unquoted body: a lone backslash line joins the delimiter', 'cat <<EOF >/dev/null\n\\\nEOF\nmark A\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['unquoted body: continuations chain', 'cat <<EOF >/dev/null\na \\\nb \\\nEOF\nmark A\nEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['unquoted body: $\\<newline>( is a substitution', 'cat <<EOF >/dev/null\n$\\\n(mark A)\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['unquoted body: a backquote joins its lines', 'cat <<EOF >/dev/null\n`mark \\\nA`\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['comsub: a continued EOF) closes it', 'x=$(cat <<EOF\nmark A\nEOF\\\n)\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['comsub: a quoted EOF\\ is body', "x=$(cat <<'EOF'\nmark A\nEOF\\\n)\nEOF\n); mark B", { runs: ['B'], hidden: ['A'] }],
  ['comsub: a continued line swallows the delimiter', 'x=$(cat <<EOF\nx \\\nEOF\nmark A\nEOF\n); mark B', { runs: ['B'], hidden: ['A'] }],
  ['<<- strips tabs once per joined line', 'cat <<-EOF >/dev/null\n\tE\\\n\tOF\nmark A\n\tEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['<<- joined delimiter ends the body', 'cat <<-EOF >/dev/null\n\tE\\\nOF\nmark A\n\tEOF\nmark B', { runs: ['A', 'B'] }],
  ['<<- continued line swallows the delimiter', 'cat <<-EOF >/dev/null\n\tx \\\n\tEOF\nmark A\n\tEOF\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['a comment does not continue', 'echo x # c \\\nmark A', { runs: ['A'] }],
  ['runner body: \\$( reaches the shell as $(', 'bash <<EOF\n\\$(mark A) 2>/dev/null\nEOF\nmark B', { runs: ['A', 'B'] }],
  ['quoted runner body: a trailing backslash is literal', "bash <<'EOF'\necho x \\\nEOF\nmark A", { runs: ['A'] }],
  ['arithmetic )\\<newline>) closes', 'x=$((1)\\\n); mark A', { runs: ['A'] }],
  // A wrapper option's value is not the command it runs.
  ['env -u NAME bash', "env -u cat bash <<'EOF'\nmark A\nEOF", { runs: ['A'] }],
  ['exec -a NAME bash', "exec -a cat bash <<'EOF'\nmark A\nEOF", { runs: ['A'] }],
  ['env -i cat is data', "env -i cat <<'EOF' >/dev/null\nmark A\nEOF\nmark B", { runs: ['B'], hidden: ['A'] }],
  // An assignment's value names a file a shell may run without naming it.
  ['BASH_ENV= prefix', "cat > hook.env <<'EOF'\nmark A\nEOF\nBASH_ENV=hook.env bash -c true", { runs: ['A'] }],
  ['env BASH_ENV=', "cat > hook.env <<'EOF'\nmark A\nEOF\nenv BASH_ENV=hook.env bash -c true", { runs: ['A'] }],
  ['export BASH_ENV=', "cat > hook.env <<'EOF'\nmark A\nEOF\nexport BASH_ENV=hook.env; bash -c true", { runs: ['A'] }],
  ['BASH_ENV= then export', "cat > hook.env <<'EOF'\nmark A\nEOF\nBASH_ENV=hook.env\nexport BASH_ENV\nbash -c true", { runs: ['A'] }],
  ['B=s.sh; bash "$B"', "cat > s.sh <<'EOF'\nmark A\nEOF\nB=s.sh; bash \"$B\"", { runs: ['A'] }],
  ['B="s.sh$(true)"', "cat > s.sh <<'EOF'\nmark A\nEOF\nB=\"s.sh$(true)\"; bash \"$B\"", { runs: ['A'] }],
  ['B=$(echo)s.sh', "cat > s.sh <<'EOF'\nmark A\nEOF\nB=$(echo)s.sh; bash \"$B\"", { runs: ['A'] }],
  // A comment inside backquotes ends at their closer. A closing shell operator
  // starts a new word; a regex or substitution's closing paren does not.
  ['comment inside backquotes', 'echo `echo a #x` >/dev/null; mark A', { runs: ['A'] }],
  ['[[ =~ (a)#b ]] is one word', '[[ a =~ ^(a)#b ]]; mark A', { runs: ['A'] }],
  ['regex alternation keeps # in its word', '[[ a =~ (a|b)#c ]]; mark A', { runs: ['A'] }],
  ['continued conditional opener keeps regex suffix', '[\\\n[ a =~ (a)#b ]]; mark A', { runs: ['A'] }],
  ['continued regex operator keeps suffix', '[[ a =\\\n~ (a)#b ]]; mark A', { runs: ['A'] }],
  ['continued conditional closer ends regex context', '[[ a =~ (a)#b ]\\\n]; printf =~\n(true)# mark A\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['regex inside substitution keeps # in its word', 'echo $( [[ a =~ ^(a)#b ]]; mark A ) >/dev/null', { runs: ['A'] }],
  ['substitution in regex still scans its comments', '[[ a =~ $( (true)# mark A\nmark B )#c ]]; mark C', { runs: ['B', 'C'], hidden: ['A'] }],
  ['conditional grouping close starts a comment', '[[ ( a == a )# mark A\n]]; mark B', { runs: ['B'], hidden: ['A'] }],
  ['extglob suffix stays visible in a conditional', '[[ a == @(a)#b ]]; mark A', { runs: ['A'] }],
  ['extglob suffix stays visible in an argument', 'shopt -s extglob\nprintf "%s" @(a)#b >/dev/null; mark A', { runs: ['A'] }],
  ['nested extglob suffix stays visible', '[[ a == @(a|@(b))#c ]]; mark A', { runs: ['A'] }],
  ['continued extglob suffix stays visible', 'shopt -s extglob\nprintf "%s" @\\\n(a)#b >/dev/null; mark A', { runs: ['A'] }],
  ['arithmetic command close starts a comment', '((1))# mark A\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['arithmetic substitution suffix is not a comment', 'printf "%s" $((1))#b >/dev/null; mark A', { runs: ['A'] }],
  ['(cmd)#x is a comment', '(true)#x; mark A', { runs: [], hidden: ['A'] }],
  ['function header comment after )', 'f()# mark A\n{ mark B; }; f', { runs: ['B'], hidden: ['A'] }],
  ['case pattern comment after )', 'case a in a)# mark A\nmark B;; esac', { runs: ['B'], hidden: ['A'] }],
  ['subshell comment inside substitution', 'echo $( (true)# mark A\nmark B) >/dev/null', { runs: ['B'], hidden: ['A'] }],
  ['substitution suffix is not a comment', 'echo $(true)#x; mark A', { runs: ['A'] }],
  ['nested quoted extglob suffix is not a comment', 'shopt -s extglob\nprintf "%s" @(a|+(b)|"c)"|\'d)\')#b >/dev/null; mark A', { runs: ['A'] }],
  ['extglob then subshell comment', 'shopt -s extglob\nprintf "%s" @(a)#b >/dev/null; (true)# mark A\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['regex then subshell comment', '[[ a =~ ^(a)#b ]]; (true)# mark A\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['[[ argument does not open a conditional', 'echo [[ >/dev/null; (true)# mark A\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['literal =~ operand does not leak conditional state', '[[ x == =~ ]]; printf =~\n(true)# mark A\nmark B', { runs: ['B'], hidden: ['A'] }],
  ['unary =~ operand does not leak conditional state', '[[ -n =~ ]]; printf =~\n(true)# mark A\nmark B', { runs: ['B'], hidden: ['A'] }],
];

for (const [name, command, want] of FACTS) {
  test(`#1853 bash fact: ${name}`, { skip: NO_BASH }, () => {
    const pieces = executedPieces(command);
    const ran = runMarks(command, { expectedStatus: want.status ?? 0 });
    const detail = `command=${JSON.stringify(command)} ran=${JSON.stringify(ran)} pieces=${JSON.stringify(pieces.map((p) => p.text))}`;
    if (want.racy) {
      for (const id of ran) assert.ok(want.racy.includes(id), `unexpected mark ${id}: ${detail}`);
    } else {
      assert.deepStrictEqual([...ran].sort(), [...want.runs].sort(), `bash ran other marks than the case names: ${detail}`);
    }
    for (const id of [...(want.runs || []), ...(want.seen || []), ...(want.racy || [])]) {
      assert.ok(lexVisible(pieces, id), `mark ${id} is in no piece outside quotes: ${detail}`);
    }
    for (const id of want.hidden || []) {
      assert.ok(!visible(pieces, id), `data mark ${id} is in a piece: ${detail}`);
    }
  });
}

test('#1853 scanHeredocs reports the quote-removed delimiter', () => {
  const cases = [
    ['cat <<"a\\"b"\na"b', 'a"b', true],
    ['cat <<"\\$EOF"\n$EOF', '$EOF', true],
    ['cat <<"a\\zb"\na\\zb', 'a\\zb', true],
    ["cat <<$'EOF'\nEOF", 'EOF', true],
    ['cat <<"E"OF\nEOF', 'EOF', true],
    ['cat <<\\EOF\nEOF', 'EOF', true],
    ['cat <<""\n', '', true],
    ['cat <<EOF\nEOF', 'EOF', false],
    ['cat <<1\n1', '1', false],
  ];
  for (const [command, delimiter, quoted] of cases) {
    const [h, ...rest] = scanHeredocs(command).heredocs;
    assert.deepStrictEqual(rest, [], command);
    assert.strictEqual(h.delimiter, delimiter, command);
    assert.strictEqual(h.quoted, quoted, command);
    assert.strictEqual(h.terminated, true, command);
  }
});

test('#1853 pieces keep the opening newline and never fuse words across a body', () => {
  const pieces = executedPieces("git commit -q -F - <<'EOF'\nfix: it's done\nEOF\ngh pr merge 5").map((p) => p.text);
  assert.ok(pieces.every((t) => !t.includes("it's")), JSON.stringify(pieces));
  assert.ok(pieces.join('').includes("<<'EOF'\ngh pr merge 5"), JSON.stringify(pieces));
  const written = executedPieces("cat > s.sh <<'EOF'\ngh pr merge 5\nEOF\nbash s.sh");
  assert.deepStrictEqual(written, [
    { text: "cat > s.sh <<'EOF'\n", depth: 0 },
    { text: 'gh pr merge 5', depth: 1 },
    { text: 'bash s.sh', depth: 0 },
  ]);
  const odd = executedPieces("bash <<'EOF'\necho it's\nEOF\ngh pr merge 5").map((p) => p.text);
  assert.ok(odd.some((t) => t.includes('gh pr merge 5') && !t.includes("it's")), JSON.stringify(odd));
});

test('#1853 executedPieces keeps text past maxDepth and rejects non-strings', () => {
  const nested = "bash <<'O'\nbash <<'I'\nmark A\nI\nO";
  const shallow = executedPieces(nested, { maxDepth: 0 });
  assert.ok(visible(shallow, 'A'), JSON.stringify(shallow));
  assert.ok(shallow.some((p) => p.depth === 1 && p.text.includes("bash <<'I'")), JSON.stringify(shallow));
  assert.deepStrictEqual(executedPieces(null), []);
  assert.deepStrictEqual(executedPieces(undefined), []);
  assert.deepStrictEqual(executedPieces(''), [{ text: '', depth: 0 }]);
});

test('#1853 an unquoted runner body reaches its shell joined and unescaped', () => {
  const pieces = executedPieces('bash <<EOF\n\\$(mark A) x\\\ny \\\\z\nEOF\n');
  assert.ok(pieces.some((p) => p.depth === 1 && p.text === '$(mark A) xy \\z'), JSON.stringify(pieces));
  const quoted = executedPieces("bash <<'EOF'\n\\$(mark A) x\\\ny\nEOF\n");
  assert.ok(quoted.some((p) => p.depth === 1 && p.text === '\\$(mark A) x\\\ny'), JSON.stringify(quoted));
});

test('#1853 git and gh read stdin as data only for known subcommands with inert config', () => {
  const shown = (head) => executedPieces(`${head} <<'EOF'\nmark A\nEOF`).some((p) => visible([p], 'A'));
  const data = [
    'git commit -F -',
    'ALLOW_MAIN_COMMIT=1 git commit -q -F -',
    'env GIT_AUTHOR_NAME=x git commit -F -',
    'env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git commit -F -',
    'git -c user.name=x commit -F -',
    'git -c User.Email=x -c commit.gpgsign=false commit -F -',
    'git -c core.hooksPath=/dev/null commit -q -F -',
    'git -C repo --git-dir .git commit -F -',
    'git apply',
    'gh pr comment 5 --body-file -',
    'GH_TOKEN=t gh issue create -F -',
    'gh api graphql --input -',
    'timeout 5 cat',
    'env cat',
    'env -i cat',
    'sudo -n python3 -',
    'uv run --no-project python -',
  ];
  const runnable = [
    "git -c alias.m='!bash' m",
    "git -c user.name=x -c alias.m='!bash' m",
    'git -c core.editor=x commit --amend',
    'git --config-env=core.editor=E commit',
    "GIT_EDITOR='bash -s' git commit --amend",
    'GIT_CONFIG_GLOBAL=g git commit -F -',
    'git m',
    'git bisect run bash',
    'git submodule foreach bash',
    'gh alias set m -',
    'gh codespace ssh',
    'gh extension exec x',
    'GH_PAGER=x gh pr view',
    'sudo -u u cat',
    'uv run --with x python -',
  ];
  for (const head of data) assert.ok(!shown(head), `body shown for ${head}`);
  for (const head of runnable) assert.ok(shown(head), `body hidden for ${head}`);
});

test('#1853 an assignment names a file by its literal text, not by a substitution inside it', () => {
  const written = "cat > b.md <<'EOF'\nmark A\nEOF\n";
  const shown = (tail) => visible(executedPieces(written + tail), 'A');
  // The substitution's command is read in its own frame: gh only reads b.md.
  assert.ok(!shown('out=$(gh pr create --body-file b.md 2>&1); echo "$out"'));
  assert.ok(!shown('n=`gh issue create -F b.md`'));
  assert.ok(shown('B="b.md$(true)"; bash "$B"'));
  assert.ok(shown('B=$(echo)b.md; bash "$B"'));
  assert.ok(shown('export X=1 B=b.md; bash "$B"'));
  // A name only a substitution's output carries is the header's run-time name residual.
  assert.ok(!shown('B=$(echo b.md); bash "$B"'));
});

// executedPieces skips the scan when the text has no `<<` (even one split by
// continuations) and no `#`; the full scan must leave such text whole.
test('#1853 text with no << and no # scans to itself', () => {
  const rnd = mulberry32(18530);
  const alphabet = ['a', 'b', ' ', '\t', '\n', '\\', "'", '"', '$', '(', ')', '`', '<', '>', '|', '&', ';', '{', '}', '=', '[', ']', '-', 'case', 'esac', 'in'];
  let checked = 0;
  while (checked < 3000) {
    const length = 1 + Math.floor(rnd() * 40);
    let command = '';
    for (let k = 0; k < length; k += 1) command += alphabet[Math.floor(rnd() * alphabet.length)];
    if (/<(?:\\\n)*<|#/.test(command)) continue;
    checked += 1;
    const scan = scanHeredocs(command);
    assert.deepStrictEqual([scan.text, scan.heredocs.length], [command, 0], JSON.stringify(command));
    assert.deepStrictEqual(executedPieces(command), [{ text: command, depth: 0 }], JSON.stringify(command));
  }
  assert.deepStrictEqual(scanHeredocs('cat <\\\n<EOF\nx\nEOF\n').heredocs.map((h) => h.delimiter), ['EOF']);
});

// `levels` of `echo "$(` around a heredoc: each level opens a double quote and
// a substitution, two frames on top of the top-level one.
const nestedCommand = (levels, body = 'body\n') =>
  `${'echo "$('.repeat(levels)}cat <<'H0'\n${body}H0\n${')"'.repeat(levels)}\n`;
const ACCEPTED_LEVELS = Math.floor((MAX_NESTING - 1) / 2);

test('#1853 executedPieces refuses nesting past MAX_NESTING and leaves text without << or # alone', () => {
  const at = executedPieces(nestedCommand(ACCEPTED_LEVELS));
  assert.ok(at.length > 0 && !at.some((p) => p.text.includes('body')), JSON.stringify(at));
  const refused = (err) => err instanceof NestingTooDeep && err.limit === MAX_NESTING;
  assert.throws(() => executedPieces(nestedCommand(ACCEPTED_LEVELS + 1)), refused);
  const commented = `${'echo $('.repeat(MAX_NESTING)}true${')'.repeat(MAX_NESTING)} # note\n`;
  assert.throws(() => executedPieces(commented), refused);
  const plain = `${'echo "$('.repeat(1000)}true${')"'.repeat(1000)}\n`;
  assert.deepStrictEqual(executedPieces(plain), [{ text: plain, depth: 0 }]);
});

// Every enclosing word re-reads its interior, so before the cap a scan grew
// with depth squared: loop-guard took 6.2 s at depth 4800, past its 5 s hook
// timeout, where a timed-out hook lets the call through.
test('#1853 a command nested past the cap is refused at once, not scanned', () => {
  const fixtures = new Map([1200, 4800].map((levels) => [levels, nestedCommand(levels)]));
  assertPerfScaling({
    n: 1200,
    scale: 4,
    maxRatio: 6,
    sanityMs: 5000,
    label: 'executedPieces() past the nesting cap',
    measure: (levels) => {
      let thrown = null;
      const { elapsedMs } = measureCpu(
        () => {
          try {
            executedPieces(fixtures.get(levels));
          } catch (err) {
            thrown = err;
          }
        },
        { cpuClock: true },
      );
      assert.strictEqual(thrown && thrown.name, 'NestingTooDeep', `depth ${levels} must be refused`);
      return elapsedMs;
    },
  });
});

test('#1853 at the deepest nesting it accepts, a scan grows linearly with length', () => {
  const fixtures = new Map([20000, 80000].map((lines) => [lines, nestedCommand(ACCEPTED_LEVELS, 'x\n'.repeat(lines))]));
  assertPerfScaling({
    n: 20000,
    scale: 4,
    maxRatio: 6,
    sanityMs: 5000,
    label: 'executedPieces() at the nesting cap',
    measure: (lines) => {
      const { result, elapsedMs } = measureCpu(() => executedPieces(fixtures.get(lines)), { cpuClock: true });
      assert.ok(!result.some((p) => p.text.includes('x\nx')), 'the data body must be scanned out, not refused');
      return elapsedMs;
    },
  });
});

// ---------------------------------------------------------------------------
// Seeded fuzz against bash.
// ---------------------------------------------------------------------------

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Mark classes: run (bash runs it and a piece shows it), data (bash does not
// run it and no piece shows it), quiet (bash does not run it; the scanner may
// conservatively show it), racy (bash may run it before the call ends).
const NOISE = ["it's", 'say "hi', 'a "quoted" word', 'x <<y', '# hash line', '}', ')', 'fi', 'done', 'esac', 'EOFX', '  indented', '', 'if then', ';;'];
const EXPANDING_NOISE = ['$((1<<2))', '${#x}', '$#'];

function generateCase(rnd) {
  const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
  const chance = (p) => rnd() < p;
  const marks = [];
  let ids = 0;
  let delims = 0;
  let files = 0;
  const mark = (cls) => {
    ids += 1;
    const id = `M${String(ids).padStart(3, '0')}`;
    marks.push({ id, cls });
    return `mark ${id}`;
  };
  // Some openers carry a line continuation where bash removes one: inside
  // `<<`, before the delimiter, or inside an unquoted or double-quoted one.
  const opener = (quoted) => {
    delims += 1;
    const d = `D${delims}`;
    const spec = quoted ? pick([`'${d}'`, `"${d}"`, `\\${d}`]) : d;
    if (!chance(0.2)) return { d, op: `<<${spec}` };
    const split = quoted ? `"${d[0]}\\\n${d.slice(1)}"` : `${d[0]}\\\n${d.slice(1)}`;
    return { d, op: pick([`<\\\n<${spec}`, `<<\\\n${spec}`, `<<${split}`]) };
  };

  // Lines of a body nobody runs. Unquoted, its substitutions still run in the
  // shell that reads the heredoc, unless that text is itself an unquoted body
  // another shell expands first (ctx.noExpand), where `$` is left out.
  // An unquoted body (`d` given) may also hold a line ending in a backslash
  // followed by its own delimiter: bash joins the two, so neither ends it.
  const dataBody = (ctx, quoted, cls = 'data', d = null) => {
    const lines = [];
    const n = 1 + Math.floor(rnd() * 4);
    for (let k = 0; k < n; k += 1) {
      const r = rnd();
      if (r < 0.35) lines.push(mark(cls));
      else if (r < 0.75) lines.push(pick(NOISE));
      else if (ctx.noExpand) lines.push(`${pick(NOISE)} ${mark(cls)}`);
      else if (quoted) lines.push(pick([() => `$(${mark(cls)})`, () => `\`${mark(cls)}\``, () => pick(EXPANDING_NOISE)])());
      else lines.push(pick([() => `$(${mark(ctx.runCls)})`, () => `$\\\n(${mark(ctx.runCls)})`, () => `\`${mark(ctx.runCls)}\``, () => `\\$(${mark(cls)})`, () => pick(EXPANDING_NOISE)])());
    }
    if (!quoted && d && chance(0.3)) lines.splice(Math.floor(rnd() * (lines.length + 1)), 0, `${pick(NOISE)} \\`, d);
    return lines.join('\n');
  };
  // Statements that run, for a body a shell executes.
  const shellBody = (ctx, quoted) => {
    const inner = { ...ctx, depth: ctx.depth + 1, noExpand: ctx.noExpand || !quoted };
    return statements(inner, 1 + Math.floor(rnd() * 3));
  };
  const marksOnly = (cls) => Array.from({ length: 1 + Math.floor(rnd() * 2) }, () => mark(cls)).join('\n');

  const KINDS = {
    plain: (ctx) => pick(['%', 'true; %', '% && true']).replace('%', mark(ctx.runCls)),
    data: (ctx) => {
      const quoted = chance(0.6);
      const { d, op } = opener(quoted);
      const f = (files += 1);
      const body = dataBody(ctx, quoted, 'data', d);
      const forms = [
        () => `cat ${op} >/dev/null\n${body}\n${d}`,
        () => `cat > n${f}.md ${op}\n${body}\n${d}`,
        () => `cat ${op} > n${f}.md\n${body}\n${d}`,
        () => `wc -l ${op} >/dev/null\n${body}\n${d}`,
        () => `tee n${f}.md >/dev/null ${op}\n${body}\n${d}`,
        () => `cat ${op} | sort | wc -l >/dev/null\n${body}\n${d}`,
        () => `cat ${op} |\n${body}\n${d}\nsort >/dev/null`,
        () => `if cat ${op} >/dev/null\n${body}\n${d}\nthen :; fi`,
        () => `{ cat ${op}\n${body}\n${d}\n} > n${f}.md`,
        () => `case x in (x) cat ${op}\n${body}\n${d}\n;; esac | sort >/dev/null`,
        () => `( cat ${op}\n${body}\n${d}\n) | sort >/dev/null`,
      ];
      // The shell expanding an enclosing unquoted body would run these itself.
      if (!ctx.noExpand) {
        forms.push(() => `x${f}=$(cat ${op}\n${body}\n${d}\n)`);
        forms.push(() => `echo "$(cat ${op}\n${body}\n${d}\n)" >/dev/null`);
        // A continued `D)` closes the substitution as `D)` does in bash; dash
        // rejects it as a syntax error, so a posix body leaves it out.
        if (!quoted && !ctx.posix) forms.push(() => `x${f}=$\\\n(cat ${op}\n${body}\n${d}\\\n)`);
      }
      return pick(forms)();
    },
    shell: (ctx) => {
      const quoted = chance(0.7);
      const { d, op } = opener(quoted);
      const forms = [
        ['bash', (b) => `bash ${op}\n${b}\n${d}`],
        ['sh', (b) => `sh ${op}\n${b}\n${d}`],
        ['bash', (b) => `cat ${op} | bash\n${b}\n${d}`],
        ['bash', (b) => `cat ${op} |\n${b}\n${d}\nbash`],
        ['bash', (b) => `env bash ${op}\n${b}\n${d}`],
      ];
      if (!ctx.posix) forms.push(['bash', (b) => `source /dev/stdin ${op}\n${b}\n${d}`]);
      const [shell, form] = pick(forms);
      return form(shellBody({ ...ctx, posix: shell === 'sh' }, quoted));
    },
    compound: (ctx) => {
      const quoted = chance(0.7);
      const { d, op } = opener(quoted);
      const sh = chance(0.3);
      const body = shellBody({ ...ctx, posix: sh }, quoted);
      const runner = sh ? 'sh' : 'bash';
      const inner = `cat ${op}\n${body}\n${d}`;
      return pick([
        () => `{ ${inner}\n} | ${runner}`,
        () => `( ${inner}\n) | ${runner}`,
        () => `if true; then ${inner}\nfi | ${runner}`,
        () => `for i in 1; do ${inner}\ndone | ${runner}`,
        () => `case x in x) ${inner}\n;; esac | ${runner}`,
      ])();
    },
    compoundData: (ctx) => {
      const quoted = chance(0.6);
      const { d, op } = opener(quoted);
      const f = (files += 1);
      const inner = `cat ${op}\n${dataBody(ctx, quoted, 'data', d)}\n${d}`;
      return pick([
        () => `{ ${inner}\n} | sort >/dev/null`,
        () => `if true; then ${inner}\nfi | sort | uniq >/dev/null`,
        () => `for i in 1; do ${inner}\ndone > n${f}.md`,
        () => `{ ${inner}\n} > n${f}.md`,
      ])();
    },
    function: (ctx) => {
      const quoted = chance(0.7);
      const { d, op } = opener(quoted);
      const f = (files += 1);
      if (chance(0.5)) return `f${f}() { cat ${op}\n${shellBody({ ...ctx, posix: false }, quoted)}\n${d}\n}; f${f} | bash`;
      // The scanner keeps every function body, so these marks may show.
      return `f${f}() { cat ${op}\n${dataBody(ctx, quoted, 'quiet')}\n${d}\n}; f${f} >/dev/null`;
    },
    written: (ctx) => {
      const quoted = chance(0.7);
      const { d, op } = opener(quoted);
      const f = (files += 1);
      const runners = [
        [false, `bash s${f}.sh`],
        [false, `bash < s${f}.sh`],
        [false, `cat s${f}.sh | bash`],
        [true, `sh ./s${f}.sh`],
        [ctx.posix, `. ./s${f}.sh`],
      ];
      if (!ctx.posix) runners.push([false, `source s${f}.sh`]);
      const [posix, runner] = pick(runners);
      const body = shellBody({ ...ctx, posix }, quoted);
      const writers = [
        () => `cat > s${f}.sh ${op}\n${body}\n${d}\n${runner}`,
        () => `cat ${op} > s${f}.sh\n${body}\n${d}\n${runner}`,
        () => `tee s${f}.sh >/dev/null ${op}\n${body}\n${d}\n${runner}`,
        () => `{ cat ${op}\n${body}\n${d}\n} > s${f}.sh; ${runner}`,
      ];
      if (!ctx.noExpand && runner === `bash s${f}.sh`) {
        writers.push(() => `cat > "$PWD/s${f}.sh" ${op}\n${body}\n${d}\nbash "$PWD/s${f}.sh"`);
      }
      return pick(writers)();
    },
    writtenData: (ctx) => {
      const quoted = chance(0.6);
      const { d, op } = opener(quoted);
      const f = (files += 1);
      const reader = pick([`wc -l n${f}.md >/dev/null`, `cat n${f}.md >/dev/null`, `cat n${f}.md | sort >/dev/null`, `sort n${f}.md >/dev/null`]);
      return `cat > n${f}.md ${op}\n${dataBody(ctx, quoted, 'data', d)}\n${d}\n${reader}`;
    },
    procsub: (ctx) => {
      const quoted = chance(0.7);
      const { d, op } = opener(quoted);
      const body = marksOnly('racy');
      return pick([
        () => `cat ${op} > >(bash)\n${body}\n${d}\nsleep 0.1`,
        () => `tee >(bash) >/dev/null ${op}\n${body}\n${d}\nsleep 0.1`,
      ])();
    },
    comsubWord: (ctx) => {
      const { d, op } = opener(chance(0.5));
      return `$(cat ${op}\n${mark(ctx.runCls)}\n${d}\n)`;
    },
    whileRead: (ctx) => {
      const { d, op } = opener(chance(0.6));
      const body = marksOnly(ctx.runCls);
      return pick([
        () => `while read -r l; do $l; done ${op}\n${body}\n${d}`,
        () => `cat ${op} | while read -r l; do $l; done\n${body}\n${d}`,
      ])();
    },
    comment: (ctx) => {
      const noise = pick(ctx.noExpand ? ["it's", '<<EOF', 'say "hi', ''] : ["it's", '<<EOF', 'say "hi', '', '$(x']);
      return pick(['# % ', 'true # % <<E']).replace('%', `${noise} ${mark('data')}`);
    },
  };
  const LEAF = ['plain', 'data', 'writtenData', 'comsubWord', 'comment'];

  function statements(ctx, n) {
    const out = [];
    for (let k = 0; k < n; k += 1) {
      let names = ctx.depth >= 2 ? LEAF : Object.keys(KINDS);
      if (ctx.posix || ctx.runCls === 'racy') names = names.filter((name) => name !== 'procsub');
      if (ctx.noExpand) names = names.filter((name) => name !== 'whileRead' && name !== 'comsubWord');
      if (ctx.runCls === 'racy') names = LEAF;
      if (ctx.depth > 0) names = names.filter((name) => name !== 'procsub' || chance(0.3));
      out.push(KINDS[pick(names)](ctx));
    }
    return out.join('\n');
  }

  const command = statements({ depth: 0, runCls: 'run', posix: false, noExpand: false }, 2 + Math.floor(rnd() * 4));
  return { command, marks };
}

function fuzzFailures(seed, cases) {
  const rnd = mulberry32(seed);
  const failures = [];
  for (let n = 0; n < cases; n += 1) {
    const { command, marks } = generateCase(rnd);
    const pieces = executedPieces(command);
    const ran = new Set(runMarks(command));
    const problems = [];
    for (const id of ran) if (!lexVisible(pieces, id)) problems.push(`${id} ran but is in no piece outside quotes`);
    for (const { id, cls } of marks) {
      if (cls === 'run' && !ran.has(id)) problems.push(`${id} was built to run but bash did not run it`);
      if ((cls === 'data' || cls === 'quiet') && ran.has(id)) problems.push(`${id} was built as data but bash ran it`);
      if (cls === 'data' && visible(pieces, id)) problems.push(`${id} is data but is in a piece`);
    }
    if (problems.length) {
      failures.push({ seed, case: n, problems, command, pieces: pieces.map((p) => p.text) });
      if (failures.length >= 5) break;
    }
  }
  return failures;
}

test('#1853 seeded fuzz: every mark bash runs is in a piece, and data marks are in none', { skip: NO_BASH }, () => {
  const seed = Number(process.env.HEREDOC_FUZZ_SEED || 1853);
  const cases = Number(process.env.HEREDOC_FUZZ_CASES || 150);
  const failures = fuzzFailures(seed, cases);
  assert.deepStrictEqual(failures, [], JSON.stringify(failures, null, 2));
});

// ---------------------------------------------------------------------------
// Agreement with shape-rewrite's findHeredocs.
// ---------------------------------------------------------------------------

// Comment-free, arithmetic-free, substitution-free commands with no quotes,
// `<` or line continuations in bodies: findHeredocs masks quotes across bodies,
// rescans them for `<<` and does not join continuations, so outside this subset
// the two readers differ by design.
function agreementCase(rnd) {
  const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
  const words = ['alpha', 'beta', 'x', 'done', 'fi', '}', 'EOFX', 'a b c', '- item', 'k=v', ''];
  let delims = 0;
  const lines = [];
  const statements = 1 + Math.floor(rnd() * 4);
  for (let s = 0; s < statements; s += 1) {
    if (rnd() < 0.3) {
      lines.push(pick(['echo hi', 'true', 'cd sub']));
      continue;
    }
    const ops = [];
    const bodies = [];
    const count = rnd() < 0.25 ? 2 : 1;
    for (let k = 0; k < count; k += 1) {
      delims += 1;
      const d = `D${delims}`;
      const dash = rnd() < 0.3;
      const spec = pick([d, `'${d}'`, `"${d}"`, `\\${d}`]);
      ops.push(`<<${dash ? '-' : ''}${spec}`);
      const body = Array.from({ length: Math.floor(rnd() * 3) }, () => `${dash && rnd() < 0.5 ? '\t' : ''}${pick(words)}`);
      bodies.push([...body, `${dash && rnd() < 0.5 ? '\t\t' : ''}${d}`]);
    }
    lines.push(`cat ${ops.join(' ')} >/dev/null`);
    for (const body of bodies) lines.push(...body);
  }
  return lines.join('\n');
}

test('#1853 scanHeredocs agrees with shape-rewrite findHeredocs on their shared subset', () => {
  const rnd = mulberry32(1853);
  for (let n = 0; n < 300; n += 1) {
    const command = agreementCase(rnd);
    const ours = scanHeredocs(command).heredocs.map(({ delimiter, quoted, body }) => ({ delimiter, quoted, body }));
    const theirs = findHeredocs(command).map(({ delimiter, quoted, body }) => ({ delimiter, quoted, body }));
    assert.deepStrictEqual(ours, theirs, JSON.stringify(command));
  }
});
