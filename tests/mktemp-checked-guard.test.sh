#!/usr/bin/env bash
# mktemp-checked-guard.test.sh — Structural guard: every mktemp in every tracked shell
# file is checked where it runs (#443).
#
# WHY THIS EXISTS
#   On 2026-10-28 vastai.test.sh ran `rm -rf /home`. Four parallel suites had filled the
#   disk, so `TMP=$(mktemp -d ...)` failed with ENOSPC and left TMP empty. The suite ran
#   under `set -uo pipefail` (its runner's -e is not inherited by the child bash), set -u
#   is silent for a set-but-empty variable, and `HOMEDIR=$TMP/home` became /home, which
#   reset_home then deleted. No hook can see this: dcg and git-guard inspect the command
#   line an agent types, and this rm ran in a grandchild. shellcheck's SC2115 catches
#   `rm -rf "$VAR/x"` written directly, not a path derived through a second variable.
#   The failure needs a full disk, so running the code does not find it; the only
#   durable guard is structural (the lesson of pipefail-grep-q-guard.test.sh). The
#   guard was written in the private config repo this one replaced; #443 brought it
#   here and rewrote the 236 live sites. This keeps the count at zero.
#
# THE RULE (one verdict per mktemp, not per line)
#   VAR=$(mktemp ...) must be checked on the same statement: `|| exit 1` in a test or at
#   a script's top level, `|| return 1` in a function body, or any other `||` handler
#   (`|| { ...; }`, or `|| VAR=""` when the next line tests VAR) -- but not `|| true` or
#   `|| :`, which handle nothing. Inside an if/elif/while/until condition it is already
#   checked when it is the condition's last command (`if VAR=$(mktemp); then`, or only
#   `&&` before `then`); `if VAR=$(mktemp); :; then` tests `:`.
#   Rejected outright, whatever follows:
#     - `local|export|declare|readonly|typeset VAR=$(mktemp)`: the builtin's own status
#       (0) replaces mktemp's, so the `||` can never fire. Declare first, assign after.
#     - `$(mktemp)` as an argument (`cd -P -- "$(mktemp -d)"`): a failure becomes an
#       empty argument, and `cd ""` succeeds in the current directory. Assign, check,
#       then use the variable.
#     - backtick `mktemp`: use $( ) so the assignment carries the status.
#     - a later command that supplies the status the handler sees: `$(mktemp -d; cmd)`,
#       `$(mktemp -d | cmd)`, or a bare `mktemp -d; cmd || exit 1`. The handler then
#       fires on cmd's failure, not mktemp's.
#     - `$(mktemp)` in an unquoted heredoc body (`<<EOF`, `<<-EOT`): it still runs, and
#       a failure becomes empty text. A quoted delimiter (`<<'EOF'`) keeps the body inert.
#     - an assignment-shaped argument (`eval VAR=$(mktemp)`, `env VAR=$(mktemp) cmd`):
#       the command's status replaces mktemp's. Only a word in command position is an
#       assignment.
#   A same-file function whose body runs mktemp is a scratch helper, and `exit` inside
#   $( ) leaves only the subshell, so every `VAR=$(helper ...)` capture needs its own
#   check too (stash-reap.test.sh's mkrepo, 14 sites). The same holds for a helper in a
#   file the script sources from its own directory, one level deep:
#   `. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"`, or the same with "$0" (wsl-cdp's
#   make_fixture, 4 sites that would have run on with an empty fixture root).
#
# SCOPE
#   Every tracked file in the repo (git ls-files) that is a shell script: a .sh/.bash
#   extension, or a sh/bash shebang on line 1. The scanner lexes each file, so comments,
#   quoted strings, quoted heredoc bodies (fixture shims) and tool lists such as
#   `for need in jq mktemp` are not invocations. It runs on a fixture repo first, with
#   one planted positive per rejected shape and the safe forms as planted negatives,
#   so a clean live tree is a verdict and not a blind scanner. Not claimed: helpers
#   sourced any other way (a variable path, a source after `&&`, a second level of
#   sourcing), other command substitutions that feed rm paths, and run: blocks in
#   workflow YAML.
#
#   Left out by path: plugins/skill-tuner/experiments/ and plugins/skill-tuner/reports/.
#   Those hold the scripts models wrote during recorded eval runs. Nothing executes
#   them, and editing one would change the record of what the model produced. A new
#   path joins RECORDED only on the same two grounds.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*" >&2; }

cat > "$TMP/scan.py" <<'PY'
"""Report unchecked mktemp sites in a git work tree's tracked shell files.

usage: scan.py ROOT [--count | --brief]
Prints `relpath:line: reason: source line`, one per violation, in file and line
order; --brief drops the source line, --count prints only the number of shell
files discovered. A scanner failure exits nonzero, so silence always means clean.
"""
import os
import re
import subprocess
import sys

root = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else ''
SHEBANG = re.compile(rb'#!.*\b(ba)?sh\b')
RECORDED = ('plugins/skill-tuner/experiments/', 'plugins/skill-tuner/reports/')
TOKEN = re.compile(r'(?<![\w./-])(?:/usr/bin/|/bin/)?mktemp(?![\w.-])')
CMD_POS_END = re.compile(r'(?:^|[;&|({!`]|\b(?:then|do|else|elif|if|while|until|time|command|builtin|exec))$')
SUBST_START = re.compile(r'\$\(\s*(?:umask\s+[0-7]+\s*;\s*)?(?:command\s+)?$')
NAME_EQ = re.compile(r'([A-Za-z_]\w*(?:\[[^\]]*\])?\+?)=$')
DECL = re.compile(r'(?:^|[;&|({\s])(local|export|declare|readonly|typeset)(?:\s+[^;&|]*)?\s$')
COND_KW = re.compile(r'(?:^|[;&|({\s])(?:if|elif|while|until)\s')
STOPS_COND = re.compile(r';|\bthen\b|\bdo\b')
REDIRS = re.compile(r'^(?:\d*(?:>>?|<)&?\S*\s*)*')
CHECK = re.compile(r'^\|\|\s*')
SILENCER = re.compile(r'^(?:true|:)(?=$|[\s;)}&|])')
FNDEF = re.compile(r'(?m)^[ \t]*(?:function[ \t]+([A-Za-z_][\w:.-]*)[ \t]*(?:\([ \t]*\))?'
                   r'|([A-Za-z_][\w:.-]*)[ \t]*\([ \t]*\))\s*\{')
SOURCE_HERE = re.compile(r'(?m)^[ \t]*((?:\.|source)[ \t]+"\$\(dirname )"\$(?:\{BASH_SOURCE\[0\]\}|0)"\)'
                         r'(/[\w.-]+(?:/[\w.-]+)*)"')
HEREDOC = re.compile(r'<<(-?)[ \t]*((?:[\'"]?[A-Za-z_][\w.-]*[\'"]?)|\\[A-Za-z_][\w.-]*)')
ASSIGN_WORD = re.compile(r'[A-Za-z_]\w*(?:\[[^\]]*\])?\+?=\S*$')
CMD_POS_WORD = re.compile(r'(?:^|[;&|({!)]|\b(?:then|do|else|elif|if|while|until|time))$')
COND_END = re.compile(r'(?:then|do)(?![\w-])')
CONT = ('\\', '&&', '||', '|')
UNCHECKED = 'unchecked (add `|| exit 1`, or `|| return 1` in a function)'
COND_LATER = ('a later command in the condition supplies its status '
              '(make mktemp the last command before `then`/`do`)')
IN_HEREDOC = ('runs in an unquoted heredoc, where a failure becomes empty text '
              '(quote the delimiter, or assign, check, then use the variable)')


def shell_files():
    out = subprocess.run(['git', '-C', root, 'ls-files', '-z'], capture_output=True, check=True).stdout
    for raw in sorted(out.split(b'\0')):
        if not raw:
            continue
        rel = raw.decode()
        if rel.startswith(RECORDED):
            continue
        p = os.path.join(root, rel)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        if not rel.endswith(('.sh', '.bash')):
            with open(p, 'rb') as fh:
                if not SHEBANG.match(fh.readline()):
                    continue
        yield rel, p


def mask(src):
    """Same-length copy of src: comments and quoted heredoc bodies blanked, quoted text
    as _.

    Code, including $( ) nested in double quotes or in an unquoted heredoc body, is
    kept, so every surviving paren, brace, `||`, `;` and word is real syntax. Returns
    (masked, errors, spans), spans holding the [start, end) of each unquoted heredoc
    body."""
    out = list(src)
    n = len(src)
    # c code, p ( or $(, b ${, d "...", k `...`, a2 (( or $((, a1 ( inside arithmetic,
    # h an unquoted heredoc body (expands like "...", but a " in it is literal)
    stack = ['c']
    pending = []
    hdocs = []  # per open h: (delimiter, tabs, heredocs queued after it, body start)
    spans = []
    errors = []
    i = 0

    def blank(a, b, ch):
        for j in range(a, min(b, n)):
            if out[j] != '\n':
                out[j] = ch

    def delim_end(a, delim, tabs):
        """Index past the line starting at a when that line is delim, else -1."""
        e = src.find('\n', a)
        e = n if e < 0 else e
        line = src[a:e]
        return e + 1 if (line.lstrip('\t') if tabs else line) == delim else -1

    def bodies(a, queue):
        """Consume the heredoc bodies in queue from a: blank a quoted body, open h for
        an unquoted one and return its start. None when a body is unterminated."""
        while queue:
            delim, tabs, quoted = queue.pop(0)
            while True:
                if a >= n:
                    errors.append(f'unterminated heredoc {delim!r}')
                    return None
                end = delim_end(a, delim, tabs)
                if end >= 0:
                    blank(a, end, ' ')
                    a = end
                    break
                if not quoted:
                    stack.append('h')
                    hdocs.append((delim, tabs, queue, a))
                    return a
                e = src.find('\n', a)
                e = n if e < 0 else e
                blank(a, e, ' ')
                a = e + 1
        return a

    while i < n:
        c = src[i]
        top = stack[-1]
        if c == '\n' and top not in ('d', 'h') and pending:
            i = bodies(i + 1, pending)
            pending = []
            if i is None:
                return ''.join(out), errors, spans
            continue
        if top == 'h':
            if c == '\n':
                delim, tabs, queue, start = hdocs[-1]
                end = delim_end(i + 1, delim, tabs)
                if end >= 0:
                    blank(i + 1, end, ' ')
                    stack.pop()
                    hdocs.pop()
                    spans.append((start, i))
                    i = bodies(end, queue)
                    if i is None:
                        return ''.join(out), errors, spans
                    continue
            elif c == '\\':
                if i + 1 < n and src[i + 1] != '\n':
                    out[i + 1] = '_'
                out[i] = '_'
                i += 2
                continue
            elif src.startswith('$((', i):
                stack.append('a2')
                i += 3
                continue
            elif src.startswith('$(', i):
                stack.append('p')
                i += 2
                continue
            elif src.startswith('${', i):
                stack.append('b')
                i += 2
                continue
            elif c == '`':
                stack.append('k')
            else:
                out[i] = '_'
            i += 1
            continue
        if top == 'd':
            if c == '\\':
                if i + 1 < n and src[i + 1] != '\n':
                    out[i + 1] = '_'
                out[i] = '_'
                i += 2
                continue
            if c == '"':
                stack.pop()
            elif src.startswith('$((', i):
                stack.append('a2')
                i += 3
                continue
            elif src.startswith('$(', i):
                stack.append('p')
                i += 2
                continue
            elif src.startswith('${', i):
                stack.append('b')
                i += 2
                continue
            elif c == '`':
                stack.append('k')
            elif c != '\n':
                out[i] = '_'
            i += 1
            continue
        if top in ('a1', 'a2'):
            if c == '"':
                stack.append('d')
            elif top == 'a2' and src.startswith('))', i):
                stack.pop()
                i += 2
                continue
            elif c == ')' and top == 'a1':
                stack.pop()
            elif c == '(':
                stack.append('a1')
            i += 1
            continue
        # code-like contexts: c, p, b, k
        if c == '\\':
            if i + 1 < n and src[i + 1] != '\n':
                out[i + 1] = '_'
            i += 2
            continue
        if c == "'":
            ansi = i > 0 and src[i - 1] == '$'
            j = i + 1
            while j < n and src[j] != "'":
                j += 2 if (ansi and src[j] == '\\') else 1
            blank(i + 1, j, '_')
            i = j + 1
            continue
        if c == '"':
            stack.append('d')
            i += 1
            continue
        if c == '#' and top != 'b' and (i == 0 or src[i - 1] in ' \t\n;&|()'):
            e = src.find('\n', i)
            e = n if e < 0 else e
            blank(i, e, ' ')
            i = e
            continue
        if src.startswith('$((', i):
            stack.append('a2')
            i += 3
            continue
        if src.startswith('((', i):
            stack.append('a2')
            i += 2
            continue
        if src.startswith('$(', i):
            stack.append('p')
            i += 2
            continue
        if src.startswith('${', i):
            stack.append('b')
            i += 2
            continue
        if c == '(':
            stack.append('p')
        elif c == ')' and top == 'p':
            stack.pop()
        elif c == '}' and top == 'b':
            stack.pop()
        elif c == '`':
            if top == 'k':
                stack.pop()
            else:
                stack.append('k')
        elif src.startswith('<<', i) and not src.startswith('<<<', i) and (i == 0 or src[i - 1] != '<'):
            h = HEREDOC.match(src, i)
            if h:
                word = h.group(2)
                pending.append((word.strip('\'"\\'), h.group(1) == '-',
                                any(q in word for q in '\'"\\')))
                i = h.end()
                continue
        i += 1
    if pending or hdocs:
        errors.append(f'unterminated heredoc {(pending or hdocs)[0][0]!r}')
    return ''.join(out), errors, spans


def logical_bounds(m, pos):
    """[start, end) of the statement around pos: backslash continuations and lines
    ending in && || | join the next line."""
    s = m.rfind('\n', 0, pos) + 1
    while s > 0:
        ps = m.rfind('\n', 0, s - 1) + 1
        if not m[ps:s - 1].rstrip().endswith(CONT):
            break
        s = ps
    e = m.find('\n', pos)
    while e >= 0 and m[m.rfind('\n', 0, e) + 1:e].rstrip().endswith(CONT):
        e = m.find('\n', e + 1)
    return s, (len(m) if e < 0 else e)


def close_paren(m, open_at):
    depth = 0
    for j in range(open_at, len(m)):
        if m[j] == '(':
            depth += 1
        elif m[j] == ')':
            depth -= 1
            if depth == 0:
                return j
    return -1


def in_condition(before):
    last = None
    for last in COND_KW.finditer(before):
        pass
    return last is not None and not STOPS_COND.search(before[last.end():])


def ends_condition(m, at):
    """True when nothing after index at (past the mktemp command or its $( )) can
    supply the condition's status: only `&&` continuations, then `then` or `do`."""
    k, op = -1, '&&'
    while op == '&&':
        k, op = next_operator(m, at, len(m))
        at = k + 2
    return op in (';', 'newline') and COND_END.match(m[k + 1:].lstrip()) is not None


def argument_of(bb):
    """The word that takes an assignment following bb as an argument (`eval`, `env`, ...),
    or None when the assignment is in command position: after an operator, a keyword
    or another assignment."""
    rest = bb.rstrip()
    while not CMD_POS_WORD.search(rest):
        word = rest.split()[-1]
        if not ASSIGN_WORD.match(word):
            return word
        rest = rest[:-len(word)].rstrip()
    return None


def handled(after):
    """None when `after` (text following the command) starts with a real || handler,
    else the reason it does not."""
    after = REDIRS.sub('', after.replace('\\\n', ' ').lstrip()).lstrip()
    c = CHECK.match(after)
    if not c:
        return UNCHECKED
    return '`|| true` / `|| :` is not a check' if SILENCER.match(after[c.end():]) else None


def next_operator(m, a, b):
    """(index, operator) of the first list or pipe operator in m[a:b] at the depth of a,
    or (-1, None). Text inside ( ) and ${ } is skipped. A newline counts unless the last
    non-blank text before it (even before a, as after `&&`) continues the line, or only
    blank text follows it; redirections such as 2>&1, &> and >| are not operators."""
    depth = braces = 0
    i = a
    while i < b:
        c = m[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        elif c == '{' and m[i - 1] == '$':
            braces += 1
        elif c == '}' and braces:
            braces -= 1
        elif depth == 0 and braces == 0:
            if c == '\n':
                j = i
                while j > 0 and m[j - 1] in ' \t\n':
                    j -= 1
                if not m.endswith(CONT, 0, j) and m[i:b].strip():
                    return i, 'newline'
            elif c == ';':
                return i, ';'
            elif c in '|&':
                two = m[i:i + 2]
                if two in ('||', '&&'):
                    return i, two
                if m[i - 1] in '<>' or (c == '&' and two == '&>'):
                    i += 1
                    continue
                return i, c
        i += 1
    return -1, None


def masked_in_subst(m, head, q):
    """Why the $( ) closing at q may not return the status of the command word ending
    at head, or None. Any later command is rejected, even after `&&`: keep the
    allocation alone in its $( )."""
    _, op = next_operator(m, head, q)
    if not op:
        return None
    where = 'on a new line' if op == 'newline' else f'after `{op}`'
    return f'a later command {where} inside $( ) can supply its status (keep mktemp alone in the $( ))'


def judge_subst(m, dollar, head, spans):
    """Verdict for the $( ) starting at index dollar, whose command word ends at head,
    or None when it is checked."""
    q = close_paren(m, dollar + 1)
    if q < 0:
        return 'scanner: unbalanced $( )'
    if any(a <= dollar < b for a, b in spans):
        return IN_HEREDOC
    masked = masked_in_subst(m, head, q)
    if masked:
        return masked
    s, _ = logical_bounds(m, dollar)
    before = m[s:dollar].replace('\\\n', ' ')
    before = before[:-1] if before.endswith('"') else before
    nm = NAME_EQ.search(before)
    if not nm:
        return 'passed as an argument (assign it, check it, then use the variable)'
    bb = before[:nm.start()]
    d = DECL.search(bb)
    if d:
        return f'status masked by `{d.group(1)}` (declare first, then assign and check)'
    word = argument_of(bb)
    if word:
        return (f'an argument to `{word}`, not an assignment, so `{word}` supplies the status '
                '(assign it in command position, check it, then use the variable)')
    _, e = logical_bounds(m, q)
    after = m[q + 1:e]
    after = after[1:] if after.startswith('"') else after
    why = handled(after)
    if why == UNCHECKED and in_condition(bb):
        return None if ends_condition(m, q + 1) else COND_LATER
    return why


PARSED = {}
KNOWN = {}  # relpath -> path of every shell file under scan, filled before the first scan


def parse(path):
    """(src, masked, errors, heredoc spans, mktemp invocations, scratch helpers) of one
    file, read once: for its own scan and for each file that sources it."""
    if path in PARSED:
        return PARSED[path]
    with open(path, encoding='utf-8', errors='replace') as fh:
        src = fh.read()
    m, errors, spans = mask(src)
    invocations = []
    for t in TOKEN.finditer(m):
        s, _ = logical_bounds(m, t.start())
        if CMD_POS_END.search(m[s:t.start()].rstrip()):
            invocations.append((t.start(), t.end()))
    helpers = set()
    for f in FNDEF.finditer(m):
        brace = f.end() - 1
        depth, j = 0, brace
        while j < len(m):
            if m[j] == '{':
                depth += 1
            elif m[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if any(brace < p < j for p, _ in invocations):
            helpers.add(f.group(1) or f.group(2))
    PARSED[path] = (src, m, errors, spans, invocations, helpers)
    return PARSED[path]


def sourced_helpers(rel, src, m):
    """{helper: file} for the scratch helpers of each scanned file that rel sources from
    its own directory. The line is matched in src and must be code in m, so a source
    line in a comment, a string or a heredoc body sources nothing."""
    out = {}
    for s in SOURCE_HERE.finditer(src):
        a, b = s.span(1)
        if m[a:b] != src[a:b]:
            continue
        target = os.path.normpath(os.path.join(os.path.dirname(rel), s.group(2)[1:]))
        if target != rel and target in KNOWN:
            for h in parse(KNOWN[target])[5]:
                out.setdefault(h, target)
    return out


def scan(rel, path):
    src, m, errors, spans, invocations, helpers = parse(path)
    lines = src.split('\n')
    found = []

    def report(pos, why):
        ln = m.count('\n', 0, pos) + 1
        found.append((rel, ln, why, lines[ln - 1].strip()[:160]))

    for err in errors:
        found.append((rel, 0, f'scanner: {err}', ''))
    for p, word_end in invocations:
        s, e = logical_bounds(m, p)
        pre = m[s:p]
        if pre.rstrip().endswith('`'):
            report(p, 'backtick mktemp (use $( ) so the assignment carries the status)')
            continue
        # the enclosing $( may sit on an earlier line: J=$(\n  mktemp -d\n)
        window = m[max(0, p - 400):p]
        sm = SUBST_START.search(window)
        if sm:
            dollar = p - len(window) + sm.start()
            why = judge_subst(m, dollar, word_end, spans)
            if why:
                report(dollar, why)
            continue
        # The handler must follow mktemp itself: after `&&` a failed mktemp still
        # reaches the next `||`, after `;`, `&`, a pipe or a new line it does not.
        k, op, at = -1, '&&', word_end
        while op == '&&':
            k, op = next_operator(m, at, e)
            at = k + 2
        why = handled(m[k:e]) if op == '||' else UNCHECKED
        if why == UNCHECKED and in_condition(pre):
            why = None if ends_condition(m, word_end) else COND_LATER
        if why:
            report(p, why if why != UNCHECKED else 'unchecked bare mktemp (add `|| return 1`)')
    borrowed = sourced_helpers(rel, src, m)
    for h in sorted(helpers | set(borrowed)):
        origin = '' if h in helpers else f' from {borrowed[h]}'
        for c in re.finditer(r'\$\(\s*' + re.escape(h) + r'(?![\w:.-])', m):
            why = judge_subst(m, c.start(), c.end(), spans)
            if why:
                report(c.start(), f'captures scratch helper {h}(){origin}, {why}')
    return found


files = list(shell_files())
KNOWN.update(files)
if mode == '--count':
    print(len(files))
    sys.exit(0)
hits = set()
for rel, path in files:
    hits.update(scan(rel, path))
for rel, ln, why, text in sorted(hits):
    print(f'{rel}:{ln}: {why}' if mode == '--brief' else f'{rel}:{ln}: {why}: {text}')
PY

scan() { python3 -I "$TMP/scan.py" "$@"; }

# ---- 1. Scanner self-test on a fixture repo ----------------------------------
FX="$TMP/fx"
mkdir -p "$FX/bin" "$FX/docs"
git -C "$FX" init -q || exit 1
M='mk''temp'   # spliced so these source lines never read as invocations themselves
{
  echo '#!/usr/bin/env bash'
  echo "A=\$($M -d)"
  echo "B=\$($M) || true "
  echo "f() { local C=\$($M -d) || exit 1; }"
  echo "cd -P -- \"\$($M -d)\" && pwd -P"
  echo "D=\$(/usr/bin/$M -d)"
  echo "E=\$($M) || exit 1; F=\$($M)"
  echo "G=\`$M\`"
  echo 'n=$(( 1 << 2 ))'
  echo "export H=\$($M -d) || exit 1"
  echo "I=\"\$($M)\" 2>/dev/null"
  echo 'mkscratch() {'
  echo "  d=\$($M -d) || exit 1"
  echo '  echo "$d"'
  echo '}'
  echo 'R=$(mkscratch)'
  echo "J=\$("
  echo "  $M -d"
  echo ")"
  echo "K=\$($M) || :"
  echo "T=\$($M -d; printf '') || exit 1"
  echo "$M -d; printf '' || exit 1"
  echo "U=\$($M -d | tee x) || exit 1"
  echo "$M -d | tee x || exit 1"
  echo "V=\$($M -d"
  echo "  printf '') || exit 1"
  echo "W=\$($M -d && echo made) || exit 1"
  echo "X=\$(cat <<EOF"
  echo "\$($M -d)"
  echo 'EOF'
  echo ') || exit 1'
  printf 'cat <<-EOT\n\tL=$(%s)\n\tEOT\n' "$M"
  echo "if Y=\$($M -d); :; then :; fi"
  echo "if $M -d >/dev/null; :; then :; fi"
  echo "while Z=\$($M); false; do break; done"
  echo "eval AA=\$($M -d) || exit 1"
  echo "env BB=\$($M) true || exit 1"
} > "$FX/pos.sh"
{
  echo '#!/bin/sh'
  echo "tmp=\$($M)"
  echo '. "$(dirname "$0")/../lib/scratch-lib.sh"'
  echo 'dir=$(mklib)'
} > "$FX/bin/pos-extensionless"
# A sourced helper is clean where it is defined, and a scratch helper in every file that
# sources it from its own directory. A source line that is not code, or that names its
# file through a variable, brings nothing in.
mkdir -p "$FX/lib" || exit 1
{
  echo 'mklib() {'
  echo '  local d'
  echo "  d=\$($M -d) || return 1"
  echo '  echo "$d"'
  echo '}'
} > "$FX/lib/scratch-lib.sh"
{
  echo '#!/usr/bin/env bash'
  echo '. "$(dirname "${BASH_SOURCE[0]}")/lib/scratch-lib.sh"'
  echo 'A=$(mklib)'
  echo 'B="$(mklib)"; echo "$B"'
  echo 'C=$(mklib) || exit 1'
} > "$FX/pos-sourced.sh"
{
  echo '# . "$(dirname "${BASH_SOURCE[0]}")/lib/scratch-lib.sh"'
  echo "cat <<'EOF'"
  echo 'source "$(dirname "$0")/lib/scratch-lib.sh"'
  echo 'EOF'
  echo '. "$HERE/lib/scratch-lib.sh"'
  echo 'N=$(mklib)'
} > "$FX/neg-not-sourced.sh"
{
  echo 'set -euo pipefail'
  echo "A=\$($M -d) || exit 1"
  echo "B=\"\$($M)\" || { echo no >&2; exit 1; }"
  echo "C=\$($M -d \"\$T/x.XXXX\") \\"
  echo '  || exit 1'
  echo "if D=\$($M); then :; fi"
  echo "if ! E=\$($M -d 2>/dev/null); then exit 1; fi"
  echo "while F=\$($M); do break; done"
  echo "if [ -n \"\$x\" ] &&"
  echo "   F2=\$($M); then :; fi"
  echo "G=\$($M) 2>/dev/null || G=\"\""
  echo "H=\$(umask 077; $M) || exit 1"
  echo "# I=\$($M) is unsafe without a check"
  echo "echo \"J=\\\$($M) failed\" >&2"
  echo "log \"could not run $M -d here\""
  echo "for need in jq realpath $M; do :; done"
  echo "command -v $M >/dev/null || exit 1"
  echo 'cat > "$T/shim" <<'"'EOF'"
  echo "K=\$($M)"
  echo 'EOF'
  printf "cat <<-'EOT'\n\tL=\$(%s)\n\tEOT\n" "$M"
  echo "echo '$M'"
  echo 'mkok() { local d; d=$('"$M"' -d) || return 1; echo "$d"; }'
  echo 'R=$(mkok) || exit 1'
  echo "case \$x in a) N=\$($M) || exit 1 ;; esac"
  echo "x=\$(( (1 + 2) << 2 )); O=\$($M) || exit 1"
  echo "P=\$($M) ||"
  echo '  exit 1'
  echo "Q=\$("
  echo "  $M -d"
  echo ") || exit 1"
  echo "S=\$($M -d 2>&1) || exit 1"
  echo "X=\$($M -d \"\${TMPDIR:-/tmp}/x.XXXXXX\") || exit 1"
  echo "Y=\$($M -p \"\$(dirname \"\$f\")\") || exit 1"
  echo "$M -d \"\$T/dir.XXXX\" >/dev/null || exit 1"
  echo "$M -d >/dev/null && echo made || exit 1"
  echo "if $M -d \"\$T/x.XXXX\" >/dev/null; then :; fi"
  echo "if Y=\$($M -d) && [ -d \"\$Y\" ]; then :; fi"
  echo "if Z=\$($M)"
  echo 'then :; fi'
  echo "if Z2=\$($M) &&"
  echo '   [ -f "$Z2" ]; then :; fi'
  echo "$M -d >/dev/null &&"
  echo '  echo made || exit 1'
  echo 'cat <<EOF'
  echo "run $M -d yourself, or \\\$($M)"
  echo 'home is $(pwd)'
  echo 'EOF'
  echo 'cat <<\EOF'
  echo "N2=\$($M)"
  echo 'EOF'
  echo "AB=1 AC=\$($M) || exit 1"
  echo 'source "$(dirname "${BASH_SOURCE[0]}")/lib/scratch-lib.sh"'
  echo 'SL=$(mklib) || exit 1'
} > "$FX/neg-safe-forms.sh"
echo "A=\$($M -d)" > "$FX/docs/not-a-shell-file.md"
printf 'no shebang, no extension\nA=$(%s -d)\n' "$M" > "$FX/bin/no-shebang"
# A recorded eval output is left out; the same script one directory over is not, so
# the exclusion is the two named trees and nothing wider (pos.sh covers that side).
mkdir -p "$FX/plugins/skill-tuner/reports/run-1" "$FX/plugins/skill-tuner/experiments/ab" || exit 1
printf '#!/bin/bash\nA=$(%s -d)\n' "$M" > "$FX/plugins/skill-tuner/reports/run-1/install.sh"
printf '#!/bin/bash\nA=$(%s -d)\n' "$M" > "$FX/plugins/skill-tuner/experiments/ab/install.sh"
git -C "$FX" add -A || exit 1
printf '#!/bin/bash\nA=$(%s -d)\n' "$M" > "$FX/untracked.sh"   # git ls-files never lists it

U='unchecked (add `|| exit 1`, or `|| return 1` in a function)'
H='runs in an unquoted heredoc, where a failure becomes empty text (quote the delimiter, or assign, check, then use the variable)'
CL='a later command in the condition supplies its status (make mktemp the last command before `then`/`do`)'
FX_HITS=$(scan "$FX" --brief) || bad "scanner exited nonzero on the fixture repo"
SH='captures scratch helper mklib() from lib/scratch-lib.sh'
FX_EXPECT="bin/pos-extensionless:2: $U
bin/pos-extensionless:4: $SH, $U
pos-sourced.sh:3: $SH, $U
pos-sourced.sh:4: $SH, $U
pos.sh:2: $U
pos.sh:3: \`|| true\` / \`|| :\` is not a check
pos.sh:4: status masked by \`local\` (declare first, then assign and check)
pos.sh:5: passed as an argument (assign it, check it, then use the variable)
pos.sh:6: $U
pos.sh:7: $U
pos.sh:8: backtick mktemp (use \$( ) so the assignment carries the status)
pos.sh:10: status masked by \`export\` (declare first, then assign and check)
pos.sh:11: $U
pos.sh:16: captures scratch helper mkscratch(), $U
pos.sh:17: $U
pos.sh:20: \`|| true\` / \`|| :\` is not a check
pos.sh:21: a later command after \`;\` inside \$( ) can supply its status (keep mktemp alone in the \$( ))
pos.sh:22: unchecked bare mktemp (add \`|| return 1\`)
pos.sh:23: a later command after \`|\` inside \$( ) can supply its status (keep mktemp alone in the \$( ))
pos.sh:24: unchecked bare mktemp (add \`|| return 1\`)
pos.sh:25: a later command on a new line inside \$( ) can supply its status (keep mktemp alone in the \$( ))
pos.sh:27: a later command after \`&&\` inside \$( ) can supply its status (keep mktemp alone in the \$( ))
pos.sh:29: $H
pos.sh:33: $H
pos.sh:35: $CL
pos.sh:36: $CL
pos.sh:37: $CL
pos.sh:38: an argument to \`eval\`, not an assignment, so \`eval\` supplies the status (assign it in command position, check it, then use the variable)
pos.sh:39: an argument to \`env\`, not an assignment, so \`env\` supplies the status (assign it in command position, check it, then use the variable)"
[ "$FX_HITS" = "$FX_EXPECT" ] && ok || bad "fixture scan: expected exactly the planted positives; got:
$FX_HITS"

FX_FILES=$(scan "$FX" --count) || bad "scanner exited nonzero counting the fixture repo"
[ "$FX_FILES" = 6 ] && ok || bad "fixture discovery: expected 6 tracked shell files (pos.sh, pos-sourced.sh, bin/pos-extensionless, neg-safe-forms.sh, neg-not-sourced.sh, lib/scratch-lib.sh; the .md, the no-shebang file, the untracked file and the two recorded eval outputs stay out), got $FX_FILES"

# ---- 2. The live tree ---------------------------------------------------------
LIVE_FILES=$(scan "$REPO" --count) || bad "scanner exited nonzero counting $REPO"
[ "${LIVE_FILES:-0}" -ge 300 ] 2>/dev/null && ok || bad "live discovery reached only ${LIVE_FILES:-0} tracked shell files under $REPO; the scanner is not seeing the tree"

LIVE_HITS=$(scan "$REPO") || bad "scanner exited nonzero on $REPO"
[ -z "$LIVE_HITS" ] && ok || bad "unchecked mktemp (an empty scratch path turns rm -rf \"\$TMP/x\" into rm -rf /x, #443):
$LIVE_HITS"

echo "mktemp-checked-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
