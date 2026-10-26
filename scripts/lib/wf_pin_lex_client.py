"""Batch subprocess client for scripts/lib/wf-pin-lex.js.

wf-pin-audit.py must not hand-port fanout-admission.js's lexer and
cap-resolution logic. This client is the ONE place wf-pin-audit.py talks to
node: it runs wf-pin-lex.js in one or more batches of texts (never once per
script) and returns the parsed, code-point-normalized results list, or
raises ShimUnavailable naming exactly what failed. History: see issue
#1351.

Doctrine ("a gate that cannot compare must fail"): a caller that catches
ShimUnavailable must NOT fall back to a comment-blind regex scan and report
clean. It must say so on stderr, count the affected scripts as unaudited,
and exit non-zero.

ShimUnavailable is reserved for SHIM-LEVEL failures: node could not be
launched, the shim exited non-zero, its stdout did not parse, the result
count did not match the request, or one result entry's own shape could not
be trusted (see _validate_entry()). A single pathological script that runs
its own analysis past its per-script budget, exceeds the per-script size
cap, or fails to lex at all does not raise here: the shim reports that ONE
script as a `{"error": "<reason>"}` result entry (see wf-pin-lex.js's own
doc comment) and this function passes it through like any other entry.
wf-pin-audit.py is the only layer that decides what "this one script is
unaudited" means -- see its own lex_error() doc comment.

Coordinate boundary (finding #2, PR #1352 round 7): wf-pin-lex.js indexes
offsets by UTF-16 code unit (JavaScript string indexing); every Python
caller of this module indexes by Unicode code point. The two agree for
every character in the Basic Multilingual Plane and diverge for an astral
character (JS spends two code units on it, Python one code point).
lex_texts() converts every offset in a success entry's "spans" and
"uncapped" lists to code-point offsets before returning -- see
_normalize_offsets()'s own doc comment. The raw "blanked" text is left
UNCONVERTED and must never be used by a Python caller for anything
offset-sensitive: wf-pin-lex.js derives it by replacing each UTF-16 code
unit of a blanked span with one space, so a blanked astral character
becomes TWO Python space-characters once decoded -- a length change, not
just an offset shift. wf-pin-audit.py's blank_strings() instead rebuilds
the blanked text itself from these (now code-point-accurate) spans.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

DEFAULT_NODE_BIN = "node"
DEFAULT_SHIM_PATH = Path(__file__).resolve().parent / "wf-pin-lex.js"

# Must track wf-pin-lex.js's own DEFAULT_BUDGET_MS -- this is only used to
# SIZE the batch timeout below (a defense-in-depth backstop around one
# batch), never to enforce the per-script budget itself; the shim enforces
# that on its own side, per script, and reports an exceeded budget as a
# per-script error entry rather than a process failure.
DEFAULT_BUDGET_MS = 3000
# The batch timeout floor, so a small batch's timeout never shrinks below
# this regardless of script count.
BATCH_TIMEOUT_FLOOR_S = 120.0
# The batch timeout ceiling (finding #7a, PR #1352 round 7): matches
# harness-doctor.sh check 23's own `timeout 300` convention (that script
# wraps its call to this auditor in `timeout` using this same figure as its
# baseline). Without a ceiling, an oversized corpus scaled the subprocess
# timeout without limit instead of failing closed into the tested
# ShimUnavailable/exit-3 path within a bounded time.
BATCH_TIMEOUT_CEILING_S = 300.0
# Head-room added on top of (per-script budget * script count) for node
# startup, JSON marshalling, and the shim's own per-script size-cap check --
# none of which count against any individual script's own budget.
BATCH_TIMEOUT_OVERHEAD_S = 30.0

# Batch transport bounds (finding #9, PR #1352 round 7): one oversized
# corpus used to travel as a single subprocess call/timeout no matter how
# large -- these bound how many whole texts, and how many total bytes,
# travel in one node invocation. Per-file size isolation (a single
# oversized script never entering the batch at all) is wf-pin-audit.py's
# own job before it builds the text list; see that module's own doc
# comment.
DEFAULT_BATCH_MAX_BYTES = 8_000_000
DEFAULT_BATCH_MAX_TEXTS = 200


class ShimUnavailable(RuntimeError):
    """The node lexer shim could not run, or its output could not be trusted."""


def _node_bin() -> str:
    return os.environ.get("WF_PIN_LEX_NODE_BIN", DEFAULT_NODE_BIN)


def _shim_path() -> Path:
    return Path(os.environ.get("WF_PIN_LEX_SHIM_PATH", str(DEFAULT_SHIM_PATH)))


def _env_positive_number(name: str, fallback: float, cast=float):
    """An env var read as a positive number, or `fallback` if unset, blank,
    non-numeric, or non-positive -- never raises. Shared by every env-driven
    knob in this module so a malformed override widens/narrows a default
    instead of crashing the auditor."""
    raw = os.environ.get(name)
    if not raw:
        return fallback
    try:
        value = cast(raw)
    except ValueError:
        return fallback
    return value if value > 0 else fallback


def _budget_ms() -> float:
    """The per-script budget the shim will use (env WF_PIN_LEX_BUDGET_MS,
    same variable name the shim itself reads), for sizing the batch timeout
    below. An unset or non-numeric value reads as the shim's own default
    rather than raising -- this function only ever WIDENS the batch timeout,
    never enforces the budget itself."""
    return _env_positive_number("WF_PIN_LEX_BUDGET_MS", DEFAULT_BUDGET_MS)


def max_bytes() -> int:
    """The per-script size cap the shim will enforce (env
    WF_PIN_LEX_MAX_BYTES, same variable name the shim itself reads).
    Exported so wf-pin-audit.py can apply the SAME cap before ever reading a
    file into the batch (finding #9) -- a second hardcoded literal here
    would drift from wf-pin-lex.js's own default exactly the way this
    module's whole existence prevents for the lexer itself."""
    return int(_env_positive_number("WF_PIN_LEX_MAX_BYTES", 2_000_000, cast=int))


def _batch_max_bytes() -> int:
    return int(_env_positive_number("WF_PIN_LEX_BATCH_MAX_BYTES", DEFAULT_BATCH_MAX_BYTES, cast=int))


def _batch_max_texts() -> int:
    return int(_env_positive_number("WF_PIN_LEX_BATCH_MAX_TEXTS", DEFAULT_BATCH_MAX_TEXTS, cast=int))


def _batch_timeout_s(text_count: int) -> float:
    """Batch subprocess timeout, sized from the per-script budget times the
    script count (plus fixed overhead) so this backstop can no longer fire
    BEFORE every script's own per-script budget has had a chance to expire
    under normal conditions -- floored so a small batch's timeout never
    shrinks below BATCH_TIMEOUT_FLOOR_S, and ceiled at BATCH_TIMEOUT_CEILING_S
    (finding #7a) so an oversized batch still fails closed within a bounded
    time instead of scaling without limit."""
    scaled = (_budget_ms() / 1000.0) * text_count + BATCH_TIMEOUT_OVERHEAD_S
    return min(BATCH_TIMEOUT_CEILING_S, max(BATCH_TIMEOUT_FLOOR_S, scaled))


def _chunk_texts(texts: list[str]) -> list[list[str]]:
    """Split `texts` into sub-batches bounded by a total byte budget
    (_batch_max_bytes()) and a text count (_batch_max_texts()), so one
    oversized corpus cannot force a single subprocess call -- and its
    timeout, see _batch_timeout_s() -- to cover the entire scan window at
    once (finding #9). Each individual text still travels whole; this only
    bounds how many whole texts share one node invocation. A single text
    larger than the byte budget still gets its own one-text batch rather
    than being dropped (wf-pin-audit.py's own per-file size cap, applied
    before this function ever sees the text, is what keeps a truly oversized
    script out of the batch entirely)."""
    if not texts:
        return []
    max_bytes_per_batch = _batch_max_bytes()
    max_texts_per_batch = _batch_max_texts()
    batches: list[list[str]] = []
    current: list[str] = []
    current_bytes = 0
    for text in texts:
        text_bytes = len(text.encode("utf-8"))
        if current and (
            len(current) >= max_texts_per_batch
            or current_bytes + text_bytes > max_bytes_per_batch
        ):
            batches.append(current)
            current, current_bytes = [], 0
        current.append(text)
        current_bytes += text_bytes
    if current:
        batches.append(current)
    return batches


def _utf16_boundary_to_codepoint(text: str) -> list[int]:
    """Map every UTF-16 code-unit boundary of `text` (as wf-pin-lex.js/
    JavaScript would index it) to the code-point index of that same
    boundary in Python's own indexing of `text`.

    `mapping[k]` is the code-point offset corresponding to UTF-16 code-unit
    offset `k`, for every `k` from 0 to the UTF-16 length of `text`
    inclusive. The two indexings agree for a Basic-Multilingual-Plane
    character (one UTF-16 unit == one code point) and diverge for an astral
    character U+10000+ (JavaScript spends two code units on it, Python one
    code point). wf-pin-lex.js only ever emits offsets that land on a real
    character boundary, so every offset it returns is a valid index into
    this list.
    """
    mapping = [0]
    codepoint_index = 0
    for char in text:
        codepoint_index += 1
        units = 2 if ord(char) > 0xFFFF else 1
        mapping.extend([codepoint_index] * units)
    return mapping


def _normalize_offsets(text: str, entry: dict, index: int) -> None:
    """Convert `entry`'s "spans" and "uncapped" UTF-16 offsets (into `text`)
    to code-point offsets, in place -- see this module's own doc comment for
    why. Raises ShimUnavailable (naming `index`) if an offset lands outside
    `text`'s own boundary map: a shim result whose offsets do not fit the
    text it was computed from is exactly as untrustworthy as a wrong result
    count (finding #10)."""
    mapping = _utf16_boundary_to_codepoint(text)
    try:
        entry["spans"] = [
            [mapping[start], mapping[end], kind] for start, end, kind in entry["spans"]
        ]
        entry["uncapped"] = [
            [mapping[start], mapping[end]] for start, end in entry["uncapped"]
        ]
    except (IndexError, TypeError, ValueError) as exc:
        raise ShimUnavailable(
            f"lexer shim result entry {index} has an offset that does not fit its own text: {exc}"
        ) from exc


def _validate_entry(index: int, entry, text_count: int) -> None:
    """Raise ShimUnavailable (naming `index` and the offending shape) unless
    `entry` is either a per-script error entry (`{"error": "<str>"}`) or the
    full success shape (`{"spans": [...], "blanked": "<str>", "uncapped":
    [...]}`) with the right types for each key.

    Finding #10 (PR #1352 round 7): a malformed result entry -- `{}`, or a
    non-dict entry -- used to reach wf-pin-audit.py as an uncaught
    KeyError, exiting 1 with a traceback instead of the documented "shim
    unavailable" exit 3. A shim returning `text_count` entries that pass
    this per-entry check is required before any is trusted; a broken shim
    is a shim-level failure, never a per-script one.
    """
    if not isinstance(entry, dict):
        raise ShimUnavailable(
            f"lexer shim result entry {index} of {text_count} is not an "
            f"object: {type(entry).__name__}"
        )
    error = entry.get("error")
    if error is not None:
        if not isinstance(error, str):
            raise ShimUnavailable(
                f"lexer shim result entry {index} of {text_count} has a "
                f'non-string "error": {type(error).__name__}'
            )
        return
    missing = [key for key in ("spans", "blanked", "uncapped") if key not in entry]
    if missing:
        raise ShimUnavailable(
            f"lexer shim result entry {index} of {text_count} is missing "
            f'{missing} and carries no "error"'
        )
    if (
        not isinstance(entry["spans"], list)
        or not isinstance(entry["uncapped"], list)
        or not isinstance(entry["blanked"], str)
    ):
        raise ShimUnavailable(
            f"lexer shim result entry {index} of {text_count} has the wrong "
            f'type for "spans"/"blanked"/"uncapped"'
        )


def _lex_batch(texts: list[str]) -> list[dict]:
    """One node subprocess invocation for exactly this sub-batch of texts.

    Raises ShimUnavailable -- naming node, the shim path, and the exact
    failure -- for a SHIM-LEVEL failure: node cannot be launched, the shim
    exits non-zero, its stdout is not the expected JSON shape, the batch
    itself times out, or the result count does not match this sub-batch.
    """
    node_bin = _node_bin()
    shim_path = _shim_path()
    try:
        proc = subprocess.run(
            [node_bin, str(shim_path)],
            input=json.dumps({"texts": texts}),
            capture_output=True,
            text=True,
            timeout=_batch_timeout_s(len(texts)),
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ShimUnavailable(
            f"could not launch lexer shim ({node_bin} {shim_path}): {exc}"
        ) from exc
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or f"exit {proc.returncode}"
        raise ShimUnavailable(f"lexer shim ({node_bin} {shim_path}) failed: {detail}")
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise ShimUnavailable(
            f"lexer shim ({node_bin} {shim_path}) produced invalid JSON: {exc}"
        ) from exc
    results = payload.get("results") if isinstance(payload, dict) else None
    if not isinstance(results, list) or len(results) != len(texts):
        got = len(results) if isinstance(results, list) else "no"
        raise ShimUnavailable(
            f"lexer shim ({node_bin} {shim_path}) returned {got} result(s) "
            f"for {len(texts)} text(s)"
        )
    return results


def lex_texts(texts: list[str]) -> list[dict]:
    """Batch-lex `texts` through fanout-admission.js's own lexer.

    One or more node processes cover the whole list (see _chunk_texts()'s
    own doc comment for why more than one), regardless of how many texts
    are passed; an empty list returns an empty list without launching node.
    Each result dict is EITHER the normal shape -- "spans" ([[start, end,
    kind], ...], code-point offsets into `texts[i]`), "blanked" (the
    UTF-16-derived blanked text -- NOT code-point safe, see this module's
    own doc comment), and "uncapped" ([[start, end], ...], code-point
    offsets) -- OR a per-script `{"error": "<reason>"}` entry (budget
    exceeded, size cap, unlexable, or any other per-text lexer exception;
    see wf-pin-lex.js's own doc comment). Callers must check for the
    "error" key before reading any of the normal keys -- see
    wf-pin-audit.py's lex_error().

    Raises ShimUnavailable -- naming node, the shim path, and the exact
    failure -- for any SHIM-LEVEL failure, including one whose own result
    entries do not have a trustworthy shape (see _validate_entry()). Never
    returns a degraded result silently.
    """
    if not texts:
        return []
    results: list[dict] = []
    for batch in _chunk_texts(texts):
        results.extend(_lex_batch(batch))
    text_count = len(texts)
    for index, (text, entry) in enumerate(zip(texts, results)):
        _validate_entry(index, entry, text_count)
        if "error" not in entry:
            _normalize_offsets(text, entry, index)
    return results
