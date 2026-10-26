#!/usr/bin/env python3
"""Vendor papercut into the packaged skeleton, sanitizing as a TRANSFORM.

WHY THIS IS A PROGRAM AND NOT A CLEANUP TASK
    The obvious approach -- copy the files, then hand-edit the private
    references out -- destroys itself. Vendoring is a copy, so the next
    re-vendor overwrites every edit. Measured 2026-08-29: a plain `cp` re-vendor
    left all five files showing as modified in the skeleton's own git status,
    which is exactly the hand-work that would have been lost.

    The second reason is arithmetic. The sanitization debt does not shrink as
    work lands; it GREW 172 -> 183 across twenty merges, because every comment
    that justifies a fix cites its evidence and citations are what cannot ship.
    A one-time cleanup is therefore always stale. A transform is not: new
    citations matching a known shape are translated the next time it runs.

WHAT IT DOES NOT DO
    It does not strip evidence. "Measured 2026-08-29 on the live store: 4,899 of
    4,917 records were synthesized" survives intact -- that sentence is why the
    code is trustworthy, and a comment asserting something with no visible
    grounds is worse than either the private citation or silence. Only the
    private ADDRESS is translated: the PR number, the org, the path, the guard
    name, the doctrine code.

SELF-VERIFYING
    The run ends by executing the skeleton's own check_no_private_refs.py and
    failing if anything survives. The guard is the transform's test: a rule that
    does not actually clean is a rule that fails the build, not one that quietly
    ships.

Usage:
  papercut-vendor.py            transform, write, then verify
  papercut-vendor.py --check    report what would remain; write nothing
  papercut-vendor.py --verify-fresh   exit 1 if the package is behind this source
  papercut-vendor.py --verify-delivered  exit 1 if CUSTOMERS are behind (reads the
                                         marketplace pin); exit 2 if unknowable
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Both roots are overridable so a vendor can be REHEARSED between two
# worktrees. Without this, the only way to test a transform change was to
# write the live skeleton, which makes a bad rule a cleanup job rather than a
# discarded branch. The source default is the checkout this file resolves
# into (scripts/ sits two levels below its root), so an unset
# environment vendors the harness that is running it.
SOURCE = Path(os.environ.get("PAPERCUT_VENDOR_SOURCE") or Path(__file__).resolve().parents[1])
SKELETON = Path(
    os.environ.get("PAPERCUT_VENDOR_SKELETON", str(Path.home() / "SITES" / "papercut"))
)

# src (under SOURCE) -> dst (under SKELETON)
VENDORED = {
    "bin/papercut.py": "papercut/cli.py",
    "hooks/PostToolUseFailure/papercut-log.js": "hooks/papercut-log.js",
    "hooks/PreToolUse/structured-output-unwrap.js": "hooks/structured-output-unwrap.js",
    "hooks/PreToolUse/read-ceiling-chunk.js": "hooks/read-ceiling-chunk.js",
    # papercut-log.js, structured-output-unwrap.js, and read-ceiling-chunk.js
    # all require('../lib/hook-output') -- one directory up from wherever they
    # sit under hooks/ (PostToolUseFailure/ and PreToolUse/ are both one
    # level down). The package flattens all three into hooks/, so from
    # SKELETON/hooks/*.js the same '../lib/hook-output' resolves to
    # SKELETON/lib/hook-output.js: vendoring here needs no import-rewrite rule
    # (verified by the load gate below, not assumed).
    "hooks/lib/hook-output.js": "lib/hook-output.js",
    "plugins/hov-stack/skills/papercut/SKILL.md": "skills/papercut/SKILL.md",
    "tests/test_papercut.py": "tests/test_papercut.py",
}

# ---------------------------------------------------------------------------
# 1. CONFIG DEFAULTS. Not sanitization -- this is the packaged copy choosing
# different defaults through the Stage 1 override layer, which is the entire
# reason that layer exists. The harness keeps its values; the plugin ships
# neutral ones.
CONFIG_DEFAULTS: list[tuple[str, str]] = [
    (
        'KNOWN_GUARDS = (\n    "git-guard",\n    "runner-guard",\n    "loop-guard",\n'
        '    "codex-quota-guard",\n    "codex-doghouse-guard",  # historical records remain queryable\n'
        '    "dcg",\n)',
        "# Guard names this installation recognises in free-text self-reports.\n"
        "# Empty by default: the automatic capture path never consults this list\n"
        "# (each guard names itself), so an unconfigured install loses nothing.\n"
        "KNOWN_GUARDS: tuple[str, ...] = ()",
    ),
    (
        "# Blank since 2026-10-18: the dispatcher that read the label retired with\n"
        "# dotfiles#1873 (2026-10-17), so adopt prints no tagging hint and the rollup's\n"
        "# `dispatch handoff:` section stays off until a queue is configured again.\n"
        'DISPATCH_READY_LABEL = ""',
        "# Label that admits a filed item to an autonomous queue. Empty means no\n"
        "# queue, and the post-filing guidance is omitted rather than reworded.\n"
        'DISPATCH_READY_LABEL = ""',
    ),
    ('DISPATCH_DOCS_REF = "gh-tracking-and-claims.md"', 'DISPATCH_DOCS_REF = ""'),
    (
        'WORK_SPEC_SECTIONS = ("Acceptance Criteria", "Planted negative", "No-Claim Boundary")',
        "# Sections a filed work item must carry. Empty means the gate passes\n"
        "# everything: these headings are one team's doctrine, not a universal\n"
        "# contract, and gating a stranger on them would refuse every filing.\n"
        "WORK_SPEC_SECTIONS: tuple[str, ...] = ()",
    ),
]

# ---------------------------------------------------------------------------
# 2. EXACT OVERRIDES, applied before the general rules. These are sites where a
# blanket substitution would produce grammatical nonsense, so the sentence is
# rewritten rather than patched.
EXACT: list[tuple[str, str]] = [
    # A PASTEABLE instruction, not prose. apply_skill_launcher_form only
    # rewrites runnable lines inside ```bash fences, so this one survived: it
    # sits in a blockquote the skill tells the user to copy into their own
    # CLAUDE.md, where an agent will later read it and run a bare `papercut`
    # that does not exist on a plugin-only install. True for this harness,
    # false for the package, so it is a rule rather than a source edit.
    (
        '> undocumented step, silently-wrong output, a footgun? `papercut add -m "..."`',
        "> undocumented step, silently-wrong output, a footgun? run the papercut\n"
        "> skill's `add` command",
    ),
    # USER-FACING REMEDIES, not prose. The general rules translate the private
    # ADDRESS and stop, which is right for a comment and wrong for a sentence
    # telling someone what to run: the packaged copy was printing "(your config
    # sync reconcile-papercut-hook)" at a stranger who has no such command, and
    # naming a command that does not exist is worse than naming none. The
    # plugin's real remedy is different, so the sentence is rewritten, not patched.
    (
        '— is the PostToolUseFailure hook registered? (sync.sh reconcile-papercut-hook)")',
        '— is the PostToolUseFailure hook registered? Check that the papercut "\n'
        '              "plugin is enabled.")',
    ),
    # Same class, in argparse help: "(for harness-weekly)" survives sanitizing as
    # a noun phrase describing a schedule the plugin does not ship, which reads
    # as a promise that one exists.
    (
        'st = sub.add_parser("staleness", help="is capture still alive? (for harness-weekly)")',
        'st = sub.add_parser("staleness", help="is capture still alive?")',
    ),
    # The Read guard requires the capture module from one directory up in the
    # harness; in the plugin both sit in hooks/. No other vendored file carries
    # this string, so the rule is inert elsewhere.
    ("require('../PostToolUseFailure/papercut-log.js')", "require('./papercut-log.js')"),
    # Same fact, prose form. The harness cites the hook by a path relative to
    # the harness root, where it genuinely sits one level down in
    # PostToolUseFailure/ (see VENDORED above). The package flattens hooks/,
    # so every prose citation of the nested path -- the skill body, and this
    # module's own docstring/comments -- points a reader at a file that does
    # not exist there. Both are true in their own tree; only the address
    # differs, which is what makes this a vendor rule rather than a source
    # edit.
    ("hooks/PostToolUseFailure/papercut-log.js", "hooks/papercut-log.js"),
    # DOCTRINE below is keyed by bare code, and this comment cites a DIFFERENT
    # plan's codes (docs/plans/2026-09-20-2120-feat-rewrite-not-deny-hook-plan.md):
    # its KTD6 is the receipt-in-the-script rule, while DOCTRINE's KTD6 is
    # papercut's open-work cap. The bare-code rule would ship the wrong
    # meaning, so the three are named here, before DOCTRINE runs.
    (
        "shape-rewrite (KTD2/KTD6/KTD7):",
        "shape-rewrite (its fresh-script-per-call, receipt-in-the-script, and "
        "friction-accounting rules):",
    ),
    # ---- SKILL.md customer-facing passages ----
    # The private harness runs the report-only rollup on demand (its Monday
    # timer and toast were retired with dotfiles#1893); the plugin ships
    # neither the script nor a schedule. Translating the script name (as the
    # general LITERALS rule below would) would leave a paragraph about a
    # retired timer in a package that never had one, so the claim is
    # rewritten here rather than left to the literal layer.
    (
        "`harness-weekly.sh` runs the report-only rollup on demand; its Monday timer and\n"
        "the Windows toast it nagged through were retired with dotfiles#1893\n"
        "(2026-10-17), so nothing now stops the log quietly becoming write-only. Run\n"
        "`papercut rollup --days 7` when the log is due a look. `--apply` stays a\n"
        "deliberate legacy operator step for unassigned raw signatures; once a family\n"
        "exists, use the clinic below.",
        "Nothing here schedules itself. `rollup --days 7` stays report-only until\n"
        "something runs it -- wire it into whatever schedule this repo already uses\n"
        "(cron, a CI job) if you want a standing check; the plugin ships no timer and\n"
        "no notification of its own. `--apply` stays a deliberate step for\n"
        "unassigned raw signatures; once a family exists, use the clinic below.",
    ),
    # The private harness's autonomous dispatch queue and its admission label
    # were real there until dotfiles#1873 (the private text now records them
    # as retired) and were never in the plugin (DISPATCH_READY_LABEL has been
    # blank in the private source too since 2026-10-18; the CONFIG_DEFAULTS
    # override below swaps only the private comment above it, and the CLI's
    # own post-filing guidance is omitted, not reworded, while the label is
    # blank -- this keeps the prose in sync with that runtime behavior). The general
    # LITERALS layer turns "loop-ok" / "dispatcher" into standalone nouns
    # like "the dispatch-ready label" and "an autonomous queue", which reads
    # as nonsense and, worse, still promises a queue the plugin does not
    # have. Rewritten as a paragraph so the history drops along with the
    # address.
    (
        "Adopt never applies `loop-ok` — filing a work item and admitting it to an\n"
        "autonomous lane were two separate acts while the dispatcher ran, and the\n"
        "label is historical since that dispatcher retired (dotfiles#1873,\n"
        "2026-10-17). It was human-admitted only: the operator's tag, or a session\n"
        "tagging specific work the operator explicitly approved in that same session\n"
        "(amended 2026-08-28; the record lives in\n"
        "`harness/gh-tracking-and-claims.md`).",
        "Adopt only files or updates the work item. It never applies a label, assigns\n"
        "an owner, or hands the item to any automation — the plugin ships nothing to\n"
        "hand it to. What happens after that is whatever process this repo already\n"
        "runs on its own issues.",
    ),
    # Deleted rather than translated. The `dispatch handoff:` section it
    # describes prints only while DISPATCH_READY_LABEL is configured, which
    # neither the private source nor the plugin does since 2026-10-18, and
    # the retired-dispatcher history behind it is private. What honestly
    # survives sanitization -- adopt only files, nothing more -- is already
    # said by the paragraph above, so this one is cut instead of restated.
    (
        "\n"
        "\n"
        "**After adopt, the handoff is the operator's.** Tagging a filed work-spec\n"
        "issue `loop-ok` was the one act that put it in the dispatcher's intake\n"
        "filter; that dispatcher retired with dotfiles#1873 (2026-10-17), so the tag\n"
        "now records operator admission and nothing picks the item up.\n"
        "`DISPATCH_READY_LABEL` has been blank since 2026-10-18, so adopt prints no\n"
        "tagging hint and the rollup's `dispatch handoff:` section stays off. With a\n"
        "label configured, that section (printed under `--refresh`) shows where\n"
        "adopted-open items stand — awaiting the tag, tagged, or blocked. Every\n"
        "state is a label fact read\n"
        "live during `rollup --refresh`, never stored, and never an inferred\n"
        "outcome: final readiness (native dependency blockers included) is\n"
        "`gh-ready.sh`'s call, and the trivial route's pull request sits outside the\n"
        "intake entirely — gh-ready reads issues only. Issue claims retired with\n"
        "dotfiles#1902 (2026-10-17), so nothing applies the `claimed` label any more;\n"
        "the section still prints `claimed` for an issue that carries the old label.\n"
        "The section covers up to the refresh read cap\n"
        "(`--limit`, default 10) per run; the quiet tail rotates oldest-checked\n"
        "first, so anything past the cap surfaces on a later run.",
        "",
    ),
    # "the queue" here meant the dispatcher's intake queue in context, which
    # read fine as a callback to the paragraph just deleted above. Standing
    # alone in the package it collides with "the plugin ships nothing to
    # hand it to" two paragraphs up -- same open-work-cap concept, less
    # loaded a word.
    (
        "**Keep the queue at the operator's keep-rate, not the backlog's size.**",
        "**Keep open work at the operator's keep-rate, not the backlog's size.**",
    ),
    # Invocation contract: the harness has a real `papercut` on PATH; the
    # plugin has neither a global install nor guaranteed PATH placement, so
    # every runnable example is rewritten below (see
    # apply_skill_launcher_form) to go through the shipped launcher. This
    # note is the one-time explanation of that rewrite plus its documented
    # fallback; it has no harness analog; so it is inserted here rather than
    # written in the source, where it would be true of nothing.
    (
        "## Log one\n\n```bash\n",
        "## Log one\n\n"
        "Every command below runs through this plugin's own launcher, so it works\n"
        "with no global install and no `PATH` setup. The launcher resolves its own\n"
        "location, so a symlink to it from anywhere on your `PATH` works too.\n\n"
        "```bash\n",
    ),
    (
        "it is the immutable capture address KTD3 folds",
        "it is the immutable capture address a family folds",
    ),
    # An IDENTIFIER carrying a private term. The general rules deliberately
    # refuse to substitute inside identifiers (that is what broke the first
    # run), so a full rename belongs here instead. Safe for a unittest method:
    # it is discovered by name and called from nowhere.
    (
        "test_no_dispatcher_configured_says_nothing",
        "test_no_queue_configured_says_nothing",
    ),
    # The staleness-check rationale cites the cass incident by name (an
    # indexer that exited 0 daily for 21 days while its index rotted). The
    # lesson ships; the private tool name does not.
    (", and cass reporting", ", and an indexing tool reporting"),
    ("'the hook died'. cass exited 0 daily for 21 days",
     "'the hook died'. A sibling indexing tool exited 0 daily for 21 days"),
    ("# The cass shape:", "# The dead-index shape:"),
    # The transcript hint names cass, this harness's transcript-search CLI.
    # A stranger's machine has no cass; the packaged hint keeps the generic
    # slicing advice instead of advertising a tool that is not there.
    (
        "'The cass CLI searches transcripts without loading them; '\n"
        "      + 'jq/grep/tail also work for slicing.'",
        "'jq, grep and tail can slice it without loading the whole file.'",
    ),
    # The vendored tests bootstrap the module by source path. In the package
    # that path is papercut/cli.py, not bin/papercut.py, so without this the
    # shipped suite cannot import the thing it tests. Repointing beats
    # rewriting to a package import: the tests rebind module attributes on
    # PC directly, and the importlib bootstrap is what gives them a module
    # object to rebind.
    (
        'CLAUDE = Path(__file__).resolve().parents[1]\nPAPERCUT = CLAUDE / "bin" / "papercut.py"',
        'CLAUDE = Path(__file__).resolve().parents[1]\nPAPERCUT = CLAUDE / "papercut" / "cli.py"',
    ),
    (
        "would do nothing, and saying otherwise sends the operator to pull",
        "would do nothing, and saying otherwise sends the operator to pull",
    ),
]

# 3. DOCTRINE CODES -> the invariant each one names. Deleting these would leave
# comments citing a rule the reader cannot look up; naming them keeps the
# reasoning legible, which is the point of the comment in the first place.
DOCTRINE = {
    "AE5": "the rewritten-call-still-refused case",
    "KTD3": "the immutable-capture-address rule",
    "KTD5": "the duplicate-filing guard",
    "KTD6": "the open-work cap",
    "KTD8": "the single-writer state lock",
    "R7": "the print-only label rule",
    "R13": "the live-data verification pass",
}

# 4. GENERAL LITERAL RULES, longest-first so a prefix never eats a longer match.
# A replacement must never CONTAIN its own pattern: 'runner-guard' ->
# 'a-runner-guard' leaves the pattern intact and the guard re-detects it.
# Caught on the first run, by the guard, which is why it gates the build.
LITERALS: list[tuple[str, str]] = [
    # Home paths are not in this table: the tracked tree spells them with a
    # literal $HOME/ and its tests with the placeholder /home/user (slug form
    # -home-user), both already public-safe. A token that can appear in a
    # second encoding (project_slug turns /x/y into -x-y) needs a rule for
    # each form, or a test's input is rewritten and its expected value left
    # alone -- output that is clean, valid, and wrong.
    ("StartupBros-com/hov-stack", "the source harness"),
    ("StartupBros-com", "an-org"),
    ("gh-tracking-and-claims.md", "your queue's documentation"),
    ("harness/", "docs/"),
    ("harness-weekly.sh", "a weekly scheduled run"),
    ("harness-weekly", "a weekly scheduled run"),
    ("work-spec-check.sh", "an external work-item validator"),
    ("verify-seed.sh", "a downstream extractor"),
    ("wt-new.sh", "an external worktree tool"),
    ("gh-ready.sh", "an external readiness check"),
    ("gh-ready", "an external readiness check"),
    ("sync.sh", "your config sync"),
    ("codex-doghouse-guard", "another-guard"),
    ("codex-quota-guard", "another-guard"),
    ("canonical-worktree-route-guard", "a-route-guard"),
    ("heavy-job-admission", "an-admission-guard"),
    ("grep-cost-guard", "a-cost-guard"),
    ("whatsapp-guard", "a-messaging-guard"),
    ("runner-guard", "a-worker-guard"),
    ("loop-guard", "a-repetition-guard"),
    ("git-guard", "a-vcs-guard"),
    ("loop-ok", "the dispatch-ready label"),
    ("dispatcher", "an autonomous queue"),
    ("smaug", "example-project"),
    ("dotfiles", "the source harness"),
    ("CLAUDE_JOB_DIR", "A_JOB_DIR"),
    ("gsc ", "a-cli "),
    ("dcg", "a-command-guard"),
]

# 5. ISSUE AND PR REFERENCES. The claim stays, the address goes: a reader
# outside the origin repository cannot resolve "#530", and a dangling number
# reads as precision that is not there.
ISSUE_REF = re.compile(r"(?:PR|Issue|issue|pull)\s*#\d+|(?<![\w&#])#\d{2,}(?![0-9A-Fa-f]{1,4}\b)")


def substitute(text: str, old: str, new: str, flags: int = 0) -> str:
    """Replace `old`, but never inside a longer identifier.

    A bare word gets word boundaries. Without them the rule
    dispatcher -> "an autonomous queue" fired inside the identifier
    test_no_dispatcher_configured_says_nothing and produced
    `def test_no_an autonomous queue_configured...` -- a file that still
    passed the private-reference guard while no longer being Python. Terms
    containing a slash or dot cannot appear in an identifier, so they stay
    plain: a leading \b would not match before "/" anyway. `flags` (the
    private names pass re.IGNORECASE) apply to either form.
    """
    if old[0].isalnum() and old[-1].isalnum():
        return re.sub(rf"\b{re.escape(old)}\b", new, text, flags=flags)
    if flags:
        return re.sub(re.escape(old), lambda _m: new, text, flags=flags)
    return text.replace(old, new)


def apply_overrides(text: str) -> str:
    """The stages that run before DOCTRINE, so a test can see what it sees."""
    # CONFIG_DEFAULTS rewrite module-level CONSTANT DEFINITIONS, which always
    # begin at column 0. Anchoring to a line start is not cosmetic: unanchored,
    # `DISPATCH_READY_LABEL = "loop-ok"` also matched inside a test's
    # `PC.DISPATCH_READY_LABEL = "loop-ok"`, which spliced a comment block into
    # the middle of an expression and shipped a file that would not parse.
    # Caught by the vendor's own py_compile gate, which is why that gate runs
    # before the sanitization check rather than after it.
    for old, new in CONFIG_DEFAULTS:
        # (?m)^ rather than a literal "\n" prefix: the newline form silently
        # stopped matching a constant at offset 0, which is how the packaged
        # copy briefly kept a private queue label. It worked on cli.py only
        # because nothing there sits at the very start of the file, so the
        # contract was passing by luck. A lambda supplies the replacement so
        # backslashes in `new` are never read as group references.
        text = re.sub(r"(?m)^" + re.escape(old), lambda _m, _new=new: _new, text)
    for old, new in EXACT:
        text = text.replace(old, new)
    return text


def private_tokens() -> list[str]:
    """The optional private names, from outside the tree, longest first.

    HOV_STACK_PRIVATE_TOKENS carries the list itself, newline-separated, as it
    does for scripts/public-safety-scan.sh; without it the list is
    <overlay>/private-tokens, with the overlay resolved the way setup resolves
    it. Longest first, so a name that contains another is replaced whole
    instead of leaving its tail behind.
    """
    configured = os.environ.get("HOV_STACK_PRIVATE_TOKENS")
    if configured:
        lines = configured.splitlines()
    else:
        xdg = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
        if not xdg.is_absolute():
            xdg = Path.home() / ".config"
        overlay = Path(os.environ.get("HOV_STACK_OVERLAY") or xdg / "hov-stack")
        if not overlay.is_absolute():
            return []
        source = overlay / "private-tokens"
        if not source.is_file():
            return []
        lines = source.read_text().splitlines()
    names = {
        line.strip()
        for line in lines
        if line.strip() and not line.lstrip().startswith("#")
    }
    return sorted(names, key=lambda name: (-len(name), name))


def transform(text: str) -> str:
    # Case-insensitive, as the scan matches them: a name that survives in
    # another case is still the name.
    for token in private_tokens():
        text = substitute(text, token, "example-project", re.IGNORECASE)
    text = apply_overrides(text)
    for code, name in DOCTRINE.items():
        text = re.sub(rf"\b{re.escape(code)}\b", name, text)
    for old, new in LITERALS:
        text = substitute(text, old, new)
    return ISSUE_REF.sub("an earlier change", text)


# SKILL.md-only: rewrite runnable ` ```bash ` command lines from the bare
# `papercut ...` the harness genuinely has on PATH to the plugin-relative
# launcher a customer repo has instead. Scoped to fenced bash blocks (not a
# LITERALS entry) because "papercut" also appears as an ordinary noun in the
# skill's prose ("the papercut CLI", "papercut-originated work items") where
# rewriting it would be wrong, and once mid-paragraph ("...backlog of open
# papercut work is not compounded...") where it is not even a command --
# only a line that IS one, inside a fence, is a command to rewrite.
# scripts/, not bin/: a top-level bin/ would put `papercut` on the Bash tool
# PATH as a bare command, but claude.ai organization-settings distribution
# rejects any plugin that contains one, so the shipped skill pays three words
# of verbosity to keep that channel open.
LAUNCHER_INVOCATION = '"${CLAUDE_PLUGIN_ROOT}/scripts/papercut"'


def apply_skill_launcher_form(text: str) -> str:
    out_lines: list[str] = []
    in_bash_fence = False
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped == "```bash":
            in_bash_fence = True
        elif stripped == "```":
            in_bash_fence = False
        elif in_bash_fence and re.match(r"^papercut\b", line):
            line = re.sub(r"^papercut\b", LAUNCHER_INVOCATION, line)
        out_lines.append(line)
    return "\n".join(out_lines)


# The files a CUSTOMER actually receives. Deliberately NOT the test file: a
# test-only change is not a product change, and treating every repository
# commit as product drift is how a freshness signal becomes noise nobody reads.
SHIPPING = tuple(
    dst for dst in VENDORED.values() if not dst.startswith("tests/")
)

MARKETPLACE_REPO = "StartupBros-com/hov-stack"
PACKAGE_REPO = "StartupBros-com/papercut"


def _gh_json(*args: str):
    """Return parsed JSON from gh, or None when the remote could not answer.

    None is NOT False. An unreadable remote is 'unknown', and reporting it as
    'current' is the exact failure this check exists to prevent -- the same
    collapse-the-third-case bug already recorded for repo_exists().
    """
    try:
        r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except (ValueError, TypeError):
        return None


def _pinned_sha() -> str | None:
    """The commit the marketplace card currently points customers at."""
    resp = _gh_json(
        "api", f"repos/{MARKETPLACE_REPO}/contents/.claude-plugin/marketplace.json",
    )
    data = (resp or {}).get("content") if isinstance(resp, dict) else None
    if not isinstance(data, str):
        return None
    try:
        manifest = json.loads(base64.b64decode(data).decode("utf-8"))
    except (ValueError, TypeError, binascii.Error):
        return None
    for card in manifest.get("plugins", []):
        if card.get("name") == "papercut":
            sha = (card.get("source") or {}).get("sha")
            return sha if isinstance(sha, str) and sha else None
    return None


def _file_at(sha: str, path: str) -> str | None:
    resp = _gh_json("api", f"repos/{PACKAGE_REPO}/contents/{path}?ref={sha}")
    data = (resp or {}).get("content") if isinstance(resp, dict) else None
    if not isinstance(data, str):
        return None
    try:
        return base64.b64decode(data).decode("utf-8")
    except (ValueError, TypeError, binascii.Error):
        return None


def verify_delivered() -> int:
    """Is the fix a CUSTOMER runs the fix this source contains?

    verify_fresh() answers a narrower question -- does the local package
    checkout match the transform. Both can be green while every customer runs
    something months old, because the marketplace pins a COMMIT and merging
    does not move that pin. That was the actual 2026-09-08 -> 09-14 gap: source
    fixed, local package fresh, customers untouched for twelve days.

    Exit codes: 0 delivered, 1 behind, 2 unknown (remote unreadable). Unknown
    is deliberately not 0 -- silence about a question you could not ask reads
    identically to an answer of "fine".
    """
    sha = _pinned_sha()
    if sha is None:
        print("papercut delivery: UNKNOWN — could not read the marketplace pin "
              "(outage or auth, NOT evidence that customers are current)")
        return 2

    behind: list[str] = []
    unknown: list[str] = []
    for src_rel, dst_rel in VENDORED.items():
        if dst_rel not in SHIPPING:
            continue
        src = SOURCE / src_rel
        if not src.exists():
            unknown.append(f"{dst_rel} (source missing locally)")
            continue
        want = transform(src.read_text(encoding="utf-8"))
        if dst_rel == "skills/papercut/SKILL.md":
            want = apply_skill_launcher_form(want)
        have = _file_at(sha, dst_rel)
        if have is None:
            unknown.append(f"{dst_rel} (could not read it at the pinned commit)")
        elif have != want:
            behind.append(dst_rel)

    if unknown:
        print(f"papercut delivery: UNKNOWN at pin {sha[:8]} — could not compare:")
        for u in unknown:
            print(f"  {u}")
        return 2
    if behind:
        print(f"WARN papercut delivery: customers are BEHIND this source "
              f"(marketplace pins {sha[:8]}):")
        for b in behind:
            print(f"  {b}")
        print("  A merged fix that is never released reaches nobody. Bump VERSION, "
              "let the train stage the draft, merge the marketplace repin, then "
              "dispatch the publish.")
        return 1
    print(f"papercut delivery: customers are current (marketplace pins {sha[:8]})")
    return 0


def verify_fresh() -> int:
    """Exit nonzero when the skeleton is BEHIND what the transform would write.

    THE DEFECT THIS EXISTS FOR
        The bounded-redaction fix merged into this harness on 2026-09-08. On
        2026-09-14 the marketplace card still pinned v0.1.18 (released
        2026-09-02), so the repair had not reached one customer twelve days
        later. Nothing anywhere noticed: vendoring is a manual step, and a
        manual step that nobody fails is a step that silently stops happening.

        Measured the same day, same machine, warm cache both sides: the shipped
        tree ran its suite in 171.1s, the re-vendored tree in 7.4s.

    WHY THIS AND NOT AN ARCHITECTURE CHANGE
        It is tempting to read that incident as proof the generation direction
        is wrong. It is not -- an inverted ownership model would not have
        noticed either. What was missing is a comparison, and the transform
        already computes both sides of it. See docs/EXTRACTION-DESIGN.md,
        "the ownership question, assessed and sequenced".

    DELETION CONDITION
        Delete when the package stops being generated from this source.
    """
    stale: list[str] = []
    for src_rel, dst_rel in VENDORED.items():
        src = SOURCE / src_rel
        if not src.exists():
            print(f"missing source: {src}", file=sys.stderr)
            return 1
        want = transform(src.read_text(encoding="utf-8"))
        if dst_rel == "skills/papercut/SKILL.md":
            want = apply_skill_launcher_form(want)
        dst = SKELETON / dst_rel
        have = dst.read_text(encoding="utf-8") if dst.is_file() else None
        if have != want:
            reason = "missing" if have is None else "differs from the transform's output"
            stale.append(f"  {dst_rel}: {reason}")

    if stale:
        print("vendor freshness: STALE -- the package is behind this source")
        for line in stale:
            print(line)
        print("\nRun papercut-vendor.py to regenerate, then release. A source fix "
              "that is never vendored reaches nobody.")
        return 1
    print("vendor freshness: ok (package matches this source)")
    return 0


def main() -> int:
    check_only = "--check" in sys.argv
    if not SKELETON.exists():
        print(f"no skeleton at {SKELETON}", file=sys.stderr)
        return 1
    if "--verify-fresh" in sys.argv:
        return verify_fresh()
    if "--verify-delivered" in sys.argv:
        return verify_delivered()
    # Only here, never on the verify paths: harness-weekly reads any stderr
    # from those as a delivery warning.
    if not private_tokens():
        print("private-token list missing: set HOV_STACK_PRIVATE_TOKENS or write "
              "<overlay>/private-tokens; vendoring with the fixed rules only",
              file=sys.stderr)

    for src_rel, dst_rel in VENDORED.items():
        src = SOURCE / src_rel
        if not src.exists():
            print(f"missing source: {src}", file=sys.stderr)
            return 1
        out = transform(src.read_text(encoding="utf-8"))
        if dst_rel == "skills/papercut/SKILL.md":
            out = apply_skill_launcher_form(out)
        dst = SKELETON / dst_rel
        if check_only:
            print(f"  would write {dst_rel} ({len(out)} bytes)")
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(out, encoding="utf-8")
        print(f"  vendored {src_rel} -> {dst_rel}")

    if check_only:
        return 0

    # A sanitization gate that cannot fail on a corrupted output is not a gate.
    # The first run of this script produced a file that passed the private-
    # reference check and was no longer valid Python, because a rule fired
    # inside an identifier. Validity is checked first, for that reason.
    for rel in VENDORED.values():
        out = SKELETON / rel
        if rel.endswith(".py"):
            cmd = [sys.executable, "-m", "py_compile", str(out)]
        elif rel.endswith(".js"):
            cmd = ["node", "--check", str(out)]
        else:
            continue
        probe = subprocess.run(cmd, capture_output=True, text=True)
        if probe.returncode != 0:
            print(f"vendor FAILED: {rel} is not valid after transform\n"
                  f"{(probe.stderr or probe.stdout).strip()[:400]}", file=sys.stderr)
            return 1
    print("  transformed output parses")

    # `node --check` only proves a file parses; it never touches a require()
    # call, so a vendored file whose require target is ITSELF missing from
    # VENDORED still passes that gate and MODULE_NOT_FOUNDs the first time a
    # real event runs it -- exactly what happened when hook-output.js shipped
    # in hooks/lib/ with three vendored callers but no VENDORED entry
    # of its own. Load each vendored .js in a fresh child process -- never
    # this one -- so a `require.main === module` standalone entry's side
    # effects (a stdin listener, an immediate exit) never fire: every hook
    # vendored here already guards that check (confirmed against source, not
    # assumed), so `require()`ing it from a *different* module is inert.
    for rel in VENDORED.values():
        if not rel.endswith(".js"):
            continue
        out = SKELETON / rel
        probe = subprocess.run(
            ["node", "-e", f"require({json.dumps(str(out))})"],
            capture_output=True, text=True,
        )
        if probe.returncode != 0:
            print(f"vendor FAILED: {rel} does not load as a module after transform\n"
                  f"{(probe.stderr or probe.stdout).strip()[:400]}", file=sys.stderr)
            return 1
    print("  transformed output loads")

    guard = SKELETON / "scripts" / "check_no_private_refs.py"
    result = subprocess.run([sys.executable, str(guard)], capture_output=True, text=True)
    print(result.stdout.rstrip() or result.stderr.rstrip())
    if result.returncode != 0:
        print("\nvendor FAILED: private references survive the transform. "
              "Add a rule rather than editing the skeleton by hand -- a hand "
              "edit is erased by the next run.", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
