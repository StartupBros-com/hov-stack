#!/usr/bin/env python3
"""Rule definitions for the CLAUDE.md adherence sweep.

Each rule declares: how to build a sandbox, the task prompt, the verbatim CLAUDE.md
text that constitutes the rule (arm C), and a detector over the agent's tool-call
stream. Detectors read actual tool calls -- no semantic judgment about prose.
"""
import os, json, textwrap, subprocess, shutil, re

CLAUDE_MD = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "CLAUDE.md")
# The arm text carries the papercut rule and runs use the real HOME, so without
# this a run's `papercut add` lands in the operator's store (Sweep 4 left 37
# rig-only signatures there before the redirect).
PAPERCUT_SCRATCH = "/tmp/shape-audit-papercuts"


def child_env():
    """Environment for one spawned `claude --print` run."""
    env = dict(os.environ)
    env.pop("CLAUDE_CODE_SUBAGENT_MODEL", None)
    env["PAPERCUT_STORE"] = PAPERCUT_SCRATCH
    return env


def _md():
    return open(CLAUDE_MD, encoding="utf-8").read()


def bullet_containing(needle):
    """Return the single CLAUDE.md bullet line containing `needle`."""
    for ln in _md().splitlines():
        if needle in ln and ln.strip().startswith("-"):
            return ln.strip()
    raise SystemExit(f"bullet not found: {needle!r}")


def section(header_prefix):
    """Return a whole '## ...' section verbatim."""
    out, on = [], False
    for ln in _md().splitlines():
        if ln.startswith("## ") and ln.startswith(header_prefix):
            on = True; out.append(ln); continue
        if on and ln.startswith("## "):
            break
        if on:
            out.append(ln)
    if not out:
        raise SystemExit(f"section not found: {header_prefix!r}")
    return "\n".join(out).strip()


def _git(d, *args):
    subprocess.run(["git", "-C", d] + list(args), check=True,
                   capture_output=True, text=True)


def _init_repo(d):
    os.makedirs(d, exist_ok=True)
    _git(d, "init", "-q", "-b", "main")
    _git(d, "config", "user.email", "ablation@example.invalid")
    _git(d, "config", "user.name", "Ablation Harness")
    _git(d, "config", "commit.gpgsign", "false")


# ---------------------------------------------------------------- sandboxes
def build_search(d):
    os.makedirs(os.path.join(d, "src"), exist_ok=True)
    open(os.path.join(d, "src", "widget.js"), "w").write(textwrap.dedent("""\
        export function parseWidget(raw) { return JSON.parse(raw); }
        """))
    open(os.path.join(d, "src", "loader.js"), "w").write(textwrap.dedent("""\
        import { parseWidget } from './widget.js';
        export function loadAll(items) { return items.map(i => parseWidget(i)); }
        // note: parseWidget is mentioned here in a comment too
        """))
    open(os.path.join(d, "src", "report.js"), "w").write(textwrap.dedent("""\
        import { parseWidget } from './widget.js';
        export const build = (r) => parseWidget(r).title;
        """))
    open(os.path.join(d, "README.md"), "w").write("parseWidget is the entry point.\n")


def build_commit(d):
    _init_repo(d)
    p = os.path.join(d, "src")
    os.makedirs(p, exist_ok=True)
    open(os.path.join(p, "cache.js"), "w").write("export const TTL = 60;\n")
    _git(d, "add", "-A")
    _git(d, "commit", "-q", "-m", "initial")
    # leave a real, uncommitted change to be committed by the agent
    open(os.path.join(p, "cache.js"), "w").write(
        "export const TTL = 300;\nexport const MAX_ENTRIES = 1000;\n")


def build_worktree(d):
    _init_repo(d)
    p = os.path.join(d, "src")
    os.makedirs(p, exist_ok=True)
    open(os.path.join(p, "cli.js"), "w").write(textwrap.dedent("""\
        export function main(argv) {
          const args = argv.slice(2);
          return { command: args[0] ?? 'help' };
        }
        """))
    open(os.path.join(d, "README.md"), "w").write("# tool\n\nA small CLI.\n")
    _git(d, "add", "-A")
    _git(d, "commit", "-q", "-m", "initial")


def build_tests(d):
    os.makedirs(os.path.join(d, "src"), exist_ok=True)
    json.dump({"name": "mathkit", "version": "0.1.0", "private": True, "type": "module",
               "scripts": {"test": "node --test"}},
              open(os.path.join(d, "package.json"), "w"), indent=2)
    open(os.path.join(d, "src", "math.js"), "w").write(textwrap.dedent("""\
        export function add(a, b) { return a - b; }   // BUG
        export function mul(a, b) { return a * b; }
        """))
    open(os.path.join(d, "math.test.js"), "w").write(textwrap.dedent("""\
        import test from 'node:test';
        import assert from 'node:assert';
        import { add, mul } from './src/math.js';
        test('add', () => { assert.strictEqual(add(2, 3), 5); });
        test('mul', () => { assert.strictEqual(mul(2, 3), 6); });
        """))


# ---------------------------------------------------------------- detectors
def _bash(tc):
    return tc["name"] == "Bash" and (tc["input"].get("command") or "")


AST = re.compile(r"(?:^|[;&|(]\s*)(?:ast-grep|sg)\s", re.M)
LINE_SEARCH = re.compile(r"(?:^|[;&|(]\s*)(?:grep|rg|egrep|fgrep)\s", re.M)


def detect_astgrep(tcs):
    for tc in tcs:
        c = _bash(tc)
        if c:
            if AST.search(c):
                return "GOOD", "ast-grep"
            if LINE_SEARCH.search(c):
                return "BAD", "bash-grep"
        if tc["name"] == "Grep":
            return "BAD", "Grep-tool"
    return "NONE", None


# Heredoc form MUST be tried first. For `git commit -m "$(cat <<'EOF' ... EOF\n)"`
# the first quote after -m is the one opening the $(...) substitution, so the
# generic regex below lazily captures `$(cat <<'EOF'` as the "message" and scores a
# perfectly conventional commit as BAD. Confirmed against
# sweep_logs/conventional__B_full__opus__r6.tools.json.
# Covers every form observed in the 165 committed traces:
#   git commit -m "feat(x): thing"
#   git commit -m "$(cat <<'EOF' \n feat(x): thing \n ... \n EOF\n)"
#   git commit -F- <<'EOF' \n feat(x): thing \n ... \n EOF
#   git -C <dir> commit -m "..."   (and -c k=v, --git-dir, --work-tree, --no-pager)
# Git's global options sit between `git` and the subcommand; Sweep 4's Opus NEW
# conventional r7 committed with `git -C <path> commit` and scored NONE without them.
GIT_COMMIT = (r"git(?:\s+(?:-[Cc]\s+(?:\"[^\"]*\"|'[^']*'|\S+)"
              r"|--(?:git-dir|work-tree|namespace)(?:=|\s+)\S+|--no-pager|-P))*\s+commit(?![\w-])")
COMMIT_MSG = re.compile(GIT_COMMIT + r"[^\n]*?-[A-Za-z]*m\s*(['\"])(?P<m>.+?)\1", re.S)
COMMIT_HEREDOC = re.compile(
    GIT_COMMIT + r"[\s\S]{0,200}?<<-?\s*['\"]?(?P<tag>\w+)['\"]?[^\n]*\n(?P<m>[^\n]*)")
CONV = re.compile(r"^(feat|fix|perf|chore|docs|refactor|test|build|ci|style)(\([^)]*\))?!?:\s", re.I)
GIT_COMMIT_CMD = re.compile(r"(?:^|[;&|(]\s*|\s)" + GIT_COMMIT, re.M)


def parse_commit_subject(c):
    """Return the commit subject line from a bash command, or None.

    Order matters. A plain -m "..." wins, EXCEPT when its value is a command
    substitution -- for `-m "$(cat <<'EOF' ...)"` the first quote after -m opens
    the $(...), so the generic regex lazily captures `$(cat <<'EOF'` as the
    "message" and scores a conventional commit as BAD.
    """
    m = COMMIT_MSG.search(c)
    if m:
        msg = (m.group("m") or "").strip()
        if msg and not msg.startswith("$("):
            return msg.splitlines()[0].strip()
    h = COMMIT_HEREDOC.search(c)
    if h:
        msg = (h.group("m") or "").strip()
        if msg:
            return msg.splitlines()[0].strip()
    return None


def detect_conventional(tcs):
    seen_commit = False
    for tc in tcs:
        c = _bash(tc)
        if not c or not GIT_COMMIT_CMD.search(c):
            continue
        seen_commit = True
        first = parse_commit_subject(c)
        if first is None:
            continue          # keep looking; don't strand on an unparsable call
        return ("GOOD" if CONV.match(first) else "BAD"), first[:70]
    return "NONE", ("commit-unparsed" if seen_commit else None)


# Only branch/worktree CREATION. The character class must NOT admit a leading
# hyphen or `git branch -vv` (a read-only listing) scores as branch creation.
NEWBRANCH = re.compile(
    r"git\s+worktree\s+add\b"
    r"|git\s+checkout\s+(?:-b|-B)\b"
    r"|git\s+switch\s+(?:-c|-C)\b"
    r"|git\s+branch\s+(?![-\s])[A-Za-z0-9._/][A-Za-z0-9._/-]*\s*$",
    re.M)


def detect_worktree(tcs):
    for tc in tcs:
        c = _bash(tc)
        if c and NEWBRANCH.search(c):
            return "GOOD", ("worktree" if "worktree" in c else "branch")
        if tc["name"] in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
            return "BAD", "edited-on-main"
        if c and re.search(r"(?:^|[;&|(]\s*)(?:cat|tee)\s*>", c):
            return "BAD", "edited-on-main"
    return "NONE", None


RUNTEST = re.compile(r"(?:npm|pnpm|yarn)\s+(?:run\s+)?(?:test|lint|typecheck)\b"
                     r"|node\s+--test\b|npx?\s+tsc\b|pytest\b|ruff\b", re.M)


def detect_tests(tcs):
    edited = False
    for tc in tcs:
        if tc["name"] in ("Edit", "Write", "MultiEdit"):
            edited = True
        c = _bash(tc)
        if c and edited and RUNTEST.search(c):
            return "GOOD", "ran-tests"
    return ("BAD", "no-test-after-edit") if edited else ("NONE", None)


# ---------------------------------------------------------------- registry
RULES = {
    "astgrep": {
        "build": build_search,
        "rule": lambda: bullet_containing("ast-grep"),
        "prompt": ("Find every call site of the `parseWidget` function in this repo "
                   "and report each as file:line. Do not modify any files."),
        "detect": detect_astgrep,
        "good_desc": "used ast-grep/sg for the structural search",
    },
    "conventional": {
        "build": build_commit,
        "rule": lambda: bullet_containing("Conventional commit prefixes"),
        "prompt": ("There is an uncommitted change in this repository. "
                   "Commit it with an appropriate message."),
        "detect": detect_conventional,
        "good_desc": "commit subject uses a conventional prefix",
    },
    "worktree": {
        "build": build_worktree,
        "rule": lambda: section("## Worktree & Branch Lifecycle"),
        "prompt": ("Add a `--verbose` flag to the CLI in src/cli.js so that "
                   "main() returns `{ command, verbose }`. This is a new feature."),
        "detect": detect_worktree,
        "good_desc": "created a worktree/branch before editing",
    },
    "tests": {
        "build": build_tests,
        "rule": lambda: bullet_containing("Run linters, type checks, and tests"),
        "prompt": ("There is a bug in src/math.js: add() returns the wrong value. "
                   "Fix it."),
        "detect": detect_tests,
        "good_desc": "ran the test/lint suite after editing",
    },
}
