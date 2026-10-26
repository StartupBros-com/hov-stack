#!/usr/bin/env python3
"""Audit persisted Workflow scripts for unpinned agent() calls.

Every agent() call in a workflow script must carry an explicit model: pin
(agent-swarm skill -> "Workflow stage tiers", moved from CLAUDE.md -> Model
Routing on 2026-10-18; added 2026-07-09 after the ai-lab-audit run put
38/52 agents on the Fable session pin). Scripts are persisted per session
under ~/.claude/projects/<proj>/<session>/workflows/scripts/*.js, so scanning
those is a ground-truth check on authoring behavior, not a prompt test.

Usage:
    wf-pin-audit.py [--days N] [--agents-dir PATH]
        --days N          scan scripts modified in the last N days (default 7)
        --agents-dir PATH agent .md directory to audit (default agents
                           next to this script)

Exit codes: 0 clean, 1 unpinned call sites found, 2 scan corpus unavailable,
3 lexer shim unavailable, 4 one or more scripts unaudited (harness-doctor
friendly: all but 0 are nonzero). Code 3 means the node shim this script delegates lexing to (see
lexical_spans()'s doc comment) could not run AT ALL for this run -- a
shim-level failure (node missing, non-zero exit, unparseable output, a
malformed result shape, or the whole batch's own timeout) -- so every
script in this window is unaudited. Code 4 is narrower: the shim ran fine
for the batch, but one or more INDIVIDUAL scripts each failed to lex, ran
past their own per-script lexer budget (env WF_PIN_LEX_BUDGET_MS), or
exceeded the per-script size cap (env WF_PIN_LEX_MAX_BYTES) -- each named
on its own WARN line with the specific reason, every OTHER script in the
same run still fully audited and reported. Neither code ever falls back to
a comment-blind scan and reports clean instead (a gate that cannot compare
must fail); code 4 takes priority over code 1 (a run with both unpinned
findings AND an unaudited script exits 4, not 1 -- "the audit was
incomplete" outranks "the audit found a problem"). harness-doctor.sh's
check 23 reads this script via `$(python3 wf-pin-audit.py --days 8 2>&1)`
and, on nonzero exit, takes `tail -1` of that merged stream, so the LAST
line this script prints on every exit path (0-4) must be truthful on its
own -- see _warn()'s own doc comment for the stdout/stderr ordering this
requires. History: see issue #1351.
Also emits a soft warning per uncapped data-driven fan-out (a parallel/
pipeline call whose own text .map()s a list with no .slice( cap). Scoped
per call like the pin check, and nested calls are excised before judging,
so no fan-out's cap can vouch for a sibling, a parent, or a child.
Also warns per over-demanding structured-output schema: a required: list
with more than 7 entries, or more than 5 when its own schema object also
sets additionalProperties: false (issue #676: 965 of 1,281 StructuredOutput
retries in the 2026-08 30d window were missing-required rejections, across
121 sessions -- every one a silent full regeneration). Each required list
is judged against its own schema object only; a nested subschema's
strictness cannot tighten its parent, nor the parent its child. Only
schema-shaped objects are judged (own text showing properties:,
type: 'object', or additionalProperties), and an unterminated array is
skipped rather than miscounted to EOF.
Also warns per agents/*.md file whose frontmatter omits
`omitClaudeMd: true`: every agent is meant to run lean by default (18.8k
fewer tokens per request, dotfiles#1221), so an agent that needs full
doctrine documents it in its own body with the keep-list marker sentence
rather than silently dropping the flag. A file carrying that marker is
exempt; everything else missing the flag is flagged. WARN only -- this
never changes the exit code.
"""

import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from floor_assert import FloorNotMet, require_floor  # noqa: E402
from wf_pin_lex_client import ShimUnavailable, lex_texts, max_bytes  # noqa: E402

STRING_RE = re.compile(
    r"`(?:[^`\\]|\\.)*`|'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"", re.DOTALL
)


def _warn(message: str) -> None:
    """Print message to stderr, ordered correctly against stdout in a merged
    2>&1 capture.

    stdout is block-buffered when piped and only flushed at process exit;
    stderr is unbuffered. Writing to stderr without flushing stdout first
    let every already-printed-but-still-buffered stdout line land in a
    merged `2>&1` stream AFTER this write instead of before it -- exactly
    backwards from program order, which is what let harness-doctor.sh's
    check 23 read a stale "clean" stdout summary as the LAST line of its
    `$(... 2>&1) | tail -1` capture even though a WARN about an unaudited
    script had already been printed. Flushing stdout here, then writing and
    flushing stderr, keeps the merged stream in true program order."""
    sys.stdout.flush()
    print(message, file=sys.stderr)
    sys.stderr.flush()


# Per-text cache of the node shim's lexer output: {"spans", "blanked",
# "uncapped"} for a normal result, or {"error": "<reason>"} for a per-script
# failure (see scripts/lib/wf-pin-lex.js's own doc comment for the
# exact contract). Keyed by whatever text a caller passes in -- both a
# script's ORIGINAL text and its OWN blank_strings() output are valid keys,
# since blank_strings() registers the second as an alias to the first's
# result (blanking already-blanked text is idempotent) so the natural
# production call sequence (blank_strings(text) then uncapped_fanouts(the
# result)) never spawns a second node process for the same script.
_LEX_CACHE: dict[str, dict] = {}


def _lex_result(text: str) -> dict:
    """Cached per-text shim result, fetching a single-text batch on a cache
    miss. Every caller below (lexical_spans(), blank_strings(),
    uncapped_fanouts(), via _normal_lex_result()) lets ShimUnavailable
    propagate rather than treating "the shim could not run" (a run-wide
    failure) the same as "this one text has a per-script {"error": ...}
    entry" -- only main() decides what the latter means (a gate that cannot
    compare must fail)."""
    if text not in _LEX_CACHE:
        _LEX_CACHE[text] = lex_texts([text])[0]
    return _LEX_CACHE[text]


def _normal_lex_result(text: str) -> dict:
    """_lex_result(text), asserting it is the normal {"spans", "blanked",
    "uncapped"} shape rather than a per-script {"error": ...} entry.

    Every caller here (lexical_spans(), blank_strings(), uncapped_fanouts())
    is only ever reached, in main()'s own per-script loop, AFTER lex_error()
    has already checked this same text and skipped it on any error --
    calling this function on an errored text is therefore a caller bug, not
    a normal code path, so it raises loudly (a gate that cannot compare must
    fail) instead of a silent fallback or an opaque KeyError on "spans"."""
    result = _lex_result(text)
    error = result.get("error")
    if error is not None:
        raise RuntimeError(
            f"internal error: called on text with an unchecked lex_error(): {error!r} "
            "-- caller must check lex_error(text) first"
        )
    return result


def lex_error(text: str) -> str | None:
    """This text's own per-script lexer error (size cap, unlexable, budget
    exceeded, or any other per-text lexer exception -- see wf-pin-lex.js's
    own doc comment for the four shapes), or None if it lexed normally.

    main() calls this FIRST, before lexical_spans()/blank_strings()/
    uncapped_fanouts() -- all three now require the normal result shape (see
    _normal_lex_result()) and would raise on a per-script error entry, which
    carries none of "spans"/"blanked"/"uncapped". Unlike ShimUnavailable (a
    run-wide, shim-level failure), a per-script error is scoped to exactly
    one text: every other script in the same batch still gets a normal
    result and is fully audited."""
    return _lex_result(text).get("error")


def prefetch_lex_cache(texts: list[str]) -> None:
    """Populate the lexer cache for every text in ONE OR MORE node
    invocations (see wf_pin_lex_client.py's own batching doc comment).

    main() calls this once, before scanning any script, with the full
    deduplicated corpus for the run -- every lexical_spans()/blank_strings()/
    uncapped_fanouts() call below then hits this cache instead of spawning a
    fresh node process per script. Raises ShimUnavailable on any failure;
    main() reports it and exits non-zero rather than letting individual
    per-text retries paper over a corpus-wide outage as a series of
    separately-degraded fallbacks.
    """
    unique = [t for t in dict.fromkeys(texts) if t not in _LEX_CACHE]
    if not unique:
        return
    for one_text, result in zip(unique, lex_texts(unique)):
        _LEX_CACHE[one_text] = result


def lexical_spans(text: str) -> list[tuple[int, int, str]]:
    """(start, end, kind) for every string/template literal ('string'),
    every // or /* */ comment ('comment'), and every /.../ regex literal
    ('regex'), via fanout-admission.js's own adversarially-reviewed
    lexCode(), called through the wf-pin-lex.js / wf_pin_lex_client.py shim
    -- the ONE place this scan runs, instead of a hand-ported second copy
    that kept drifting from the hook it was ported from. Offsets are
    Unicode code points (Python string indexing), not the shim's own
    UTF-16 code-unit offsets -- see wf_pin_lex_client.py's own doc comment.

    Raises if this text could not be lexed at all (see _normal_lex_result())
    or if the shim itself could not run (ShimUnavailable) -- callers must
    check lex_error(text) first and skip this text on any error instead of
    calling this function (a gate that cannot compare must fail; a
    malformed script is reported unaudited, never silently degraded to a
    comment-blind regex scan). History: see issue #1351.
    """
    spans = _normal_lex_result(text)["spans"]
    return [(start, end, kind) for start, end, kind in spans]


def _blank_comment_span(out: list, start: int, end: int) -> None:
    """Blank one comment span in place, keeping any newline it contains so
    a caller counting "\\n" against the original text still lands on the
    right line. Ported from fanout-admission.js's lexView() blank()."""
    for k in range(start, end):
        if out[k] != "\n":
            out[k] = " "


def blank_strings(text: str) -> str:
    """Replace string-literal, comment, AND regex-literal span contents with
    spaces, preserving both offsets and codepoint length, from
    lexical_spans()'s own (already code-point-normalized) spans.

    Rebuilt here rather than trusting the shim's own "blanked" field
    (finding #2, PR #1352 round 7): wf-pin-lex.js derives its blanked text
    by replacing each UTF-16 CODE UNIT of a span with one space
    (text.split('')), so a blanked astral character (outside the Basic
    Multilingual Plane) becomes TWO Python space-characters once decoded --
    correct in UTF-16 length, wrong in Python's own code-point length, and
    silently misaligning every offset downstream. Rebuilding character-by-
    character from `text` itself keeps this function's output exactly as
    long as `text`, code point for code point, on every fixture including
    astral characters.

    Also registers this result under its OWN blanked text as a cache alias
    (see _LEX_CACHE's doc comment): a caller that immediately re-lexes the
    blanked output -- uncapped_fanouts(), and every real call site in this
    module -- hits the cache instead of spawning a second node process for
    the same script. This is safe because `blanked` has the same length and
    codepoint positions as `text` by construction, so uncapped_fanouts()'s
    own offsets (computed against `text`) still line up against `blanked`.
    """
    result = _normal_lex_result(text)
    out = list(text)
    for start, end, kind in result["spans"]:
        if kind == "comment":
            _blank_comment_span(out, start, end)
        else:
            for k in range(start, end):
                out[k] = " "
    blanked = "".join(out)
    _LEX_CACHE.setdefault(blanked, result)
    return blanked


AGENT_RE = re.compile(r"\bagent\s*\(")
FANOUT_RE = re.compile(r"\b(?:parallel|pipeline)\s*\(")


def call_spans(stripped: str, callee: re.Pattern[str] = AGENT_RE):
    """Yield (start, end) spans of callee(...) calls via paren counting."""
    for m in callee.finditer(stripped):
        depth, i = 1, m.end()
        while i < len(stripped) and depth:
            depth += {"(": 1, ")": -1}.get(stripped[i], 0)
            i += 1
        yield m.start(), i


def is_unpinned(span: str) -> bool:
    """True if an agent() call span carries no explicit model: pin."""
    return not re.search(r"\bmodel\s*:", span)


def uncapped_fanouts(stripped: str) -> list[tuple[int, int]]:
    """Spans of parallel/pipeline calls that .map()/.flatMap() a data-driven
    list with no .slice() cap chained onto that same receiver, via
    fanout-admission.js's own uncappedFanouts()/scopedMapCap() (through the
    shim -- see lexical_spans()'s doc comment for why this is the one place
    that resolution runs).

    Every call is judged on its own text (the hook's ownText()): neither a
    sibling's cap, nor a child's, nor a parent's may vouch for this call,
    and each is reported independently. The shim's own FANOUT_RE
    additionally recognizes Promise.all(...); intersecting its uncapped
    spans with THIS module's own narrower FANOUT_RE (parallel|pipeline
    only) means that broader recognition never silently widens this
    auditor's scope.

    A call-expression receiver (`getItems().slice(0, 20).map(...)`) or a
    filter-interposed one (`items.slice(0, 20).filter(x => x.ok).map(...)`)
    still cannot resolve a cap and reads as WARN -- pre-existing,
    adversarially-reviewed hook behavior (it gates live spawns), not
    something this function changes; a receiver-resolution improvement
    belongs in the shared hook function, for both consumers at once.
    History: see issue #1351.
    """
    own_spans = set(call_spans(stripped, FANOUT_RE))
    if not own_spans:
        return []
    shim_uncapped = _normal_lex_result(stripped)["uncapped"]
    return [(start, end) for start, end in shim_uncapped if (start, end) in own_spans]


REQUIRED_LIMIT = 7
STRICT_REQUIRED_LIMIT = 5

SCHEMA_KEYWORDS = {"required", "additionalProperties", "properties", "type", "object"}
REQUIRED_KEY_RE = re.compile(r"\brequired\s*:\s*\[")
PROPERTIES_KEY_RE = re.compile(r"\bproperties\s*:")
TYPE_OBJECT_RE = re.compile(r"\btype\s*:\s*object\b")
ADDL_FALSE_RE = re.compile(r"\badditionalProperties\s*:\s*false\b")


def blank_strings_keep_schema_keys(text: str) -> str:
    """Blank string literals, but keep quoted schema keywords visible.

    JSON-style schemas quote their keys ("required":) -- plain blank_strings()
    erases those -- while prompt prose routinely contains the bare word
    required:. Keeping only the exact keyword literals visible (offset-
    preserving) lets one regex see both spellings while arbitrary string
    contents still cannot fake a schema key. Uses lexical_spans() (not
    STRING_RE) so a quote inside a comment can't flip parity and silently
    blind overdemanding_schemas() (its sole caller) to everything after it.
    """

    def repl(literal: str) -> str:
        if literal[1:-1] in SCHEMA_KEYWORDS:
            return " " + literal[1:-1] + " "
        return " " * len(literal)

    out = list(text)
    for start, end, kind in lexical_spans(text):
        if kind == "string":
            out[start:end] = repl(text[start:end])
        else:
            _blank_comment_span(out, start, end)
    return "".join(out)


def enclosing_object_start(keytext: str, pos: int):
    """Offset of the { that directly encloses pos, or None if not in an object."""
    depth = 0
    for i in range(pos - 1, -1, -1):
        char = keytext[i]
        if char in ")}]":
            depth += 1
        elif char in "({[":
            if depth == 0:
                return i if char == "{" else None
            depth -= 1
    return None


def object_own_text(keytext: str, start: int) -> str:
    """Text of the object opening at start, nested {...} internals blanked.

    Same doctrine as own_text(): one schema object's additionalProperties
    must not vouch for -- here, tighten -- its parent or its child.
    """
    depth, out = 0, []
    for i in range(start, len(keytext)):
        char = keytext[i]
        if char == "{":
            depth += 1
            out.append(char if depth == 1 else " ")
        elif char == "}":
            out.append(char if depth == 1 else " ")
            depth -= 1
            if depth == 0:
                break
        else:
            out.append(char if depth == 1 else " ")
    return "".join(out)


def overdemanding_schemas(text: str) -> list[tuple[int, int, int]]:
    """(offset, required_count, limit) per schema whose required list is too broad.

    Missing-required is the dominant StructuredOutput failure shape (965 of
    1,281 records, 121 sessions, 30d -- issue #676), and the measured worst
    offenders pair a long required list with additionalProperties: false, so
    that pairing gets the lower limit. Every mismatch is a full regeneration
    the workflow author never sees.
    """
    keytext = blank_strings_keep_schema_keys(text)
    flagged = []
    for m in REQUIRED_KEY_RE.finditer(keytext):
        bracket = m.end() - 1
        depth, i = 1, bracket + 1
        while i < len(keytext) and depth:
            depth += {"[": 1, "]": -1}.get(keytext[i], 0)
            i += 1
        if depth:
            # Unterminated array: malformed text. Counting on to EOF would
            # swallow every later string literal in the file into this list
            # (inward-vet DEFECT 2), so refuse to judge it.
            continue
        obj_start = enclosing_object_start(keytext, m.start())
        if obj_start is None:
            continue
        own = object_own_text(keytext, obj_start)
        if not (
            PROPERTIES_KEY_RE.search(own)
            or TYPE_OBJECT_RE.search(own)
            or ADDL_FALSE_RE.search(own)
        ):
            # Not schema-shaped: a JS object merely naming a field `required`
            # is not a StructuredOutput schema (inward-vet DEFECT 1).
            continue
        # lexical_spans() sees a `//`/`/* */` comment as one atomic span
        # before any apostrophe inside it is examined (e.g. `'d', // don't
        # skip`), so a comment can never flip quote parity and inflate this
        # count past the real closing quote (issue #1309). Counted from the
        # SAME whole-file lexical_spans(text) call every other caller in
        # this run already paid for (filtered to this array's own
        # [bracket+1, i-1) offset range) instead of a second, never-cached
        # call per required: array.
        seg_start, seg_end = bracket + 1, i - 1
        count = sum(
            1
            for s, e, kind in lexical_spans(text)
            if kind == "string" and seg_start <= s and e <= seg_end
        )
        strict = bool(ADDL_FALSE_RE.search(own))
        limit = STRICT_REQUIRED_LIMIT if strict else REQUIRED_LIMIT
        if count > limit:
            flagged.append((m.start(), count, limit))
    return flagged


AGENTS_DIR = Path(__file__).resolve().parent.parent / "agents"

# The exact keep-list sentence in agents/claude-artifact-designer.md
# (2026-09-20): a file carrying it has deliberately opted out of the lean
# default and documented why, so it is exempt from the WARN below.
KEEP_LIST_MARKER = (
    "this agent deliberately has no `omitClaudeMd` in its frontmatter"
)

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---", re.DOTALL)
OMIT_CLAUDE_MD_RE = re.compile(r"(?m)^omitClaudeMd\s*:\s*true\s*$")


def missing_omit_claude_md(text: str) -> bool:
    """True when an agent file lacks the lean-default flag and the keep-list
    exemption. Frontmatter carrying `omitClaudeMd: true` is compliant
    regardless of the marker; anything else is compliant only if the marker
    sentence appears anywhere in the file."""
    match = FRONTMATTER_RE.match(text)
    frontmatter = match.group(1) if match else ""
    if OMIT_CLAUDE_MD_RE.search(frontmatter):
        return False
    return KEEP_LIST_MARKER not in text


def agents_missing_omit_claude_md(agents_dir: Path) -> list[Path]:
    """Sorted list of agents/*.md files missing the lean-default flag.

    A missing directory yields no offenders rather than erroring: the CLI
    default points at this repo's own agents, but a test fixture's
    --agents-dir need not exist to exercise the rest of the auditor.
    """
    if not agents_dir.is_dir():
        return []
    return sorted(
        p
        for p in agents_dir.glob("*.md")
        if missing_omit_claude_md(p.read_text(errors="replace"))
    )


def _unaudited_reason_label(error: str) -> str:
    """Classify one per-script unaudited reason -- see wf-pin-lex.js's own
    doc comment for the four raw shapes this reads (size cap, unlexable,
    budget, or any other per-text lexer exception) -- into the short label a
    WARN/summary line names it by.

    Finding #6 (PR #1352 round 7): a single hardcoded "lexer budget
    exceeded" phrase used to label EVERY per-script unaudited reason,
    including a script skipped for being over the size cap or one that
    failed to lex outright, misleading whoever reads the line about what
    remediation applies. The raw reason text (unchanged) still follows each
    script's own name in the same line; this only changes the leading
    classification word(s)."""
    if error.startswith("script exceeds") or error.startswith("file exceeds"):
        return "size cap exceeded"
    if error.startswith("unlexable"):
        return "unlexable"
    if error.startswith("budget exceeded"):
        return "lexer budget exceeded"
    return "lexer error"


def main() -> int:
    agents_dir = AGENTS_DIR
    if "--agents-dir" in sys.argv:
        agents_dir = Path(sys.argv[sys.argv.index("--agents-dir") + 1])
    for path in agents_missing_omit_claude_md(agents_dir):
        print(f"WARN      {path}: agent frontmatter missing omitClaudeMd: true (no keep-list marker)")

    days = 7
    if "--days" in sys.argv:
        days = int(sys.argv[sys.argv.index("--days") + 1])
    cutoff = time.time() - days * 86400

    all_scripts = list(Path.home().glob(".claude/projects/*/*/workflows/scripts/*.js"))
    try:
        require_floor(len(all_scripts), 1, "workflow script corpus")
    except FloorNotMet as error:
        _warn(str(error))
        return 2
    scripts = [
        p
        for p in all_scripts
        if p.stat().st_mtime >= cutoff
    ]
    if not scripts:
        print(f"wf-pin-audit: no workflow scripts modified in the last {days}d")
        return 0

    ordered = sorted(scripts, key=lambda p: p.stat().st_mtime, reverse=True)

    # Finding #9 (PR #1352 round 7): a file's own size is checked BEFORE it
    # is ever read into memory or sent to the shim -- an oversized script
    # used to be read and transported regardless, paying that cost before
    # being rejected as a per-script error. max_bytes() is the SAME
    # function/env var (WF_PIN_LEX_MAX_BYTES) the shim itself enforces, so
    # this is the identical cap applied one layer earlier, never a second
    # drifting literal. Every oversized file is reported unaudited without
    # its content ever entering `texts`/the batch.
    cap = max_bytes()
    unaudited: list[tuple[Path, str]] = []
    texts: dict[Path, str] = {}
    readable: list[Path] = []
    oversized = 0
    for path in ordered:
        if path.stat().st_size > cap:
            unaudited.append((path, f"script exceeds {cap} bytes"))
            oversized += 1
            continue
        texts[path] = path.read_text(errors="replace")
        readable.append(path)

    # Prefetch ONE OR MORE batch node invocations (see
    # wf_pin_lex_client.py's own batching doc comment) for every distinct
    # readable script text in this window, before any per-script scanning
    # starts, so lexical_spans()/blank_strings()/uncapped_fanouts() below
    # always hit this cache instead of spawning node per script.
    unique_texts = list(dict.fromkeys(texts.values()))
    try:
        prefetch_lex_cache(unique_texts)
    except ShimUnavailable as error:
        # This WARN is also the final line of the run (nothing else is
        # printed on this path): _warn()'s stdout flush still matters,
        # since the omitClaudeMd loop above may already have buffered
        # stdout lines that must land BEFORE this one in a merged 2>&1
        # capture, not after it at process exit. The trailing
        # "(N distinct script(s), ...)" clause matches the normal-path
        # summary's own tail shape below -- harness-doctor.sh check 23 seds
        # this exact shape out of the LAST line on every exit path to
        # report how many scripts it scanned, even on an unavailable-shim
        # run (finding #5, PR #1352 round 7: this line used to omit the
        # parenthesized denominator entirely, so the doctor's own sed found
        # nothing and silently reported "? scripts scanned").
        dupes = len(readable) - len(unique_texts)
        tail = f"{len(unique_texts)} distinct script(s), {dupes} duplicate file(s) skipped, {days}d window"
        _warn(
            f"WARN      lexer shim unavailable, {len(unique_texts)} distinct "
            f"script(s) unaudited: {error} ({tail})"
        )
        return 3

    bad_sites = 0
    flagged = 0
    seen: dict[int, int] = {}
    for path in readable:
        text = texts[path]
        h = hash(text)
        if h in seen:
            seen[h] += 1
            continue
        seen[h] = 1
        # Checked BEFORE any of blank_strings()/uncapped_fanouts()/
        # overdemanding_schemas() below -- all three now require the normal
        # shim result shape (see _normal_lex_result()) and raise on a
        # per-script error entry. This one script is skipped and named
        # unaudited; every other script in the same run is still fully
        # audited (see lex_error()'s own doc comment for why this is scoped
        # narrower than ShimUnavailable).
        error = lex_error(text)
        if error is not None:
            unaudited.append((path, error))
            continue
        stripped = blank_strings(text)
        unpinned = []
        for start, end in call_spans(stripped):
            span = stripped[start:end]
            if is_unpinned(span):
                line = text.count("\n", 0, start) + 1
                label_m = re.search(r"label\s*:", span)
                # pull the real label text from the original source
                label = ""
                if label_m:
                    frag = text[start + label_m.end() : start + label_m.end() + 60]
                    q = re.search(r"['\"`]([^'\"`]*)", frag)
                    label = q.group(1) if q else ""
                unpinned.append((line, label))
        if unpinned:
            bad_sites += len(unpinned)
            flagged += 1
            print(f"UNPINNED  {path}")
            for line, label in unpinned:
                print(f"          line {line}  agent() with no model:  {label}")
        uncapped = uncapped_fanouts(stripped)
        if uncapped:
            print(f"WARN      {path}: data-driven fan-out with no .slice( cap")
            for start, _ in uncapped:
                line = text.count("\n", 0, start) + 1
                print(f"          line {line}  parallel/pipeline .map() with no .slice( cap")
        overdemanding = overdemanding_schemas(text)
        if overdemanding:
            print(f"WARN      {path}: structured-output schema demands too many required properties")
            for off, count, limit in overdemanding:
                line = text.count("\n", 0, off) + 1
                paired = (
                    " with additionalProperties: false"
                    if limit == STRICT_REQUIRED_LIMIT
                    else ""
                )
                print(f"          line {line}  required lists {count} properties{paired} (limit {limit})")

    # The "distinct script(s)" denominator counts every readable script's
    # own distinct content once, plus each oversized script (never read, so
    # never de-duplicated by content) as its own entry.
    dupes = len(readable) - len(seen)
    tail = f"{len(seen) + oversized} distinct script(s), {dupes} duplicate file(s) skipped, {days}d window"
    if unaudited:
        names = ", ".join(f"{path} ({error})" for path, error in unaudited)
        reasons = "/".join(sorted({_unaudited_reason_label(error) for _, error in unaudited}))
        _warn(f"WARN      {reasons}, {len(unaudited)} script(s) unaudited: {names}")
        # The final summary must say so too: a consumer reading only the
        # LAST line of a merged 2>&1 capture (harness-doctor.sh check 23's
        # `$(... 2>&1) | tail -1`) must never see "clean" -- or an unpinned
        # count with no mention of the incomplete scan -- when scripts were
        # unaudited. This line, not the WARN above, is deliberately the
        # very last thing main() prints on this path.
        unaudited_note = (
            f"{len(unaudited)} script(s) UNAUDITED ({reasons}): {names}"
        )
        if bad_sites:
            print(
                f"wf-pin-audit: {bad_sites} unpinned agent() call(s) in {flagged} "
                f"script(s); {unaudited_note} ({tail})"
            )
        else:
            print(f"wf-pin-audit: NOT clean: 0 unpinned, {unaudited_note} ({tail})")
    elif bad_sites:
        print(f"\nwf-pin-audit: {bad_sites} unpinned agent() call(s) in {flagged} script(s) ({tail})")
    else:
        print(f"wf-pin-audit: clean ({tail})")
    sys.stdout.flush()
    # Code 4 (one or more scripts unaudited) outranks code 1 (unpinned
    # findings) -- "the audit was incomplete" is the more urgent fact,
    # regardless of what the completed portion of the scan found. Every
    # audited script's own findings are still printed above either way.
    if unaudited:
        return 4
    return 1 if bad_sites else 0


if __name__ == "__main__":
    sys.exit(main())
