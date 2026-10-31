#!/usr/bin/env python3
"""rent-check fact engine: the deterministic half of the audit.

The skill's doctrine says enforcement beats prose for anything that must hold
every time -- then states every one of its own checks as prose an agent may or
may not execute. This script is the correction. It owns the facts; the agent
owns the judgment, and never the reverse.

What lives here is exactly what needs no judgment: which files load, how big
they are, whether their references resolve, which claims are shaped like
things that expire, how much a proposed edit grows the always-loaded surface,
and what past runs decided. Everything requiring a verdict stays with the
model.

Design rules, in priority order:
  1. Facts only. Subcommands emit evidence and worklists, never verdicts.
     `expiring` returns candidates to verify, not violations to fix.
  2. Degradation is explicit. Missing git, unreadable file, absent helper ->
     an "unavailable" record naming the reason. Never a silent skip: a
     coverage matrix with no empty cells that is quietly incomplete is worse
     than an acknowledged gap.
  3. Stdlib only, Python 3.9+. The skill claims portability to any harness;
     an engine with dependencies would make that a lie.

Every subcommand accepts --json. Exit codes: 0 clean, 1 findings that are
unambiguously defects (dead refs, over-ceiling index), 2 usage error.
Worklist-shaped subcommands exit 0 unless --strict.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1

# Context-file names, matching the skill's Phase 1 discovery command.
CONTEXT_NAMES = (
    "AGENTS.md",
    "CLAUDE.md",
    "CLAUDE.local.md",
    ".cursorrules",
    "copilot-instructions.md",
)

# Pruned by NAME, never by depth: a depth cap is silent truncation. Measured
# in the skill's own dogfood: -maxdepth 4 found 31 of 43 context files.
PRUNE_DIRS = {
    "node_modules", ".git", ".next", "dist", "vendor", "worktrees",
    ".worktrees", "__pycache__", ".venv", "venv", "build", "target",
    # Our OWN output. Phase 5 writes drafts that mirror audited paths under
    # <root>/.rent-check/<date>/; without this the next run audits its own
    # drafts, inflates the authoritative file count, and can draft drafts of
    # drafts. Self-inflicted recursion, caught by pro-gate before it shipped.
    ".rent-check",
}

# chars/4 is the folk estimate. Calibrated twice against live /context, it
# under-measured dense markdown by 1.5-1.7x, so estimates are FLOORS and the
# calibrated figure is the one to plan against.
CALIBRATION = 1.6

# Memory index limits (code.claude.com/docs/en/memory): 200 lines OR 25KB,
# whichever comes first. The byte half is the one that actually bites.
MEMORY_MAX_LINES = 200
MEMORY_MAX_BYTES = 25 * 1024

EMPHASIS_RE = re.compile(r"\b(IMPORTANT|CRITICAL|NEVER|ALWAYS|MUST)\b")
# Anthropic's own system prompt converged to ~1.4 emphasis keywords per 1k
# words across 265 versions; well above ~2 means emphasis ranks nothing.
EMPHASIS_REFERENCE = 1.4

# R7 -- claim shapes that expire silently. Tuned for RECALL: this produces a
# worklist for a human or model to verify against the authority of record, so
# a false positive costs one glance and a false negative costs a rotted fact.
EXPIRING_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("model-name", re.compile(
        r"\b(?:GPT|Claude|Gemini|Llama|Mistral|Grok|Sonnet|Opus|Haiku)"
        r"[- ]?\d+(?:[.-]\w+)*\b", re.I)),
    # OpenAI's o-series, case-SENSITIVE so it does not swallow "O2" or a
    # grade letter. Its own pattern rather than folded into the case-
    # insensitive alternation above.
    ("model-name", re.compile(r"\bo[1-9](?:-(?:mini|pro|preview))?\b")),
    # Two branches: a v-prefix makes 2-part versions unambiguous (v1.2),
    # while a bare number needs 3 parts or "step 3.2" becomes noise.
    ("version", re.compile(
        r"(?<![\w.])v\d+\.\d+(?:\.\d+)*(?![\w.])"
        r"|(?<![\w.])\d+\.\d+(?:\.\d+)+(?![\w.])")),
    # Dates are the canonical silently-expiring claim shape.
    ("date", re.compile(r"\b20\d{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])\b")),
    ("duration-range", re.compile(
        r"~?\d+\s*(?:[-–—]|to)\s*\d+\s*(?:min|mins|minutes|hour|hours|hrs|sec|seconds)\b", re.I)),
    ("duration", re.compile(r"~\s*\d+\s*(?:min|mins|minutes|hour|hours|hrs)\b", re.I)),
    ("price", re.compile(r"\$\s?\d[\d,]*(?:\.\d+)?")),
    ("permission-level", re.compile(
        r"\b(?:siteOwner|siteFullUser|siteRestrictedUser|siteUnverifiedUser|"
        r"owner|admin|read-only|readonly|service_role|super-?admin)\b")),
    ("quota-count", re.compile(
        r"\b\d+\s+(?:zones|properties|seats|repos|repositories|accounts|tools|slots)\b", re.I)),
)

# A backticked token that looks like a path (has a separator or a known
# extension) rather than a command or an identifier.
PATH_HINT_RE = re.compile(r"[/\\]|\.(?:md|mjs|cjs|js|ts|tsx|py|sh|json|ya?ml|toml|sql|txt)$")
BACKTICK_RE = re.compile(r"`([^`\n]{2,200})`")


def _fail(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"rent-check: {msg}", file=sys.stderr)
    raise SystemExit(2)


# --------------------------------------------------------------------------
# fingerprints
# --------------------------------------------------------------------------

@dataclass
class Fingerprint:
    kind: str      # "git-blob" | "size-mtime" | "unavailable"
    value: str
    detail: str = ""


def git_available(cwd: Path) -> bool:
    try:
        subprocess.run(
            ["git", "-C", str(cwd), "rev-parse", "--show-toplevel"],
            check=True, capture_output=True, timeout=5,
        )
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def fingerprint(path: Path) -> Fingerprint:
    """Prefer the git blob SHA -- content-addressed, stable across checkout.

    A prior ledger recorded 'git blob shas unavailable' and fell back to
    size+mtime, which false-positives on touch and false-negatives on a
    same-size edit. The SHA is one command away.
    """
    try:
        out = subprocess.run(
            ["git", "hash-object", "--", str(path)],
            check=True, capture_output=True, text=True, timeout=5,
        )
        return Fingerprint("git-blob", out.stdout.strip())
    except (OSError, subprocess.SubprocessError) as exc:
        try:
            st = path.stat()
            return Fingerprint(
                "size-mtime", f"{st.st_size}:{int(st.st_mtime)}",
                detail=f"git unavailable ({type(exc).__name__}); weaker fingerprint",
            )
        except OSError as stat_exc:
            return Fingerprint("unavailable", "", detail=str(stat_exc))


# --------------------------------------------------------------------------
# inventory (L1 of the skill's flow)
# --------------------------------------------------------------------------

@dataclass
class FileRecord:
    path: str
    load_class: str
    bytes: int
    lines: int
    est_tokens_floor: int
    est_tokens_calibrated: int
    fingerprint: dict[str, str]
    vcs: dict[str, str]


def checkout_freshness(root: Path) -> dict[str, Any]:
    """Is this checkout current enough for its content to mean anything?

    A stale checkout does not error. It silently answers a different question
    than the one asked, and every downstream verdict inherits the lie.
    Measured 2026-08-11: an audit of prbot read a checkout 129 commits behind
    origin/main, reported two enumeration defects as live, and those findings
    reached a filed architecture issue. Both were already fixed upstream. The
    same run's targeted verifiers read `origin/main` objects and correctly
    found nothing -- so the tooling contradicted itself and the stale half
    won, because nothing flagged the staleness.

    Facts only: this reports the distance, never a verdict. `no-upstream` and
    `unfetched` are honest states, not failures -- a detached HEAD or an
    offline run is legitimate, but the reader must be told.
    """
    def _git(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", "-C", str(root), *args],
                              capture_output=True, text=True, timeout=10)

    try:
        if _git("rev-parse", "--show-toplevel").returncode != 0:
            return {"state": "unavailable", "detail": "not a git repository"}

        head = _git("rev-parse", "--short", "HEAD")
        if head.returncode != 0:
            return {"state": "unavailable", "detail": "no HEAD (empty repository?)"}

        up = _git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
        if up.returncode != 0:
            return {"state": "no-upstream", "head": head.stdout.strip(),
                    "detail": "branch tracks no upstream; freshness cannot be judged"}
        upstream = up.stdout.strip()

        counts = _git("rev-list", "--left-right", "--count", f"HEAD...{upstream}")
        if counts.returncode != 0:
            # The ref exists but has never been fetched in this clone.
            return {"state": "unfetched", "head": head.stdout.strip(),
                    "upstream": upstream,
                    "detail": "cannot compare to upstream; run `git fetch` first"}
        ahead_s, _, behind_s = counts.stdout.strip().partition("\t")
        ahead, behind = int(ahead_s or 0), int(behind_s.strip() or 0)
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        return {"state": "unavailable", "detail": f"{type(exc).__name__}: {exc}"}

    rec: dict[str, Any] = {
        "state": "stale" if behind else "current",
        "head": head.stdout.strip(),
        "upstream": upstream,
        "behind": behind,
        "ahead": ahead,
    }
    if behind:
        rec["detail"] = (
            f"{behind} commit(s) behind {upstream}: this audit describes a past "
            "state of the repo. Fetch and re-run, or read the upstream objects "
            "directly (`git show <upstream>:<path>`), before trusting any finding."
        )
    return rec


def vcs_status(path: Path) -> dict[str, str]:
    """Is this context file visible to everyone, or only to this machine?

    An untracked context file still steers every local agent while being
    invisible to teammates, clean checkouts, and CI -- so it freezes while
    its tracked twin keeps moving. Measured: better-ccflare's AGENTS.md sat
    gitignored at 4 commits while CLAUDE.md reached 91, and drifted into
    naming a mode the CLI does not accept. will-os carries the same shape.

    `ignored` is reported separately from `tracked` because the pair
    distinguishes a deliberate local-only file (ignored) from one nobody ever
    committed (untracked, not ignored) -- the latter is one `git clean` from
    gone, which is a different conversation than the former.
    """
    def _git(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(path.parent), *args],
            capture_output=True, text=True, timeout=5,
        )

    try:
        if _git("rev-parse", "--show-toplevel").returncode != 0:
            return {"state": "unavailable", "detail": "not a git repository"}
        tracked = _git("ls-files", "--error-unmatch", "--", path.name).returncode == 0
        # check-ignore: 0 = ignored, 1 = not ignored, other = error.
        ig = _git("check-ignore", "--no-index", "-q", "--", path.name)
        if ig.returncode not in (0, 1):
            return {"state": "unavailable",
                    "detail": f"check-ignore exit {ig.returncode}"}
        ignored = ig.returncode == 0
    except (OSError, subprocess.SubprocessError) as exc:
        return {"state": "unavailable", "detail": f"{type(exc).__name__}: {exc}"}

    if tracked:
        # Tracked-and-ignored is legal (force-added) and worth naming: the
        # ignore rule will silently exclude any NEW sibling context file.
        return {"state": "tracked-ignored" if ignored else "tracked", "detail": ""}
    return {
        "state": "untracked-ignored" if ignored else "untracked",
        "detail": (
            "loads locally, invisible to clean checkouts and CI; drifts from any tracked twin"
            if ignored else
            "never committed and not ignored -- one `git clean -fd` from permanent loss"
        ),
    }


def classify_load_class(rel: Path, at_scan_root: bool) -> str:
    """Load class RELATIVE TO THE SCANNED ROOT.

    The platform rule: files in the hierarchy at or above the working
    directory load in full at launch; files in subdirectories load only when
    the agent reads files there (code.claude.com/docs/en/memory).

    This walk goes DOWNWARD from the root it was given, so it classifies
    root-level files as always-loaded and nested files as on-read. Context
    files in ANCESTOR directories above that root are outside the scan and
    are reported as an explicit gap by cmd_inventory -- an acknowledged
    limitation, never a silent one. If you scan a subdirectory of a larger
    repo, its "always-loaded" is relative to that subdirectory.
    """
    return "always-loaded" if at_scan_root else "on-read"


def discover(root: Path) -> list[Path]:
    """Every context file under root, symlinked directories included.

    followlinks=True with a realpath guard: the default skipped symlinked
    trees silently, which is the failure this module's rule 2 forbids. The
    guard is what makes following safe -- a symlink cycle would otherwise
    walk forever.
    """
    found: list[Path] = []
    seen: set[str] = set()
    for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
        real = os.path.realpath(dirpath)
        if real in seen:
            dirnames[:] = []
            continue
        seen.add(real)
        dirnames[:] = [d for d in dirnames if d not in PRUNE_DIRS]
        for name in filenames:
            if name in CONTEXT_NAMES:
                found.append(Path(dirpath) / name)
    return sorted(found)


def cmd_inventory(args: argparse.Namespace) -> int:
    """Inventory a tree, or a single context file.

    The skill's argument-hint is `[context-file-path | repo-root]`, so
    rejecting a file broke the documented contract -- and the workaround
    (pass the parent directory) silently widens the audit to sibling files,
    which is worse than an error.
    """
    target = Path(args.root).resolve()
    if target.is_file():
        root, paths = target.parent, [target]
    elif target.is_dir():
        root, paths = target, discover(target)
    else:
        _fail(f"no such file or directory: {target}")

    records: list[FileRecord] = []
    for path in paths:
        try:
            raw = path.read_bytes()
        except OSError as exc:
            records.append(FileRecord(
                str(path), "unavailable", 0, 0, 0, 0,
                {"kind": "unavailable", "value": "", "detail": str(exc)},
                {"state": "unavailable", "detail": "file unreadable"},
            ))
            continue
        text = raw.decode("utf-8", errors="replace")
        floor = len(text) // 4
        records.append(FileRecord(
            path=str(path),
            load_class=classify_load_class(path, path.parent == root),
            bytes=len(raw),
            # splitlines, not count("\n") -- same off-by-one that made a
            # 201-line memory index report clean at the ceiling.
            lines=len(text.splitlines()),
            est_tokens_floor=floor,
            est_tokens_calibrated=int(floor * CALIBRATION),
            fingerprint=asdict(fingerprint(path)),
            vcs=vcs_status(path),
        ))

    # Ancestor context files above the scan root also load at launch but are
    # outside this walk. Name them so the gap is acknowledged, per rule 2.
    ancestors = [
        str(p / name)
        for p in root.parents
        for name in CONTEXT_NAMES
        if (p / name).is_file()
    ]

    always = [r for r in records if r.load_class == "always-loaded"]
    invisible = [r for r in records if r.vcs.get("state", "").startswith("untracked")]
    freshness = checkout_freshness(root)
    payload = {
        "schema": SCHEMA_VERSION,
        "root": str(root),
        # First field after root, deliberately: every finding below is only as
        # current as the checkout it was read from.
        "checkout": freshness,
        "file_count": len(records),
        "ancestor_files_not_scanned": ancestors,
        "ancestor_note": (
            "these load in full at launch too but lie above the scan root; "
            "re-run with a higher root to include them"
        ),
        "always_loaded_bytes": sum(r.bytes for r in always),
        "always_loaded_tokens_calibrated": sum(r.est_tokens_calibrated for r in always),
        # A worklist, not a verdict: an untracked context file may be
        # deliberate. It is never deliberate by accident, which is the point.
        "untracked_context_files": [r.path for r in invisible],
        "token_estimate_note": (
            f"floor = chars/4; calibrated = floor x {CALIBRATION} "
            "(chars/4 under-measured dense markdown 1.5-1.7x against live /context)"
        ),
        "files": [asdict(r) for r in records],
    }
    emit(payload, args)
    # Only staleness is unambiguous enough to fail on: an untracked file may be
    # deliberate, but a checkout behind upstream cannot describe current state.
    return 1 if (getattr(args, "strict", False)
                 and freshness.get("state") == "stale") else 0


# --------------------------------------------------------------------------
# R1 dead references
# --------------------------------------------------------------------------

def extract_path_refs(text: str) -> list[str]:
    """Backticked tokens that name a path.

    Spaces do NOT disqualify a token: `docs/my notes.md` is a real path and
    gating on 'contains a space' made every spaced path invisible in both
    directions -- a blind spot, not a conservative default. Instead, judge
    the first whitespace-delimited word: if that is path-shaped the token is
    a path, and if it is not (`pnpm run build`) it is a command line.
    URLs are excluded: they are not filesystem paths and cannot be resolved.
    """
    refs = []
    for m in BACKTICK_RE.finditer(text):
        tok = m.group(1).strip()
        if not tok or "://" in tok:
            continue
        head = tok.split(" ", 1)[0]
        looks_like_path = tok.startswith(("~", ".", "/")) or PATH_HINT_RE.search(head)
        if not looks_like_path:
            continue
        if PATH_HINT_RE.search(tok):
            refs.append(tok)
    return refs


def resolve_ref(ref: str, base: Path, repo_root: Path | None) -> Path | None:
    raw = ref.split("#", 1)[0].strip()
    if not raw or raw.endswith("/*") or "*" in raw:
        return None  # globs are not resolvable as literal paths
    if raw.startswith("~"):
        return Path(raw).expanduser()
    if raw.startswith("/"):
        return Path(raw)
    for anchor in filter(None, (base, repo_root)):
        cand = anchor / raw
        if cand.exists():
            return cand
    return (base / raw)


def cmd_refs(args: argparse.Namespace) -> int:
    target = Path(args.file).resolve()
    if not target.is_file():
        _fail(f"not a file: {target}")
    repo_root = Path(args.repo_root).resolve() if args.repo_root else None
    text = target.read_text(encoding="utf-8", errors="replace")

    dead, checked = [], 0
    for ref in dict.fromkeys(extract_path_refs(text)):
        resolved = resolve_ref(ref, target.parent, repo_root)
        if resolved is None:
            continue
        checked += 1
        if not resolved.exists():
            line = next(
                (i for i, l in enumerate(text.splitlines(), 1) if f"`{ref}`" in l), None
            )
            dead.append({"ref": ref, "line": line, "resolved_to": str(resolved)})

    payload = {
        "schema": SCHEMA_VERSION,
        "file": str(target),
        "refs_checked": checked,
        "dead_count": len(dead),
        "dead": dead,
    }
    emit(payload, args)
    return 1 if dead else 0


# --------------------------------------------------------------------------
# R6 emphasis density
# --------------------------------------------------------------------------

def cmd_emphasis(args: argparse.Namespace) -> int:
    target = Path(args.file).resolve()
    if not target.is_file():
        _fail(f"not a file: {target}")
    text = target.read_text(encoding="utf-8", errors="replace")
    words = len(text.split())
    hits = EMPHASIS_RE.findall(text)
    per_1k = (len(hits) / words * 1000) if words else 0.0
    payload = {
        "schema": SCHEMA_VERSION,
        "file": str(target),
        "words": words,
        "emphasis_tokens": len(hits),
        "per_1k_words": round(per_1k, 2),
        "reference_per_1k": EMPHASIS_REFERENCE,
        "note": "reference is Anthropic's own converged density; this is a signal, not a gate",
    }
    emit(payload, args)
    return 0


# --------------------------------------------------------------------------
# R7 expiring-claim worklist
# --------------------------------------------------------------------------

def cmd_expiring(args: argparse.Namespace) -> int:
    target = Path(args.file).resolve()
    if not target.is_file():
        _fail(f"not a file: {target}")
    text = target.read_text(encoding="utf-8", errors="replace")

    items: list[dict[str, Any]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for kind, pattern in EXPIRING_PATTERNS:
            for m in pattern.finditer(line):
                items.append({
                    "kind": kind,
                    "match": m.group(0),
                    "line": lineno,
                    "context": line.strip()[:200],
                })

    payload = {
        "schema": SCHEMA_VERSION,
        "file": str(target),
        "candidate_count": len(items),
        "candidates": items,
        "note": (
            "WORKLIST, not verdicts. Verify each against its authority of record "
            "(the tool/API/ledger that owns the fact), not another document that "
            "may have copied the same stale value. If the owning authority "
            "declines to assert it, the context file must not assert it either."
        ),
    }
    emit(payload, args)
    return 1 if (items and args.strict) else 0


# --------------------------------------------------------------------------
# claimed enforcement (the highest-severity class)
# --------------------------------------------------------------------------

# A context file asserting that something is enforced is making a checkable
# claim about the repo. When the mechanism does not exist, an agent reads the
# claim, believes CI covers the work, and SKIPS it -- so a false enforcement
# claim does not merely misinform, it subtracts real verification.
#
# Measured across 5 repos: better-ccflare documented a pre-push hook that
# existed in no versioned config or .git/hooks; startupbros.com's "Verify your
# work" had no required check behind it; prbot claims a GitHub Actions job
# runs `resend:webhooks:audit` while zero of its 19 workflow files mention
# resend at all.
#
# Tuned for RECALL like R7's patterns: a false positive costs one glance, a
# false negative leaves an agent trusting a gate that is not there.
ENFORCEMENT_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("ci-job", re.compile(
        r"\b(?:CI|GitHub Actions?|workflow|pipeline)\b[^.]{0,80}?"
        r"\b(?:runs?|checks?|enforces?|validates?|fails?|blocks?|gates?)\b", re.I)),
    ("git-hook", re.compile(
        r"\b(?:pre-commit|pre-push|post-merge|commit-msg|husky|lefthook)\b", re.I)),
    ("auto-behavior", re.compile(
        r"\bauto(?:matically|-updated?|-generated?|-applied?)\b"
        r"|\bhandled automatically\b", re.I)),
    ("lint-rule", re.compile(
        r"\b(?:lint(?:er)? rule|eslint rule|ruff rule|phpstan|phpcs|biome)\b"
        r"[^.]{0,60}?\b(?:enforces?|forbids?|blocks?|errors?|fails?)\b", re.I)),
    ("blocking-claim", re.compile(
        r"\b(?:fails? the (?:check|build|gate)|blocks? (?:the )?merge|"
        r"required (?:status )?check|cannot be merged|will not merge)\b", re.I)),
    ("guard-claim", re.compile(
        r"\b(?:guard|hook|gate)\b[^.]{0,60}?\b(?:prevents?|blocks?|rejects?|refuses?)\b", re.I)),
)


def cmd_claims(args: argparse.Namespace) -> int:
    """Worklist of enforcement-shaped assertions to verify against the repo.

    Emits candidates, never verdicts: whether a claimed mechanism exists is a
    question about THIS repo's config, and answering it is judgment the model
    owns. The script's job is to guarantee no such claim goes unexamined --
    which is exactly what failed when a documented pre-push hook survived
    every prose-only audit for months.
    """
    target = Path(args.file).resolve()
    if not target.is_file():
        _fail(f"not a file: {target}")
    text = target.read_text(encoding="utf-8", errors="replace")

    in_fence = False
    items: list[dict[str, Any]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        # A fenced block is usually the command itself, not a claim about it.
        if in_fence:
            continue
        seen: set[str] = set()
        for kind, pattern in ENFORCEMENT_PATTERNS:
            m = pattern.search(line)
            if m and kind not in seen:
                seen.add(kind)
                items.append({
                    "kind": kind,
                    "match": m.group(0)[:120],
                    "line": lineno,
                    "context": stripped[:200],
                })

    payload = {
        "schema": SCHEMA_VERSION,
        "file": str(target),
        "candidate_count": len(items),
        "candidates": items,
        "note": (
            "WORKLIST, not verdicts. For each, find the mechanism in THIS repo "
            "(.github/workflows, .git/hooks + core.hooksPath, package.json "
            "scripts, lint config, rulesets) and confirm it exists AND covers "
            "what the sentence claims. A claim whose mechanism is absent is "
            "worse than no claim: an agent skips the work believing it is "
            "covered. Verified-real claims are not defects -- do not cut them."
        ),
    }
    emit(payload, args)
    return 1 if (items and args.strict) else 0


# --------------------------------------------------------------------------
# byte-delta gate for corrections
# --------------------------------------------------------------------------

def cmd_delta(args: argparse.Namespace) -> int:
    """Byte delta of a correction -- per FIX, not per file.

    Whole-file aggregate was gameable: a bloated FIX passes --strict
    whenever a CUT elsewhere in the same draft removes more bytes. The
    workflow requires a delta for EVERY individual FIX, so --hunks takes a
    manifest of {id, type, original, replacement} and each is measured
    alone. The file-level number stays as supplemental context.
    """
    original, draft = Path(args.original), Path(args.draft)
    for p in (original, draft):
        if not p.is_file():
            _fail(f"not a file: {p}")
    ob, db = original.stat().st_size, draft.stat().st_size
    delta = db - ob

    hunks: list[dict[str, Any]] = []
    grew_hunks: list[str] = []
    if args.hunks:
        manifest_path = Path(args.hunks)
        if not manifest_path.is_file():
            _fail(f"no hunk manifest at {manifest_path}")
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            _fail(f"hunk manifest is not valid JSON: {exc}")
        for h in manifest:
            hd = len(h.get("replacement", "")) - len(h.get("original", ""))
            entry = {
                "id": h.get("id"), "type": h.get("type", "FIX"),
                "delta_bytes": hd, "grew": hd > 0,
            }
            hunks.append(entry)
            if hd > 0:
                grew_hunks.append(str(h.get("id")))

    payload = {
        "schema": SCHEMA_VERSION,
        "original": str(original), "draft": str(draft),
        "original_bytes": ob, "draft_bytes": db,
        "delta_bytes": delta,
        "delta_tokens_calibrated": int(abs(delta) / 4 * CALIBRATION) * (1 if delta >= 0 else -1),
        "grew": delta > 0,
        "hunks": hunks,
        "hunks_that_grew": grew_hunks,
        "note": (
            "A FIX that lands more always-loaded bytes than it removed traded one "
            "defect (wrong) for another (bloated). A positive delta needs an "
            "explicit justification; the default answer to 'this needs more "
            "explanation' is DEMOTE the explanation to an on-read doc. Without "
            "--hunks this reports the file aggregate only, which a shrinking edit "
            "elsewhere can mask."
        ),
    }
    emit(payload, args)
    if not args.strict:
        return 0
    # With a manifest, judge each FIX on its own; without one, fall back to
    # the aggregate rather than silently passing.
    return 1 if (grew_hunks if hunks else delta > 0) else 0


# --------------------------------------------------------------------------
# P3 memory ceilings (both dimensions)
# --------------------------------------------------------------------------

def cmd_memory(args: argparse.Namespace) -> int:
    """P3 ceilings -- which apply to MEMORY.md and nothing else.

    The docs are explicit: "This limit applies only to MEMORY.md. CLAUDE.md
    files are loaded in full regardless of length." Applying the truncation
    verdict to any file handed in would manufacture a defect the platform
    does not have, so the limit is scoped by filename and `--force` is the
    deliberate override for a differently-named index.
    """
    target = Path(args.file).resolve()
    if not target.is_file():
        _fail(f"not a file: {target}")
    raw = target.read_bytes()
    # splitlines, not count("\n"): a file whose last line lacks a trailing
    # newline was under-counted by one, so a 201-line index reported clean
    # at exactly the ceiling this check exists to enforce.
    lines = len(raw.decode("utf-8", errors="replace").splitlines())

    applies = target.name.lower() == "memory.md" or args.force
    over_lines = applies and lines > MEMORY_MAX_LINES
    over_bytes = applies and len(raw) > MEMORY_MAX_BYTES
    payload = {
        "schema": SCHEMA_VERSION,
        "file": str(target),
        "limit_applies": applies,
        "lines": lines, "max_lines": MEMORY_MAX_LINES, "over_lines": over_lines,
        "bytes": len(raw), "max_bytes": MEMORY_MAX_BYTES, "over_bytes": over_bytes,
        "truncated": over_lines or over_bytes,
        "note": (
            "limit is 200 lines OR 25KB, whichever comes first, and applies to "
            "MEMORY.md ONLY -- CLAUDE.md loads in full regardless of length "
            "(code.claude.com/docs/en/memory). Use --force for a memory index "
            "under a different filename."
        ),
    }
    emit(payload, args)
    return 1 if payload["truncated"] else 0


# --------------------------------------------------------------------------
# L3 ledger
# --------------------------------------------------------------------------

@dataclass
class LedgerEntry:
    schema: int
    run: str
    root: str
    path: str
    fingerprint: dict[str, str]
    bytes: int
    verdicts: list[dict[str, Any]] = field(default_factory=list)


def cmd_ledger_write(args: argparse.Namespace) -> int:
    """Append this run's ledger, including the verdicts it issued.

    Without a verdict manifest every entry kept an empty `verdicts` list, so
    ledger-resolve had only file-level fingerprints and the self-measurement
    loop could never produce per-verdict outcomes -- the loop existed on
    paper only. --verdicts takes {"<path>": [{id, type, quote}, ...]}; the
    `quote` is what makes resolution mechanical later, since its presence or
    absence in the current file is direct evidence about that one verdict.
    """
    root = Path(args.root).resolve()
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    manifest: dict[str, list[dict[str, Any]]] = {}
    if args.verdicts:
        mpath = Path(args.verdicts)
        if not mpath.is_file():
            _fail(f"no verdict manifest at {mpath}")
        try:
            manifest = json.loads(mpath.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            _fail(f"verdict manifest is not valid JSON: {exc}")

    written = 0
    with out.open("a", encoding="utf-8") as fh:
        for path in discover(root):
            key_matches = [k for k in manifest if Path(k).resolve() == path.resolve()]
            verdicts = manifest[key_matches[0]] if key_matches else []
            entry = LedgerEntry(
                schema=SCHEMA_VERSION, run=args.run, root=str(root), path=str(path),
                fingerprint=asdict(fingerprint(path)),
                bytes=path.stat().st_size if path.exists() else 0,
                verdicts=verdicts,
            )
            fh.write(json.dumps(asdict(entry), sort_keys=True) + "\n")
            written += 1

    payload = {
        "schema": SCHEMA_VERSION, "ledger": str(out), "entries_written": written,
        "verdicts_attached": sum(len(v) for v in manifest.values()),
    }
    emit(payload, args)
    return 0


def cmd_ledger_resolve(args: argparse.Namespace) -> int:
    """Attach evidence of what happened to each audited file since its run.

    Deliberately does NOT classify applied/reverted itself: proving a specific
    verdict was applied requires the draft's semantics, which is judgment. It
    returns the evidence (fingerprint match, commits touching the file since
    the run) and lets the model decide -- with something to decide ON, which
    is the whole point.
    """
    ledger = Path(args.ledger)
    if not ledger.is_file():
        _fail(f"no ledger at {ledger}")

    results = []
    for line in ledger.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            results.append({"raw": line[:120], "status": "unparseable: legacy prose ledger"})
            continue

        path = Path(entry.get("path", ""))
        rec: dict[str, Any] = {"path": str(path), "run": entry.get("run")}
        if not path.exists():
            rec["status"] = "file-gone"
            results.append(rec)
            continue

        now = fingerprint(path)
        was = entry.get("fingerprint", {})
        rec["changed_since_run"] = not (
            was.get("kind") == now.kind and was.get("value") == now.value
        )
        rec["fingerprint_then"] = was
        rec["fingerprint_now"] = asdict(now)

        run_date = entry.get("run")
        if run_date and git_available(path.parent):
            try:
                out = subprocess.run(
                    ["git", "-C", str(path.parent), "log", f"--since={run_date}",
                     "--oneline", "--", str(path)],
                    check=True, capture_output=True, text=True, timeout=10,
                )
                rec["commits_since_run"] = [l for l in out.stdout.splitlines() if l]
            except (OSError, subprocess.SubprocessError) as exc:
                rec["commits_since_run"] = f"unavailable: {type(exc).__name__}"
        else:
            rec["commits_since_run"] = "unavailable: no git or no run date"

        # Per-verdict evidence. A quoted span that has vanished is direct
        # evidence a CUT/MERGE landed; one still present after a CUT is
        # direct evidence it did not. Still evidence, not a classification:
        # the model decides applied vs reverted, now with something to
        # decide on.
        current = path.read_text(encoding="utf-8", errors="replace")
        verdict_evidence = []
        for v in entry.get("verdicts", []):
            quote = v.get("quote")
            verdict_evidence.append({
                "id": v.get("id"), "type": v.get("type"),
                "quote_present_now": (quote in current) if quote else None,
                "quote_checked": bool(quote),
            })
        rec["verdicts"] = verdict_evidence
        results.append(rec)

    emit({"schema": SCHEMA_VERSION, "ledger": str(ledger), "entries": results}, args)
    return 0


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------

def emit(payload: dict[str, Any], args: argparse.Namespace) -> None:
    if getattr(args, "json", False):
        print(json.dumps(payload, indent=2, sort_keys=True))
        return
    for key, value in payload.items():
        if isinstance(value, list):
            print(f"{key}: {len(value)}")
            for item in value[:20]:
                print(f"  - {json.dumps(item, sort_keys=True)}")
            if len(value) > 20:
                print(f"  ... {len(value) - 20} more (use --json for all)")
        else:
            print(f"{key}: {value}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="rent-check",
        description="Deterministic fact engine for the rent-check skill. Facts and worklists only, never verdicts.",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name: str, fn, **kw):
        sp = sub.add_parser(name, **kw)
        sp.set_defaults(fn=fn)
        sp.add_argument("--json", action="store_true", help="machine-readable output")
        return sp

    sp = add("inventory", cmd_inventory, help="discover context files with load class, bytes, calibrated tokens")
    sp.add_argument("root", nargs="?", default=".")
    sp.add_argument("--strict", action="store_true",
                    help="exit 1 when the checkout is behind its upstream")

    sp = add("refs", cmd_refs, help="R1: backticked path references that do not resolve")
    sp.add_argument("file")
    sp.add_argument("--repo-root", default=None)

    sp = add("emphasis", cmd_emphasis, help="R6: emphasis-keyword density per 1k words")
    sp.add_argument("file")

    sp = add("expiring", cmd_expiring, help="R7: worklist of claim shapes that expire silently")
    sp.add_argument("file")
    sp.add_argument("--strict", action="store_true", help="exit 1 when candidates exist")

    sp = add("claims", cmd_claims,
             help="worklist of enforcement-shaped assertions to verify against the repo")
    sp.add_argument("file")
    sp.add_argument("--strict", action="store_true", help="exit 1 when candidates exist")

    sp = add("delta", cmd_delta, help="byte delta of a correction, per FIX with --hunks")
    sp.add_argument("original")
    sp.add_argument("draft")
    sp.add_argument("--hunks", default=None,
                    help='JSON list of {id,type,original,replacement} so each FIX is measured alone')
    sp.add_argument("--strict", action="store_true",
                    help="exit 1 when any FIX grew (or, without --hunks, when the file grew)")

    sp = add("memory", cmd_memory, help="P3: memory-index ceilings (200 lines OR 25KB, MEMORY.md only)")
    sp.add_argument("file")
    sp.add_argument("--force", action="store_true",
                    help="apply the limits to a memory index not named MEMORY.md")

    sp = add("ledger-write", cmd_ledger_write, help="L3: append a JSONL ledger for this run")
    sp.add_argument("root", nargs="?", default=".")
    sp.add_argument("--run", required=True, help="run identifier, e.g. 2026-08-11")
    sp.add_argument("--out", required=True)
    sp.add_argument("--verdicts", default=None,
                    help='JSON {"<path>": [{id,type,quote}]} so outcomes are resolvable later')

    sp = add("ledger-resolve", cmd_ledger_resolve, help="L3: attach post-run evidence to each ledger entry")
    sp.add_argument("ledger")

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.fn(args))


if __name__ == "__main__":
    raise SystemExit(main())
