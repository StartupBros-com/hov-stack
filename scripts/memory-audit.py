#!/usr/bin/env python3
"""Audit Claude Code project memories without exposing memory contents."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import io
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from floor_assert import FloorNotMet, require_floor  # noqa: E402

ALLOWED_TYPES = {"user", "feedback", "project", "reference"}
YAML_LITERALS = {"null", "~", "true", "false", "none"}
LINK_RE = re.compile(r"\]\((?P<target><[^>]+>|(?:\\.|[^)])+)\)")
WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
DATE_PATTERNS = (
    re.compile(r"(?i)\b(?:status|checkpoint|status\s+as\s+of|checkpoint\s+as\s+of)\s*[:=-]?\s*(20\d{2}-\d{2}-\d{2})\b"),
    re.compile(r"(?i)\b(?:status|checkpoint)\s+date\s*[:=-]\s*(20\d{2}-\d{2}-\d{2})\b"),
)
SENSITIVE_FILENAME_RE = re.compile(r"(?i)(?:^|[._-])(secret|credential|password|passwd|api[_-]?key|access[_-]?token|private[_-]?key)(?:[._-]|$)")
# WhatsApp linked-device authority and its raw mirror are SQLite databases, not
# text secrets, so content signatures cannot catch an accidental copy. Quarantine
# the exact store filenames (and SQLite sidecars) before memory backup.
WHATSAPP_STORE_FILENAME_RE = re.compile(r"(?i)^(?:session|wacli)\.db(?:-(?:journal|shm|wal|mj.*))?$")
SENSITIVE_KEY_RE = re.compile(r"(?i)(secret|credential|password|passwd|token|api[_-]?key|private[_-]?key)")
# Historical write bug: an unquoted '#' in a frontmatter value starts a YAML
# comment and silently truncates the value. Flag descriptions ending in the
# characteristic dangling fragments this leaves behind ("shipped as PR", "(issue").
# Case-sensitive on purpose: "PR"/"issue" match how references are written, and
# lowercase-only articles/prepositions avoid flagging values that legitimately
# end in words like "ON" or "-A".
# Demoted from CLAUDE.md (2026-09-21, dotfiles#1286): this hit 100+ notes
# before the 2026-07 audit.
TRUNCATED_DESCRIPTION_RE = re.compile(
    r"(?:[(,;:]|\bPRs?|\bissues?|\s(?:the|an?|and|with|via|after|as|for|to|of|on|by|at))$"
)
CONTENT_SIGNATURES = (
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"\b(?:ghp|github_pat|sk_live|sk_test)_[A-Za-z0-9_\-]{16,}\b"),
    re.compile(r"(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]\s*['\"]?[A-Za-z0-9_./+\-=]{16,}"),
)

# --- Copy gate ---------------------------------------------------------------
# sync.sh's memory push asks this auditor one question: may the mirror be
# updated? The answer is per-file. A sensitive indicator excludes that one file
# from the copy and lets the rest through, which is exactly as confidential as
# refusing the whole push -- the flagged bytes reach the mirror in neither case
# -- while no longer costing every other note its backup. Blocking the run
# outright bought nothing but the operator's attention, and quarantine reporting
# buys that instead.
#
# A live symlink still blocks everything: it means the live store is no longer a
# self-contained tree, so what to copy is a confinement question about the whole
# push rather than a question about one file.
COPY_GATE_BLOCKING_KINDS = frozenset({"live_symlink"})
COPY_GATE_QUARANTINE_KINDS = frozenset(
    {
        "sensitive_content_indicator",
        "sensitive_frontmatter_indicator",
        "sensitive_filename_indicator",
    }
)

# Kinds that are real findings but must not make the audit exit non-zero.
NON_BLOCKING_KINDS = frozenset({"stale_date_review", "filename_indicator_allowlisted", "cited_enforcer_missing"})

# --- Cited-enforcer check (dotfiles#1687) -------------------------------------
# A feedback note that sends an agent to a hook, script or test which no longer
# exists is a rule with no enforcer. The 2026-10-07 vet of pstack `/correct`
# (docs/vets/2026-10-07-correct-retro-family-harness-vet.md, section 2.2) found 2
# of the 34 enforcer citations in this repo's feedback notes pointing at scripts
# that exist nowhere. Consumer: harness-doctor's memory-audit line. Scope: the
# feedback notes of the project whose memory belongs to the checkout holding this
# script (`--enforcer-repo`; a linked worktree resolves to its main checkout,
# whose project holds the notes), and within them the backticked tokens that are
# a `...` path or a script basename. It proves the cited file exists, not
# that it enforces what the note says. Delete the check once two consecutive
# monthly audits report 0.
ENFORCER_REPO_DEFAULT = Path(__file__).resolve().parents[1]
ENFORCER_SCRIPT_SUFFIXES = (".sh", ".py", ".js", ".mjs")
# Installed plugin scripts (`run-log.py`) are enforcers that live outside the
# repo; their tree is indexed alongside it. Host-only, like the live store.
ENFORCER_EXTRA_ROOTS_DEFAULT = ("~/.claude/plugins",)
# The pre-2026-10 nested layout kept the harness under this prefix; a note written
# then cites what now sits at the root. Spelled in two pieces so the layout suite's
# old-prefix scan does not read it as a live repo path.
ENFORCER_LEGACY_PREFIX = "cl" "aude/"
# Other repositories are the checkouts under these roots that have a live memory
# project of their own; their names count as repo names (below).
ENFORCER_REPO_ROOTS_DEFAULT = ("~/SITES",)
BACKTICK_RE = re.compile(r"`([^`\n]+)`")
# Angle, brace, glob and variable placeholders describe a shape, not a file.
ENFORCER_PLACEHOLDER_RE = re.compile(r"[<>{}*$]")
# Never part of the enforcer index: VCS internals, vendored packages, nested
# worktrees and the memory mirror (a note is not an enforcer).
ENFORCER_INDEX_EXCLUDED_DIRS = frozenset({".git", "node_modules", ".claude"})
ENFORCER_INDEX_EXCLUDED_PREFIXES = ("memory/",)
# A sentence about another repository is about that repository's scripts: a
# ~/SITES checkout path for a different repo, a GitHub URL whose repository is
# not this one, a plugin
# cache path, an unspaced `name#N` issue reference whose name is not this repo's
# (`hov-marketplace#72`), or a repo name next to an issue reference
# (`acme-app #1621`). A description that carries the last form skips the whole
# note. The unit is the sentence or list item (#1687), so "See acme-app#1621.
# Locally run `x.sh`." keeps its second sentence in scope; abbreviations ending
# in a period are not sentence ends. Bare repo words skip a sentence only for
# names the operator passes with `--other-repo`: the derived names include
# `oracle` and `papercut`, which ordinary harness prose uses (as bare words they
# would touch 64 of the 148 live notes checked; every scoping variant measured
# on 2026-10-08 flagged the same 2 notes).
# Capture the complete repo component, not a prefix (repo-tools is not repo).
# Both separators occur in notes even when the audit itself runs on POSIX.
SITES_REPO_PATH_RE = re.compile(r"[\\/]SITES[\\/]([^\\/\s`'\"<>{}\[\](),;:!?]+)")
GITHUB_REPO_URL_RE = re.compile(r"github\.com/([\w.-]+)/([\w.-]+)")
SENTENCE_RE = re.compile(
    r"(?<!\be\.g\.)(?<!\bi\.e\.)(?<!\bvs\.)(?<=[.!?])\s+|\n(?=[ \t]*(?:[-*+]|\d+[.)])[ \t])", re.IGNORECASE
)
# Cited lines: file.sh:105-138, file.sh#L12-L20.
LINE_ANCHOR_RE = re.compile(r"(?::\d+(?:-\d+)?|#L\d+(?:-L?\d+)?)$")
CROSS_REPO_REF_RE = re.compile(r"(?<![\w./-])([A-Za-z][\w.-]*(?:/[\w.-]+)?)#\d+\b")
NAMED_REF_RE = re.compile(r"(?<![\w./-])([A-Za-z][\w.-]*)\s?#\d+\b")

# SENSITIVE_FILENAME_RE matches a name, and a name is the weakest evidence this
# auditor has: a note *about* credential handling reads identically to a note
# *containing* one. An allowlist entry records that a path was reviewed and its
# name is not evidence. It suppresses the filename check for that exact path and
# nothing else -- body and frontmatter scanning still apply in full, so an
# allowlisted note that later gains a real secret is still caught and still
# quarantined. Entries are "<project>/<relative>", one per line, '#' comments ok.
# The tracked file ships no entries: a reviewed path names a project under one
# operator's home, so the live list is an overlay copy that
# filename_allowlist_path() prefers when it exists (the same overlay directory
# scripts/repo-route.py and the public-safety scan read; restructure plan U16).
DEFAULT_FILENAME_ALLOWLIST = Path(__file__).resolve().parent.parent / "memory-filename-allowlist.txt"


def filename_allowlist_path() -> Path:
    """<overlay>/memory-filename-allowlist.txt when it is a file, else the tracked default.

    The overlay directory is HOV_STACK_OVERLAY, else $XDG_CONFIG_HOME/hov-stack or
    ~/.config/hov-stack. --filename-allowlist overrides both.
    """
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    overlay = Path(os.environ.get("HOV_STACK_OVERLAY") or Path(base) / "hov-stack")
    candidate = overlay / "memory-filename-allowlist.txt"
    return candidate if candidate.is_file() else DEFAULT_FILENAME_ALLOWLIST

# With no --mirror-root and no CLAUDE_MEMORY_MIRROR_ROOT, the mirror is the
# memory tree of the branch backup-harness.sh pushes, read from this
# checkout's remote-tracking ref (dotfiles#1918). A directory can be filled by a
# scratch memory-push with nothing durable behind it; this ref moves only on a
# fetch or a push. CLAUDE_MEMORY_BACKUP_REPO names another checkout to read it from.
PUSHED_MIRROR_REF = "refs/remotes/origin/backup/claude-memory"
PUSHED_MIRROR_HINT = (
    f"checked against {PUSHED_MIRROR_REF}; run `systemctl --user start backup-harness.service` "
    "to push live memory, then retry"
)
_pushed_mirror: tempfile.TemporaryDirectory[str] | None = None


def pushed_mirror_root() -> Path:
    """Extract PUSHED_MIRROR_REF:memory into a temporary directory, once per
    process. On any failure the directory stays empty, so every freshness check
    reports mirror_missing_project and refuses."""
    global _pushed_mirror
    if _pushed_mirror is None:
        _pushed_mirror = tempfile.TemporaryDirectory(prefix="memory-pushed-mirror.")
        repo = Path(os.environ.get("CLAUDE_MEMORY_BACKUP_REPO") or Path(__file__).resolve().parents[1])
        try:
            archive = subprocess.run(
                ["git", "-C", str(repo), "archive", "--format=tar", f"{PUSHED_MIRROR_REF}:memory"],
                capture_output=True,
                check=False,
            )
        except OSError as error:
            print(f"memory-audit: cannot read {PUSHED_MIRROR_REF} in {repo}: {error}", file=sys.stderr)
        else:
            if archive.returncode == 0:
                with tarfile.open(fileobj=io.BytesIO(archive.stdout), mode="r:") as bundle:
                    bundle.extractall(_pushed_mirror.name, filter="tar")
            else:
                reason = archive.stderr.decode("utf-8", errors="replace").strip()
                print(f"memory-audit: cannot read {PUSHED_MIRROR_REF} in {repo}: {reason}", file=sys.stderr)
    return Path(_pushed_mirror.name)


def mirror_root_path(value: str | None) -> Path:
    return pushed_mirror_root() if value is None else Path(value).expanduser()


def mirror_root_label(value: str | None) -> str:
    return PUSHED_MIRROR_REF if value is None else str(Path(value).expanduser())


def load_filename_allowlist(path: Path) -> set[str]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return set()
    entries = set()
    for line in raw.splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            entries.add(entry)
    return entries


def copy_gate(result: dict[str, Any]) -> dict[str, Any]:
    blocked = [item for item in result["findings"] if item["kind"] in COPY_GATE_BLOCKING_KINDS]
    quarantined = [item for item in result["findings"] if item["kind"] in COPY_GATE_QUARANTINE_KINDS]
    return {
        "schema_version": 1,
        "blocked": blocked,
        # Deduplicated: one path can trip more than one indicator, and rsync
        # wants each exclusion once.
        "quarantine_paths": sorted({f"{item['project']}/{item['path']}" for item in quarantined}),
        "quarantined": quarantined,
    }

# --- Dream-pass triage (stage one) -------------------------------------------
# Additive scoring over structural signals only. Live memory is not a git
# repository, so the operative age signal is live-file mtime (KTD3); mirror git
# corroboration is advisory and not wired in v1. All thresholds live in this one
# constants block. Supersession markers are case-sensitive line-leading tokens,
# so "SUPERSEDED"/"CORRECTED"/"RESOLVED"/"RETRACTED" status lines count while
# prose mentions ("resolved the bug") do not. This is the only supersession check
# since harness-doctor's section 16, which also counted RETRACTED, was retired.
SUPERSESSION_RE = re.compile(r"(?m)^[\s>*_+-]*(?:SUPERSEDED|CORRECTED|RESOLVED|RETRACTED)\b")
# A note is flagged only on STRUCTURAL rot: at least one supersession marker, or a
# body past the log-shaped size threshold. Age and zero-inbound are ranking boosts
# only, never independent flag triggers, so a merely-old orphan note (the bulk of a
# mature store) does not manufacture a consolidation proposal. Size thresholds are
# calibrated to the live store (p50~2.5KB, p90~7.3KB): 6KB isolates the long-tail
# running logs, 10KB the clearly oversized ones.
TRIAGE_SUPERSESSION_FLAG = 1
TRIAGE_BODY_BYTES = 6000
TRIAGE_BODY_BYTES_LARGE = 10000
TRIAGE_AGE_DAYS = 90
TRIAGE_AGE_DAYS_OLD = 180
# Per-pass fan-out caps (KTD6): the assembler reads these so a single pass never
# balloons the drafting fleet; overflow is reported and deferred. Defined here
# beside the thresholds as the single shared constants block.
TRIAGE_MAX_CLUSTERS = 12
TRIAGE_MAX_NOTES_PER_CLUSTER = 8
# Recall is 100% agentic and routed by the one-line description (no vector index),
# so a vague or duplicated description makes its note unrecallable. A description
# under this many words, or one another note in the same project duplicates
# verbatim, flags the note for a redescribe proposal.
TRIAGE_DESC_MIN_WORDS = 5
# Claude Code loads MEMORY.md into every session but hard-truncates at the first
# 200 lines / 25KB (frontmatter and block HTML comments stripped before counting,
# v2.1.211 accounting); content past the cap is silently invisible. Warn at the
# 70% mark, matching Claude Code's own over-limit rewrite target.
INDEX_LOAD_MAX_LINES = 200
INDEX_LOAD_MAX_BYTES = 25 * 1024
INDEX_BUDGET_FRACTION = 0.7


def digest(path: Path) -> str:
    if path.is_symlink():
        value = b"symlink\0" + os.fsencode(os.readlink(path))
    else:
        value = path.read_bytes()
    return hashlib.sha256(value).hexdigest()


def project_dirs(root: Path, live: bool) -> dict[str, Path]:
    if not root.is_dir():
        return {}
    if live:
        return {
            parent.name: memory
            for parent in sorted(root.iterdir(), key=lambda item: item.name)
            if parent.is_dir() and (memory := parent / "memory").is_dir()
        }
    return {item.name: item for item in sorted(root.iterdir(), key=lambda item: item.name) if item.is_dir()}


def files(directory: Path, markdown_only: bool = False) -> dict[str, Path]:
    pattern = "*.md" if markdown_only else "*"
    return {
        path.relative_to(directory).as_posix(): path
        for path in sorted(directory.rglob(pattern), key=lambda item: item.as_posix())
        if path.is_file() or path.is_symlink()
    }


# memory-mine.py runtime state that sync.sh never mirrors (MEMORY_MINER_DROPPINGS
# in sync.sh, the one list both memory_plan and memory_push read; a
# test pins this copy to it). Live-only by design, so neither the coverage
# audit nor the mirror-freshness gate may count one as a missing mirror file:
# with them counted, `fix --apply` and `rehook --apply` could never pass on a
# project the miner had touched (#1450). Glob syntax, matched on the basename.
MINER_DROPPINGS = (".mine-apply.lock", ".mined-sessions.json", ".MEMORY.md.pre-mine-*")


def is_miner_dropping(rel: str) -> bool:
    base = rel.rsplit("/", 1)[-1]
    return any(fnmatch.fnmatchcase(base, pattern) for pattern in MINER_DROPPINGS)


def scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    return value.strip()


def parse_frontmatter(text: str) -> tuple[dict[str, Any] | None, str | None, str, dict[str, str]]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, "missing YAML frontmatter", text, {}
    try:
        end = next(index for index in range(1, len(lines)) if lines[index].strip() == "---")
    except StopIteration:
        return None, "unterminated YAML frontmatter", text, {}
    data: dict[str, Any] = {}
    metadata: dict[str, str] = {}
    raw: dict[str, str] = {}
    in_metadata = False
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^(?P<indent>\s*)(?P<key>[A-Za-z0-9_.-]+)\s*:\s*(?P<value>.*)$", line)
        if not match:
            continue
        indent, key, value = match.group("indent"), match.group("key"), match.group("value")
        if not indent:
            in_metadata = key == "metadata"
            if in_metadata:
                data["metadata"] = metadata
            else:
                data[key] = scalar(value)
                raw[key] = value.strip()
        elif in_metadata:
            metadata[key] = scalar(value)
    return data, None, "\n".join(lines[end + 1 :]), raw


def index_targets(text: str) -> tuple[set[str], set[str]]:
    targets: set[str] = set()
    escaping: set[str] = set()
    for match in LINK_RE.finditer(text):
        target = match.group("target")
        if target.startswith("<") and target.endswith(">"):
            target = target[1:-1]
        target = re.sub(r"\\([()\\])", r"\1", target)
        target = unquote(target.split("#", 1)[0])
        if target.startswith("./"):
            target = target[2:]
        path = Path(target)
        if not target.lower().endswith(".md"):
            continue
        if path.is_absolute() or ".." in path.parts:
            escaping.add(target)
        else:
            targets.add(path.as_posix())
    return targets, escaping


def archive_tier_targets(memory_dir: Path) -> set[str]:
    """Notes pointed to from an archive tier below MEMORY.md's load cut: the
    rehook tier (ARCHIVE_INDEX_NAME, dotfiles#1459) or the legacy
    MEMORY-archive.md (memory-dream's archive demotion). A note listed there is
    indexed on purpose, so neither the audit nor fix may treat it as orphaned.
    A symlinked tier is skipped, as rehook skips it."""
    targets: set[str] = set()
    for name in (ARCHIVE_INDEX_NAME, "MEMORY-archive.md"):
        path = memory_dir / name
        if path.is_file() and not path.is_symlink():
            targets |= index_targets(path.read_text(encoding="utf-8", errors="replace"))[0]
    return targets - {"MEMORY.md", "MEMORY-archive.md", ARCHIVE_INDEX_NAME}


def canon(value: str) -> str:
    value = value.strip().lower()
    if value.endswith(".md"):
        value = value[:-3]
    value = value.replace("-", "_")
    value = re.sub(r"[^a-z0-9_]+", "_", value)
    return re.sub(r"_+", "_", value).strip("_")


def finding(kind: str, project: str, path: str | None = None, **details: Any) -> dict[str, Any]:
    result: dict[str, Any] = {"kind": kind, "project": project}
    if path is not None:
        result["path"] = path
    result.update(details)
    return result


def project_key(path: Path) -> str:
    """Claude Code's project directory name for a checkout: every '/', '.' and
    '_' of the absolute path becomes '-' (/home/u/dotfiles -> -home-u-dotfiles;
    /home/u/SITES/a_b -> -home-u-SITES-a-b, observed live 2026-10-08). Other
    punctuation is left alone: the only live keys with a kept '+' or '.' were
    written in April 2026 by an earlier client and hold no memory."""
    return re.sub(r"[/._]", "-", str(path))


def enforcer_index(roots: tuple[Path, ...], errors: list[str]) -> set[str]:
    """Basenames of every regular file under the roots, outside the excluded
    directories. A dangling symlink is not an enforcer. A directory the walk
    cannot read, or a root the auditor cannot probe, is recorded in `errors`,
    not fatal. An entry the walk lists but cannot stat (its directory lists
    without being searchable) stays citable and is recorded too: a path the
    auditor cannot see is never reported as a phantom, and the check never
    reads as complete over it."""
    names: set[str] = set()
    for repo in roots:
        if not usable_root(repo, errors):
            continue
        for root, dirs, filenames in os.walk(repo, onerror=lambda error: errors.append(f"{error.filename}: {error.strerror}")):
            rel = Path(root).relative_to(repo).as_posix()
            if rel != "." and any((rel + "/").startswith(prefix) for prefix in ENFORCER_INDEX_EXCLUDED_PREFIXES):
                dirs[:] = []
                continue
            dirs[:] = sorted(name for name in dirs if name not in ENFORCER_INDEX_EXCLUDED_DIRS)
            names.update(name for name in filenames if path_kind(Path(root) / name, errors) in ("file", "unknown"))
    return names


def other_repo_names(repo: Path, roots: tuple[Path, ...], live_projects: set[str], errors: list[str]) -> tuple[str, ...]:
    """Checkouts under the roots that have a live memory project, except the
    audited repo. A root that cannot be listed, or a child the auditor cannot
    probe (the root lists without being searchable), is recorded in `errors`,
    not fatal: this is an advisory guard against cross-repo false positives,
    never a reason to end the audit without a verdict."""
    names: set[str] = set()
    for root in roots:
        if not usable_root(root, errors):
            continue
        try:
            for child in root.iterdir():
                if path_kind(child, errors) == "dir" and child != repo and project_key(child) in live_projects:
                    names.add(child.name)
        except OSError as error:
            errors.append(f"{root}: {error.strerror or error}")
    return tuple(sorted(names))


def path_kind(path: Path, errors: list[str]) -> str | None:
    """'file', 'dir' or 'other' for what a cited path resolves to (symlinks
    followed), None when nothing is there, and 'unknown' when the probe itself
    failed; that failure is recorded, and a path the auditor cannot stat is
    never reported as a phantom. Path.exists() raises on EACCES under 3.12 and
    returns False under 3.13, so every existence probe goes through here. A NUL
    inside the path makes stat raise ValueError rather than OSError (note bodies
    are agent-written text); that is a probe failure like any other."""
    try:
        mode = path.stat().st_mode
    except (FileNotFoundError, NotADirectoryError):
        return None
    except (OSError, ValueError) as error:
        errors.append(f"{path}: {getattr(error, 'strerror', None) or error}")
        return "unknown"
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "dir"
    return "other"


def usable_root(path: Path, errors: list[str]) -> bool:
    """Whether a discovery root can be walked. A root that is simply absent is
    skipped in silence (a CI host has no ~/SITES or ~/.claude/plugins); one that
    exists but is not a directory is an operator misconfiguration, and one the
    auditor cannot probe is a failure: both are recorded so the check never
    reads as complete."""
    kind = path_kind(path, errors)
    if kind == "dir":
        return True
    if kind not in (None, "unknown"):
        errors.append(f"{path}: not a directory")
    return False


def enforcer_token(span: str) -> str | None:
    """The repo path or script a backticked span cites, normalised, else None."""
    if "\x00" in span:
        return None  # not a path; stat() would raise ValueError on it
    words = span.strip().split()
    if not words:
        return None
    word = words[0].rsplit("=", 1)[-1]  # ExecStopPost=unit.sh, KEY=script.sh
    word = re.sub(r"::.*$", "", word)  # pytest ids: file.py::case
    word = word.rstrip(",.;:)")
    word = LINE_ANCHOR_RE.sub("", word)
    if word.startswith("./"):
        word = word[2:]
    if not word or "://" in word or ENFORCER_PLACEHOLDER_RE.search(word):
        return None
    if word.startswith("~/.claude/") or "/" in word:
        # A path. The caller resolves it against the repo (whose root the
        # installed tree mirrors) and drops one whose first segment is no repo
        # directory: another repository's layout (ops/arc/bin/x.py).
        return word
    if word.endswith(ENFORCER_SCRIPT_SUFFIXES):
        return word
    return None


def names_other_repo_ref(text: str, repo_name: str, repo_names: tuple[str, ...]) -> bool:
    """`acme-app #1621` or `hov-marketplace#72`: an issue reference qualified by a
    repository name other than the audited repo's."""
    for match in CROSS_REPO_REF_RE.finditer(text):
        if match.group(1).rsplit("/", 1)[-1].lower() != repo_name.lower():
            return True
    lowered = {name.lower() for name in repo_names} - {repo_name.lower()}
    return any(match.group(1).lower() in lowered for match in NAMED_REF_RE.finditer(text))


def text_names_other_repo(
    text: str,
    repo_name: str,
    repo_names: tuple[str, ...],
    other_repos: tuple[str, ...],
    repo_aliases: tuple[str, ...] = (),
) -> bool:
    """Whether a sentence or list item is about another repository (see the
    constants block): a path signal, a GitHub URL for a different repository, an
    issue reference qualified by another repo's name, or an `--other-repo` word."""
    if "plugins/" in text:
        return True
    own_names = {name.lower() for name in (repo_name,) + repo_aliases}
    for match in SITES_REPO_PATH_RE.finditer(text):
        # A prose sentence's full stop is not part of its checkout name.
        name = match.group(1).rstrip(".")
        if name and name.lower() not in own_names:
            return True
    for match in GITHUB_REPO_URL_RE.finditer(text):
        if match.group(2).removesuffix(".git").lower() != repo_name.lower():
            return True
    if names_other_repo_ref(text, repo_name, repo_names + other_repos):
        return True
    return any(re.search(rf"(?i)(?<![\w-]){re.escape(word)}(?![\w-])", text) for word in other_repos)


def missing_enforcer_citations(
    body: str,
    repo: Path,
    index: set[str],
    repo_names: tuple[str, ...],
    other_repos: tuple[str, ...],
    errors: list[str],
    repo_aliases: tuple[str, ...] = (),
) -> tuple[list[str], bool]:
    """Cited `...` paths and script basenames that resolve to nothing: neither
    the exact path (a regular file, or a directory for a token without a script
    suffix) nor any indexed regular file with that basename exists. The flag says
    whether a sentence was skipped for naming another repository."""
    missing: list[str] = []
    skipped = False
    for paragraph in re.split(r"\n\s*\n", body):
        for unit in SENTENCE_RE.split(paragraph):
            if not unit.strip():
                continue
            if text_names_other_repo(unit, repo.name, repo_names, other_repos, repo_aliases):
                skipped = True
                continue
            for match in BACKTICK_RE.finditer(unit):
                token = enforcer_token(match.group(1))
                if token is None or token in missing:
                    continue
                rel = token
                resolve = "/" in token
                if token.startswith("~/.claude/"):
                    # The installed tree mirrors the repo's <dir> for the dirs sync.sh
                    # installs; anything else under ~/.claude is runtime state.
                    rel = token[len("~/.claude/") :]
                    top = rel.split("/")[0]
                    if not top or path_kind(repo / top, errors) not in ("dir", "unknown"):
                        continue
                elif resolve:
                    if rel.startswith(ENFORCER_LEGACY_PREFIX) and path_kind(
                        repo / ENFORCER_LEGACY_PREFIX.rstrip("/"), errors
                    ) != "dir":
                        rel = rel[len(ENFORCER_LEGACY_PREFIX) :]
                    # A repo-relative path only when its first segment is a repo
                    # directory; otherwise it is another repository's layout
                    # (ops/arc/bin/x.py), not a citation of ours. Since the flatten the
                    # root holds generic names (bin, scripts, lib), so another repo's
                    # bin/x.sh is reported too, never blocking, unless its sentence
                    # names that repository.
                    if not rel or path_kind(repo / rel.split("/")[0], errors) != "dir":
                        continue
                if resolve:
                    kind = path_kind(repo / rel.rstrip("/"), errors)
                    if kind in ("file", "unknown") or (
                        kind == "dir" and not rel.rstrip("/").endswith(ENFORCER_SCRIPT_SUFFIXES)
                    ):
                        continue
                if Path(rel.rstrip("/")).name in index:
                    continue
                missing.append(token)
    return missing, skipped


def audit(args: argparse.Namespace) -> dict[str, Any]:
    live_root = Path(args.live_root).expanduser()
    mirror_root = mirror_root_path(args.mirror_root)
    filename_allowlist = load_filename_allowlist(
        Path(getattr(args, "filename_allowlist", None) or filename_allowlist_path()).expanduser()
    )
    if not live_root.is_dir():
        raise OSError(f"live root is not a directory: {live_root}")
    live = project_dirs(live_root, live=True)
    mirror = project_dirs(mirror_root, live=False)
    findings: list[dict[str, Any]] = []
    # The cited-enforcer check is advisory. sync.sh's --copy-gate decides
    # confinement and sensitive data only, so in that mode none of it runs: at
    # 43575a48 the sibling-repo discovery still walked ~/SITES in gate mode, and
    # one unreadable optional root made the nightly push exit 2 without a verdict
    # (#1699 comment 6070518687). Outside the gate a discovery failure is recorded
    # in the scope block and the audit continues.
    enforcer_enabled = not getattr(args, "copy_gate", False)
    discovery_errors: list[str] = []
    enforcer_repo_requested = Path(getattr(args, "enforcer_repo", None) or ENFORCER_REPO_DEFAULT).expanduser()
    enforcer_repo = main_checkout(enforcer_repo_requested, discovery_errors) if enforcer_enabled else enforcer_repo_requested
    enforcer_project = project_key(enforcer_repo)
    # One probe, shared by the per-note guard and the scope block. Path.is_dir()
    # raises on EACCES under 3.12; a repo the auditor cannot see is reported as
    # unavailable in the scope block rather than ending the audit without a verdict.
    enforcer_repo_exists = enforcer_enabled and path_kind(enforcer_repo, discovery_errors) == "dir"
    other_repos = tuple(getattr(args, "other_repo", None) or ())
    enforcer_extra_roots = tuple(
        Path(root).expanduser() for root in (getattr(args, "enforcer_extra_root", None) or ENFORCER_EXTRA_ROOTS_DEFAULT)
    )
    enforcer_repo_roots = tuple(
        Path(root).expanduser() for root in (getattr(args, "repo_root", None) or ENFORCER_REPO_ROOTS_DEFAULT)
    )
    repo_names: tuple[str, ...] = ()
    if enforcer_enabled:
        repo_names = other_repo_names(enforcer_repo, enforcer_repo_roots, set(live), discovery_errors)
    enforcer_names: set[str] | None = None  # built on the first feedback note in scope
    enforcer_notes_checked = 0
    enforcer_notes_other_repo = 0  # skipped whole or in part for naming another repo

    for project in sorted(set(live) | set(mirror)):
        if project not in live:
            findings.append(finding("mirror_only_project", project))
            continue
        if project not in mirror:
            findings.append(finding("mirror_missing_project", project))
        memory_dir = live[project]
        if memory_dir.is_symlink() or memory_dir.parent.is_symlink():
            # A symlinked project or memory root would make rsync copy an
            # arbitrary external tree; block and skip traversal entirely.
            findings.append(finding("live_symlink", project, "" if memory_dir.parent.is_symlink() else "memory"))
            continue
        live_all_files = files(memory_dir)
        mirror_all_files = files(mirror[project]) if project in mirror else {}
        for relative, path in sorted(live_all_files.items()):
            if path.is_symlink():
                findings.append(finding("live_symlink", project, relative))
                continue
            # Everything here gets copied by memory-push, so the sensitive scan
            # covers every file: MEMORY.md, frontmatter, and attachments.
            filename = Path(relative).name
            if WHATSAPP_STORE_FILENAME_RE.search(filename):
                # This is account/data authority, never a prose false positive;
                # unlike the generic filename heuristic it is not allowlistable.
                findings.append(finding("sensitive_filename_indicator", project, relative))
                # A mistaken database can be gigabytes. Filename evidence is
                # conclusive here; never decode the raw SQLite payload as text.
                continue
            elif SENSITIVE_FILENAME_RE.search(filename):
                if f"{project}/{relative}" in filename_allowlist:
                    findings.append(finding("filename_indicator_allowlisted", project, relative))
                else:
                    findings.append(finding("sensitive_filename_indicator", project, relative))
            if args.scan_content:
                try:
                    raw_text = path.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    findings.append(finding("unreadable_file", project, relative))
                    continue
                if any(pattern.search(raw_text) for pattern in CONTENT_SIGNATURES):
                    findings.append(finding("sensitive_content_indicator", project, relative))
        live_files = files(memory_dir, markdown_only=True)
        index = live_files.get("MEMORY.md")
        if index is None or index.is_symlink():
            if index is None:
                findings.append(finding("missing_memory_index", project, "MEMORY.md"))
            targets: set[str] = set()
            escaping_targets: set[str] = set()
        else:
            index_text = index.read_text(encoding="utf-8", errors="replace")
            targets, escaping_targets = index_targets(index_text)
            for target in sorted(escaping_targets):
                findings.append(finding("escaping_index_target", project, target))
            # The note loop skips memory-dream's tier by name and exempts what it
            # lists, so a MEMORY.md that never mentions it would hide the tier and
            # all its notes. memory-dream's pointer is a plain-text line, not a link:
            # rehook ranks a bullet link to it as a dead entry and evicts it first.
            dream_tier = live_files.get("MEMORY-archive.md")
            if dream_tier is not None and not dream_tier.is_symlink() and "MEMORY-archive.md" not in index_text:
                findings.append(finding("unindexed_markdown", project, "MEMORY-archive.md"))
            size = index.stat().st_size
            lines = len(index_text.splitlines())
            if size > args.max_index_bytes or lines > args.max_index_lines:
                findings.append(
                    finding(
                        "oversized_memory_index",
                        project,
                        "MEMORY.md",
                        bytes=size,
                        lines=lines,
                        max_bytes=args.max_index_bytes,
                        max_lines=args.max_index_lines,
                    )
                )
        # Advisory like the enforcer above: the exemption only removes
        # unindexed_markdown findings, which the copy gate ignores, so gate mode
        # reads no tier. Elsewhere an unreadable tier only loses the exemption;
        # the content scan already records MEMORY-archive.md as unreadable_file.
        archived: set[str] = set()
        if not getattr(args, "copy_gate", False):
            try:
                archived = archive_tier_targets(memory_dir)
            except OSError:
                pass
        note_names: dict[str, list[str]] = {}
        note_stems: set[str] = set()
        note_bodies: dict[str, str] = {}
        for relative, path in sorted(live_files.items()):
            if relative in ("MEMORY.md", "MEMORY-archive.md"):
                continue
            if path.is_symlink():
                continue
            note_stems.add(Path(relative).name[:-3])
            if relative not in targets and relative not in archived:
                findings.append(finding("unindexed_markdown", project, relative))
            text = path.read_text(encoding="utf-8", errors="replace")
            metadata, parse_error, body, raw_values = parse_frontmatter(text)
            note_bodies[relative] = body
            problems: list[str] = []
            if parse_error:
                problems.append(parse_error)
            else:
                assert metadata is not None
                for key in ("name", "description"):
                    value = metadata.get(key)
                    if not isinstance(value, str) or not value.strip():
                        problems.append(f"missing or empty {key}")
                    elif raw_values.get(key, "").strip().lower() in YAML_LITERALS:
                        # An unquoted null/true/false is a YAML non-string, not a name.
                        problems.append(f"{key} is a YAML literal, not a string")
                description = metadata.get("description")
                raw_description = raw_values.get("description", "")
                # The truncation is YAML's: '#' cannot open a comment inside a closed
                # quote pair, so a quoted value ends where its writer ended it.
                quoted = len(raw_description) >= 2 and raw_description[0] in "\"'" and raw_description[-1] == raw_description[0]
                if isinstance(description, str) and description.strip() and not quoted:
                    tail = description.strip()
                    # Unbalanced open-paren: the same unquoted-# YAML truncation bug,
                    # cut mid-parenthetical so no tracked trailing token remains.
                    if (
                        TRUNCATED_DESCRIPTION_RE.search(tail)
                        or re.fullmatch(r"20\d{2}-\d{2}-\d{2}", tail)
                        or tail.count("(") > tail.count(")")
                    ):
                        findings.append(finding("truncated_description", project, relative))
                nested = metadata.get("metadata")
                nested_type = nested.get("type") if isinstance(nested, dict) else None
                note_type = nested_type or metadata.get("type")
                if note_type not in ALLOWED_TYPES:
                    problems.append("type or metadata.type must be user|feedback|project|reference")
                if enforcer_repo_exists and project == enforcer_project and note_type == "feedback":
                    if names_other_repo_ref(str(description or ""), enforcer_repo.name, repo_names + other_repos):
                        enforcer_notes_other_repo += 1  # the note is about another repo's PR or issue
                    else:
                        enforcer_notes_checked += 1
                        if enforcer_names is None:
                            enforcer_names = enforcer_index((enforcer_repo,) + enforcer_extra_roots, discovery_errors)
                        missing, skipped = missing_enforcer_citations(
                            body, enforcer_repo, enforcer_names, repo_names, other_repos, discovery_errors,
                            # main_checkout owns the notes; either checkout name
                            # still identifies this repo in a SITES path.
                            (enforcer_repo_requested.name,),
                        )
                        enforcer_notes_other_repo += int(skipped)
                        for token in missing:
                            findings.append(finding("cited_enforcer_missing", project, relative, token=token))
                # Decay enforcement (2026-07-31 face-off follow-up, issue #142): notes
                # carrying the mined-note fields lose confidence with a 90-day half-life
                # since last_validated (cm's one good idea, applied to the stock store).
                # Effective confidence < 0.3 => dream-pass candidate: revalidate or archive.
                if isinstance(nested, dict) and "confidence" in nested and "last_validated" in nested:
                    decay = decay_effective(nested, dt.date.today())
                    if decay is None:
                        problems.append("confidence/last_validated present but unparseable")
                    else:
                        effective, age_days = decay
                        if effective < 0.3:
                            findings.append(
                                finding(
                                    "decayed_confidence",
                                    project,
                                    relative,
                                    confidence=float(nested["confidence"]),
                                    age_days=age_days,
                                    effective=round(effective, 3),
                                )
                            )
                name = metadata.get("name")
                if isinstance(name, str) and name.strip():
                    note_names.setdefault(name.strip(), []).append(relative)
                sensitive_keys = sorted(
                    key
                    for key in metadata
                    if SENSITIVE_KEY_RE.search(key)
                )
                if isinstance(nested, dict):
                    sensitive_keys.extend(f"metadata.{key}" for key in nested if SENSITIVE_KEY_RE.search(key))
                if sensitive_keys:
                    findings.append(
                        finding("sensitive_frontmatter_indicator", project, relative, indicators=sorted(set(sensitive_keys)))
                    )
            if problems:
                findings.append(finding("invalid_frontmatter", project, relative, problems=sorted(problems)))
            if args.as_of:
                dates: set[dt.date] = set()
                # Patterns require an explicit status/checkpoint label, so scanning
                # frontmatter and body remains high-confidence without broad date noise.
                for pattern in DATE_PATTERNS:
                    for value in pattern.findall(text):
                        try:
                            dates.add(dt.date.fromisoformat(value))
                        except ValueError:
                            pass
                stale_dates = sorted(value for value in dates if (args.as_of - value).days > args.stale_days)
                if stale_dates:
                    findings.append(
                        finding(
                            "stale_date_review",
                            project,
                            relative,
                            dates=[value.isoformat() for value in stale_dates],
                            stale_days=args.stale_days,
                        )
                    )
        for name, paths in sorted(note_names.items()):
            if len(paths) > 1:
                findings.append(finding("duplicate_frontmatter_name", project, paths=sorted(paths), count=len(paths)))
        for target in sorted(targets - set(live_files)):
            findings.append(finding("missing_index_target", project, target))

        # Body [[wikilinks]] that resolve to exactly one existing note under a
        # different slug are typos worth fixing; links with no close match are
        # doctrine-allowed forward references and stay silent.
        raw_names = {name for name in note_names}
        by_canon: dict[str, set[str]] = {}
        for stem in note_stems:
            by_canon.setdefault(canon(stem), set()).add(stem)
            for prefix in ("feedback_", "project_", "reference_"):
                if stem.startswith(prefix):
                    by_canon.setdefault(canon(stem[len(prefix):]), set()).add(stem)
        for name in raw_names:
            by_canon.setdefault(canon(name), set()).add(name)
        for relative, body in sorted(note_bodies.items()):
            for match in WIKILINK_RE.finditer(body):
                link = match.group(1)
                if link in note_stems or link in raw_names:
                    continue
                candidates = by_canon.get(canon(re.sub(r"\s+", "", link) if "\n" in link else link), set())
                if len(candidates) == 1 and next(iter(candidates)) != link:
                    findings.append(
                        finding("wikilink_typo", project, relative, link=link, resolves_to=next(iter(candidates)))
                    )

        if project in mirror:
            for relative in sorted(set(live_all_files) | set(mirror_all_files)):
                if is_miner_dropping(relative):
                    continue  # never mirrored by design (sync.sh MEMORY_MINER_DROPPINGS)
                if relative not in live_all_files:
                    findings.append(finding("mirror_only_file", project, relative))
                elif relative not in mirror_all_files:
                    findings.append(finding("mirror_missing_file", project, relative))
                elif digest(live_all_files[relative]) != digest(mirror_all_files[relative]):
                    findings.append(finding("mirror_stale_file", project, relative))

    findings.sort(key=lambda item: json.dumps(item, sort_keys=True, separators=(",", ":")))
    counts = dict(sorted(Counter(item["kind"] for item in findings).items()))
    blocking = sum(count for kind, count in counts.items() if kind not in NON_BLOCKING_KINDS)
    # The states in which the check cannot stand for the store, named once here
    # so every consumer (harness-doctor, the human render) reads the same list
    # instead of re-deriving the conditions: at 28067804 the doctor did, and a
    # missing repo rendered as a clean line.
    enforcer_warnings: list[str] = []
    if enforcer_enabled:
        if not enforcer_repo_exists:
            enforcer_warnings.append(f"cited-enforcer repo unavailable ({enforcer_repo})")
        elif not enforcer_notes_checked:
            enforcer_warnings.append(f"cited-enforcer check covered 0 feedback notes (project {enforcer_project})")
        if discovery_errors:
            enforcer_warnings.append(f"cited-enforcer discovery degraded ({len(discovery_errors)} error(s))")
    result: dict[str, Any] = {
        "schema_version": 1,
        "roots": {"live": str(live_root), "mirror": mirror_root_label(args.mirror_root)},
        "summary": {
            "live_projects": len(live),
            "mirror_projects": len(mirror),
            "findings": len(findings),
            "blocking_findings": blocking,
            "review_candidates": counts.get("stale_date_review", 0),
            "cited_enforcer_missing": counts.get("cited_enforcer_missing", 0),
            "cited_enforcer_scope": {
                "project": enforcer_project,
                "repo": str(enforcer_repo),
                "repo_requested": str(enforcer_repo_requested),
                "repo_exists": enforcer_repo_exists,
                "notes_checked": enforcer_notes_checked,
                "notes_other_repo": enforcer_notes_other_repo,
                "repo_names": list(repo_names),
                "discovery_errors": discovery_errors,
                "warnings": enforcer_warnings,
            }
            if enforcer_enabled
            else {"skipped": "copy-gate"},
            "by_kind": counts,
        },
        "findings": findings,
    }
    if args.as_of:
        result["as_of"] = args.as_of.isoformat()
    return result


def main_checkout(repo: Path, errors: list[str] | None = None) -> Path:
    """The checkout whose Claude Code project owns `repo`'s feedback notes.

    A linked git worktree's `.git` is a one-line pointer file,
    `gitdir: <main>/.git/worktrees/<name>`, and the worktree's own project key
    has no memory of its own, so an audit run from a worktree would check 0
    notes and read as a clean store (seen live 2026-10-08). Resolve the pointer
    to the main checkout; a `.git` directory, no `.git`, or any other pointer
    shape is returned unchanged, and so is a `.git` the auditor cannot probe or
    read, with that failure recorded in `errors`."""
    dot_git = repo / ".git"
    probe_errors: list[str] = [] if errors is None else errors
    if path_kind(dot_git, probe_errors) != "file":
        return repo
    try:
        text = dot_git.read_text(encoding="utf-8", errors="replace").strip()
    except OSError as error:
        probe_errors.append(f"{dot_git}: {error.strerror or error}")
        return repo
    if not text.startswith("gitdir:"):
        return repo
    gitdir = Path(text[len("gitdir:"):].strip())
    if not gitdir.is_absolute():
        gitdir = repo / gitdir
    parts = Path(os.path.normpath(gitdir)).parts
    if len(parts) < 4 or parts[-3] != ".git" or parts[-2] != "worktrees":
        return repo
    return Path(*parts[:-3])


def render_human(result: dict[str, Any]) -> str:
    summary = result["summary"]
    lines = [
        "memory-audit: "
        f"{summary['live_projects']} live, {summary['mirror_projects']} mirrored, "
        f"{summary['blocking_findings']} actionable, {summary['review_candidates']} review candidate(s)"
    ]
    for kind, count in summary["by_kind"].items():
        lines.append(f"  {kind}: {count}")
    # The denominator travels with the result: a run that checked 0 notes must
    # not read like a clean store.
    scope = summary.get("cited_enforcer_scope")
    if scope and "notes_checked" in scope:
        lines.append(
            f"  cited_enforcer_scope: {scope['notes_checked']} feedback note(s) checked, "
            f"{scope['notes_other_repo']} skipped as other-repo, project {scope['project']}"
        )
        errors = scope.get("discovery_errors") or []
        if errors:
            # A root the check could not read weakens its other-repo guard; say so
            # next to the denominator rather than letting the run read as complete.
            lines.append(f"  cited_enforcer_discovery_errors: {len(errors)} ({'; '.join(errors)})")
        warnings = scope.get("warnings") or []
        if warnings:
            lines.append(f"  cited_enforcer_warnings: {len(warnings)} ({'; '.join(warnings)})")
    return "\n".join(lines)


# --- Shared dream-pass helpers -----------------------------------------------


def decay_effective(nested: Any, today: dt.date) -> tuple[float, int] | None:
    """(effective_confidence, age_days) for a note's confidence/last_validated
    decay pair (0.5 half-life, 90-day period), or None when the pair is missing
    OR present but unparseable. The single shared computation for both audit()
    and triage_project() so the 0.5/90.0 formula can never drift apart between
    call sites; each call site applies its own 0.3 flag threshold and, for
    audit(), its own presence check to distinguish "absent" (no problem) from
    "present but unparseable" (an invalid_frontmatter problem)."""
    if not (isinstance(nested, dict) and "confidence" in nested and "last_validated" in nested):
        return None
    try:
        conf = float(nested["confidence"])
        validated = dt.date.fromisoformat(str(nested["last_validated"]).strip())
    except (TypeError, ValueError):
        return None
    age_days = (today - validated).days
    effective = conf * (0.5 ** (max(age_days, 0) / 90.0))
    return effective, age_days


def scan_project_notes(memory_dir: Path) -> dict[str, dict[str, Any]]:
    """Per-note structural records for one project (excludes MEMORY.md and symlinks)."""
    records: dict[str, dict[str, Any]] = {}
    for relative, path in sorted(files(memory_dir, markdown_only=True).items()):
        if relative in ("MEMORY.md", "MEMORY-archive.md") or path.is_symlink():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        metadata, _error, body, _raw = parse_frontmatter(text)
        name = None
        description = None
        if isinstance(metadata, dict):
            candidate = metadata.get("name")
            if isinstance(candidate, str) and candidate.strip():
                name = candidate.strip()
            candidate = metadata.get("description")
            if isinstance(candidate, str) and candidate.strip():
                description = candidate.strip()
        stat = path.stat()
        nested = metadata.get("metadata") if isinstance(metadata, dict) else None
        records[relative] = {
            "body": body,
            "body_bytes": len(body.encode("utf-8")),
            "mtime": stat.st_mtime,
            "stem": Path(relative).name[:-3],
            "name": name,
            "description": description,
            "nested_meta": nested if isinstance(nested, dict) else {},
        }
    return records


def project_by_canon(stems: set[str], names: set[str]) -> dict[str, set[str]]:
    """Canonical-form graph mirroring the auditor's wikilink_typo resolution."""
    by_canon: dict[str, set[str]] = {}
    for stem in stems:
        by_canon.setdefault(canon(stem), set()).add(stem)
        for prefix in ("feedback_", "project_", "reference_"):
            if stem.startswith(prefix):
                by_canon.setdefault(canon(stem[len(prefix):]), set()).add(stem)
    for name in names:
        by_canon.setdefault(canon(name), set()).add(name)
    return by_canon


def inbound_index(records: dict[str, dict[str, Any]]) -> dict[str, set[str]]:
    """Target rel -> set of source rels that [[wikilink]] to it (v1: wikilinks only).

    Doubles as the retargeting index (R16/KTD8): the same single-candidate
    resolution the auditor uses for wikilink_typo, so a link resolves only when
    exactly one note owns its canonical form.
    """
    stems = {record["stem"] for record in records.values()}
    names = {record["name"] for record in records.values() if record["name"]}
    by_canon = project_by_canon(stems, names)
    token_to_rel: dict[str, set[str]] = {}
    for rel, record in records.items():
        token_to_rel.setdefault(record["stem"], set()).add(rel)
        if record["name"]:
            token_to_rel.setdefault(record["name"], set()).add(rel)
    index: dict[str, set[str]] = {rel: set() for rel in records}
    for source, record in records.items():
        for match in WIKILINK_RE.finditer(record["body"]):
            link = match.group(1)
            key = canon(re.sub(r"\s+", "", link) if "\n" in link else link)
            candidates = by_canon.get(key, set())
            if len(candidates) != 1:
                continue
            targets = token_to_rel.get(next(iter(candidates)), set())
            if len(targets) != 1:
                continue
            target = next(iter(targets))
            if target != source:
                index[target].add(source)
    return index


def link_resolver(records: dict[str, dict[str, Any]]) -> tuple[dict[str, set[str]], dict[str, set[str]]]:
    """(by_canon, token_to_rel) for resolving a [[wikilink]] to at most one note rel."""
    stems = {record["stem"] for record in records.values()}
    names = {record["name"] for record in records.values() if record["name"]}
    by_canon = project_by_canon(stems, names)
    token_to_rel: dict[str, set[str]] = {}
    for rel, record in records.items():
        token_to_rel.setdefault(record["stem"], set()).add(rel)
        if record["name"]:
            token_to_rel.setdefault(record["name"], set()).add(rel)
    return by_canon, token_to_rel


def resolve_link(link: str, by_canon: dict[str, set[str]], token_to_rel: dict[str, set[str]]) -> str | None:
    """The single note rel a [[wikilink]] resolves to, or None when ambiguous or unknown."""
    key = canon(re.sub(r"\s+", "", link) if "\n" in link else link)
    candidates = by_canon.get(key, set())
    if len(candidates) != 1:
        return None
    targets = token_to_rel.get(next(iter(candidates)), set())
    return next(iter(targets)) if len(targets) == 1 else None


def rewrite_links_to_deleted(
    text: str,
    by_canon: dict[str, set[str]],
    token_to_rel: dict[str, set[str]],
    delete_to_stem: dict[str, str],
) -> str:
    """Rewrite every [[wikilink]] that resolves to a deleted note to its survivor stem (R16)."""
    head, body = split_frontmatter_raw(text)
    new_body = body
    for match in WIKILINK_RE.finditer(body):
        link = match.group(1)
        target = resolve_link(link, by_canon, token_to_rel)
        if target is not None and target in delete_to_stem:
            new_body = new_body.replace(f"[[{link}]]", f"[[{delete_to_stem[target]}]]")
    return head + new_body


def score_note(
    body_bytes: int, age_days: int, inbound: int, supersessions: int, desc_problems: tuple[str, ...] = ()
) -> tuple[int, list[str]]:
    """Additive priority score plus per-signal reasons; ranks the flagged set (KTD6 cap picks the top)."""
    score = 0
    reasons: list[str] = []
    if supersessions >= 1:
        score += 3 * supersessions
        reasons.append(f"supersession:{supersessions}")
    if body_bytes > TRIAGE_BODY_BYTES_LARGE:
        score += 5
        reasons.append(f"size:{body_bytes}")
    elif body_bytes > TRIAGE_BODY_BYTES:
        score += 3
        reasons.append(f"size:{body_bytes}")
    if age_days > TRIAGE_AGE_DAYS_OLD:
        score += 2
        reasons.append(f"age:{age_days}")
    elif age_days > TRIAGE_AGE_DAYS:
        score += 1
        reasons.append(f"age:{age_days}")
    if inbound == 0:
        score += 1
        reasons.append("orphan:0-inbound")
    score += 2 * len(desc_problems)
    reasons.extend(desc_problems)
    return score, reasons


def is_flagged(body_bytes: int, supersessions: int, desc_problems: tuple[str, ...] = ()) -> bool:
    """Structural-rot gate: supersession stacks, oversized bodies, and unroutable
    descriptions flag (recall is description-routed, so a bad one hides its note)."""
    return (
        supersessions >= TRIAGE_SUPERSESSION_FLAG
        or body_bytes > TRIAGE_BODY_BYTES
        or bool(desc_problems)
    )


def description_problems(description: str | None, duplicated: set[str]) -> tuple[str, ...]:
    """Deterministic description-quality signals for one note.

    desc_short: too few words to route agentic recall (or missing entirely).
    desc_dup: another note in the same project carries the identical description,
    so neither can be told apart at recall time.
    """
    problems: list[str] = []
    if description is None or len(description.split()) < TRIAGE_DESC_MIN_WORDS:
        problems.append("desc_short")
    elif description.casefold() in duplicated:
        problems.append("desc_dup")
    return tuple(problems)


def duplicated_descriptions(records: dict[str, dict[str, Any]]) -> set[str]:
    """Case-folded descriptions carried verbatim by two or more notes in a project."""
    seen: dict[str, int] = {}
    for record in records.values():
        description = record.get("description")
        if isinstance(description, str):
            key = description.casefold()
            seen[key] = seen.get(key, 0) + 1
    return {key for key, count in seen.items() if count >= 2}


def effective_index_size(index_text: str) -> tuple[int, int]:
    """(lines, bytes) of MEMORY.md as Claude Code measures its load cap: YAML
    frontmatter and block-level HTML comments are stripped before counting
    (v2.1.211 accounting); the first 200 lines / 25KB actually load, the rest is
    silently invisible to every session."""
    _fm, body = split_frontmatter_raw(index_text)
    body = re.sub(r"(?s)<!--.*?-->", "", body)
    return len(body.splitlines()), len(body.encode("utf-8"))


def loaded_index_text(index_text: str) -> str:
    """The index content a session ACTUALLY loads: frontmatter and block HTML
    comments stripped, then hard-truncated to the first INDEX_LOAD_MAX_LINES lines
    and INDEX_LOAD_MAX_BYTES bytes, whichever cuts first. Anything past this is
    invisible to real recall, so eval judges must never see it either."""
    _fm, body = split_frontmatter_raw(index_text)
    body = re.sub(r"(?s)<!--.*?-->", "", body)
    truncated = "".join(body.splitlines(keepends=True)[:INDEX_LOAD_MAX_LINES])
    return truncated.encode("utf-8")[:INDEX_LOAD_MAX_BYTES].decode("utf-8", errors="ignore")


def triage_project(project: str, memory_dir: Path, now: dt.date) -> tuple[int, list[dict[str, Any]]]:
    records = scan_project_notes(memory_dir)
    index = inbound_index(records)
    duplicated = duplicated_descriptions(records)
    flagged: list[dict[str, Any]] = []
    for rel, record in sorted(records.items()):
        supersessions = len(SUPERSESSION_RE.findall(record["body"]))
        age_days = max(0, (now - dt.date.fromtimestamp(record["mtime"])).days)
        inbound = len(index[rel])
        desc_problems = description_problems(record.get("description"), duplicated)
        score, reasons = score_note(record["body_bytes"], age_days, inbound, supersessions, desc_problems)
        # Decay flag (issue #142): mined notes carry confidence/last_validated;
        # 90-day half-life. Effective < 0.3 => dream-pass candidate (revalidate
        # or archive), surfaced through the same flagged channel the pass reads.
        decayed = False
        nested = record.get("nested_meta") or {}
        decay = decay_effective(nested, now)
        if decay is not None:
            effective, _age_days = decay
            if effective < 0.3:
                decayed = True
                reasons = list(reasons) + [f"decayed_confidence (effective {effective:.2f})"]
        if decayed or is_flagged(record["body_bytes"], supersessions, desc_problems):
            flagged.append(
                {
                    "project": project,
                    "path": rel,
                    "score": score,
                    "reasons": reasons,
                    "body_bytes": record["body_bytes"],
                    "age_days": age_days,
                    "age_source": "mtime",
                    "inbound_links": inbound,
                    "supersessions": supersessions,
                }
            )
    return len(records), flagged


def recently_applied_paths(days: int, now: dt.date) -> set[tuple[str, str]]:
    """(project, path) pairs an APPLIED dream pass touched within the window.

    Reads applied patch-set manifests so both triage and the planner can skip
    consolidation-refire flags (size and supersession-language heuristics fire
    on notes already in their durable form)."""
    recently_applied: set[tuple[str, str]] = set()
    pass_root = Path(os.environ.get("MEMORY_DREAM_PASS_ROOT", "~/.claude/logs/dream-pass")).expanduser()
    cutoff = dt.date.fromordinal(now.toordinal() - days)
    if not pass_root.is_dir():
        return recently_applied
    for patch_dir in pass_root.iterdir():
        apply_manifest = patch_dir / "apply-manifest.json"
        manifest = patch_dir / "manifest.json"
        if not (apply_manifest.is_file() and manifest.is_file()):
            continue
        if dt.date.fromtimestamp(apply_manifest.stat().st_mtime) < cutoff:
            continue
        try:
            proposals = json.loads(manifest.read_text())["proposals"]
        except (json.JSONDecodeError, KeyError, OSError):
            continue
        for proposal in proposals:
            project = proposal.get("project", "")
            for result_file in proposal.get("results") or []:
                if isinstance(result_file, dict) and result_file.get("path"):
                    recently_applied.add((project, result_file["path"]))
            # Early-wave manifests store survivor as a bare path string.
            survivor = proposal.get("survivor")
            if isinstance(survivor, str) and survivor:
                recently_applied.add((project, survivor))
            elif isinstance(survivor, dict) and survivor.get("path"):
                recently_applied.add((project, survivor["path"]))
    return recently_applied


def run_triage(args: argparse.Namespace) -> int:
    live_root = Path(args.live_root).expanduser()
    if not live_root.is_dir():
        print(f"memory-triage: live root is not a directory: {live_root}", file=sys.stderr)
        return 2
    now = args.now or dt.date.today()
    live = project_dirs(live_root, live=True)
    all_flagged: list[dict[str, Any]] = []
    notes_scored = 0
    by_project: dict[str, int] = {}
    index_over_budget: dict[str, dict[str, int]] = {}
    index_bare_fragments: dict[str, int] = {}
    for project in sorted(live):
        memory_dir = live[project]
        if memory_dir.is_symlink() or memory_dir.parent.is_symlink():
            # Symlinked roots are an audit finding; triage never traverses them.
            continue
        count, flagged = triage_project(project, memory_dir, now)
        notes_scored += count
        if flagged:
            by_project[project] = len(flagged)
            all_flagged.extend(flagged)
        index_path = memory_dir / "MEMORY.md"
        if index_path.is_file() and not index_path.is_symlink():
            index_text = index_path.read_text(encoding="utf-8", errors="replace")
            lines, size = effective_index_size(index_text)
            if (
                lines >= INDEX_LOAD_MAX_LINES * INDEX_BUDGET_FRACTION
                or size >= INDEX_LOAD_MAX_BYTES * INDEX_BUDGET_FRACTION
            ):
                index_over_budget[project] = {"lines": lines, "bytes": size}
            # A bare `[-](slug.md)` fragment cannot route recall (#1450); the
            # same weekly WARN channel as the load-cap line, rehook is the fix.
            bare = len(BARE_FRAGMENT_RE.findall(index_text))
            if bare:
                index_bare_fragments[project] = bare
    # Consolidation-refire suppression: notes an applied dream pass touched
    # within --suppress-applied-days are already in their durable form; size and
    # supersession-language heuristics refire on correct content (pass-9 saw 3
    # just-consolidated notes reflagged the same day). Suppressed entries are
    # reported, not silently dropped.
    suppressed: list[dict[str, Any]] = []
    days = getattr(args, "suppress_applied_days", 14)
    if days > 0:
        recently_applied = recently_applied_paths(days, now)
        if recently_applied:
            kept = []
            for record in all_flagged:
                if (record["project"], record["path"]) in recently_applied:
                    suppressed.append(record)
                else:
                    kept.append(record)
            all_flagged = kept
            for record in suppressed:
                by_project[record["project"]] = by_project.get(record["project"], 1) - 1
                if by_project.get(record["project"], 0) <= 0:
                    by_project.pop(record["project"], None)
    all_flagged.sort(key=lambda record: (-record["score"], record["project"], record["path"]))
    result = {
        "schema_version": 1,
        "command": "triage",
        "roots": {"live": str(live_root), "mirror": mirror_root_label(args.mirror_root)},
        "now": now.isoformat(),
        "summary": {
            "live_projects": len(live),
            "notes_scored": notes_scored,
            "flagged": len(all_flagged),
            "suppressed_recently_applied": len(suppressed),
            "by_project": dict(sorted(by_project.items())),
            "index_over_budget": dict(sorted(index_over_budget.items())),
            "index_bare_fragments": dict(sorted(index_bare_fragments.items())),
        },
        "flagged": all_flagged,
        "suppressed": suppressed,
    }
    try:
        require_floor(result["summary"]["live_projects"], 1, "memory triage live projects")
    except FloorNotMet as error:
        print(error, file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    else:
        print(render_triage_human(result))
    return 0


def render_triage_human(result: dict[str, Any]) -> str:
    # Project-level only, no note filenames or bodies, so the weekly report can
    # embed this verbatim (R11, U4). The trailing flagged:N line is the toast grep.
    summary = result["summary"]
    lines = [
        "memory-triage: "
        f"{summary['live_projects']} project(s), {summary['notes_scored']} note(s) scored, "
        f"{summary['flagged']} flagged"
    ]
    for project, count in summary["by_project"].items():
        top = max((record["score"] for record in result["flagged"] if record["project"] == project), default=0)
        lines.append(f"  {project}: {count} flagged (max score {top})")
    # Claude Code hard-truncates MEMORY.md at 200 lines / 25KB on load; past the cap
    # is invisible to every session. WARN prefix on purpose: harness-weekly toasts on it.
    for project, size in summary.get("index_over_budget", {}).items():
        lines.append(
            f"WARN {project}: MEMORY.md at {size['lines']}/{INDEX_LOAD_MAX_LINES} lines, "
            f"{size['bytes']}/{INDEX_LOAD_MAX_BYTES} bytes (>=70% of the session load cap)"
        )
    for project, count in summary.get("index_bare_fragments", {}).items():
        lines.append(
            f"WARN {project}: MEMORY.md carries {count} bare [-](slug) fragment(s) that cannot route recall "
            "(memory-audit.py rehook previews the fix)"
        )
    lines.append(f"flagged:{summary['flagged']}")
    return "\n".join(lines)


def push_excluded_paths(project: str, memory_dir: Path, filename_allowlist: set[str]) -> set[str]:
    """Live paths that `sync.sh memory-push` never copies: the miner's droppings
    and every path the copy gate quarantines (a sensitive filename that is not
    allowlisted, a content signature, a sensitive frontmatter key), by the same
    rules the audit applies. The freshness gate must not demand these from the
    mirror: with them demanded, `fix --apply` could never pass on a project that
    held one (#1450 found dotfiles blocked on three notes *about* credentials)."""
    excluded: set[str] = set()
    for relative, path in files(memory_dir).items():
        if is_miner_dropping(relative):
            excluded.add(relative)
            continue
        if path.is_symlink():
            continue
        filename = Path(relative).name
        if WHATSAPP_STORE_FILENAME_RE.search(filename):
            excluded.add(relative)
            continue
        if SENSITIVE_FILENAME_RE.search(filename) and f"{project}/{relative}" not in filename_allowlist:
            excluded.add(relative)
            continue
        try:
            raw_text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if any(pattern.search(raw_text) for pattern in CONTENT_SIGNATURES):
            excluded.add(relative)
            continue
        if relative.endswith(".md"):
            metadata, _error, _body, _raw = parse_frontmatter(raw_text)
            if isinstance(metadata, dict):
                keys = [key for key in metadata if SENSITIVE_KEY_RE.search(key)]
                nested = metadata.get("metadata")
                if isinstance(nested, dict):
                    keys.extend(key for key in nested if SENSITIVE_KEY_RE.search(key))
                if keys:
                    excluded.add(relative)
    return excluded


def mirror_freshness(
    live_root: Path,
    mirror_root: Path,
    projects: list[str],
    filename_allowlist: set[str] | None = None,
) -> dict[str, list[str]]:
    """Per-project live->mirror freshness gate shared by fix --apply, rehook --apply
    and the apply script.

    Returns {project: [finding_kind, ...]} for any project whose live memory is
    not fully reflected in the mirror (KTD5), "fully" meaning every path the push
    would copy: what it never copies (push_excluded_paths) cannot be demanded.
    mirror_only paths do not block: the mirror deliberately preserves history
    the live tree no longer has.
    """
    if filename_allowlist is None:
        filename_allowlist = load_filename_allowlist(filename_allowlist_path())
    live = project_dirs(live_root, live=True)
    mirror = project_dirs(mirror_root, live=False)
    result: dict[str, list[str]] = {}
    for project in projects:
        issues: set[str] = set()
        if project not in mirror:
            issues.add("mirror_missing_project")
        elif project in live:
            live_files = files(live[project])
            mirror_files = files(mirror[project])
            excluded = push_excluded_paths(project, live[project], filename_allowlist)
            for rel in sorted(live_files):
                if rel in excluded:
                    continue  # never mirrored by design; see push_excluded_paths
                if rel not in mirror_files:
                    issues.add("mirror_missing_file")
                elif digest(live_files[rel]) != digest(mirror_files[rel]):
                    issues.add("mirror_stale_file")
        if issues:
            result[project] = sorted(issues)
    return result


def confined_path(memory_dir: Path, rel: str) -> Path | None:
    """Resolve rel to a .md file strictly inside memory_dir, or None on any escape (R18).

    Rejects empty, absolute, traversal, non-.md, MEMORY.md (single-writer), NUL bytes,
    and any symlink-escaping destination. The single confinement implementation shared
    by the assembler and the apply script, so the security check can never drift.
    """
    if not rel or os.path.isabs(rel):
        return None
    candidate = Path(rel)
    if candidate.is_absolute() or ".." in candidate.parts:
        return None
    if candidate.name == "MEMORY.md" or not candidate.name.endswith(".md"):
        return None
    dest = memory_dir / candidate
    try:
        base = memory_dir.resolve()
        resolved = dest.resolve()
    except (OSError, ValueError):
        return None
    if resolved == base or base not in resolved.parents:
        return None
    return dest


def atomic_write(path: Path, data: bytes) -> None:
    """Write via a temp sibling then rename, so an interrupted write never truncates."""
    temp = path.with_name(path.name + ".dream-tmp")
    temp.write_bytes(data)
    os.replace(temp, path)


def _fm_quote_if_needed(value: str) -> str:
    """Quote a frontmatter scalar when a bare value would be mis-parsed (e.g. contains
    '#', a colon, or leading/trailing whitespace); matches the memory '#'-quoting rule."""
    if value != value.strip() or any(ch in value for ch in "#:") or value[:1] in "!&*[]{}>|%@`\"'":
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return value


def _set_fm_field(lines: list[str], key: str, indent: str, value: str) -> bool:
    """Replace the value of `<indent>key:` in a frontmatter line list, in place.
    Returns False when no such line exists (nothing replaced)."""
    pattern = re.compile(rf"^{re.escape(indent)}{re.escape(key)}\s*:")
    for index, line in enumerate(lines):
        if pattern.match(line):
            newline = "\n" if line.endswith("\n") else ""
            lines[index] = f"{indent}{key}: {value}{newline}"
            return True
    return False


def _set_or_insert_nested(lines: list[str], key: str, value: str) -> None:
    """Set `  key: value` inside the frontmatter's nested `metadata:` block, inserting
    after the block's last field when absent. No-op when there is no nested block
    (legacy flat-schema notes; ~19% of the corpus): never invent structure."""
    if _set_fm_field(lines, key, "  ", value):
        return
    for index, line in enumerate(lines):
        if re.match(r"^metadata\s*:", line):
            end = index + 1
            while end < len(lines) and re.match(r"^\s{2,}\S", lines[end]):
                end += 1
            lines.insert(end, f"  {key}: {value}\n")
            return


_FLAT_SCHEMA_FIELDS = ("node_type", "type", "originSessionId")


def _normalize_flat_schema(lines: list[str]) -> list[str]:
    """Lift a legacy flat-schema frontmatter's harness fields into a nested
    metadata block, preserving their values verbatim. Lift-only: fields absent
    from the donor are never invented, unknown top-level fields stay top-level,
    and frontmatter that already has a metadata: block is returned unchanged."""
    if any(re.match(r"^metadata\s*:", line) for line in lines):
        return lines
    lifted: dict[str, str] = {}
    kept: list[str] = []
    for line in lines:
        match = re.match(r"^(node_type|type|originSessionId)\s*:\s*(.*?)\s*$", line)
        if match:
            lifted[match.group(1)] = match.group(2)
        else:
            kept.append(line)
    if not lifted:
        return lines
    block = ["metadata:\n"] + [
        f"  {key}: {lifted[key]}\n" for key in _FLAT_SCHEMA_FIELDS if key in lifted
    ]
    # The raw frontmatter includes its --- delimiter lines; the block must land
    # inside them, so insert before the closing delimiter (the last --- line).
    closing = max(
        (index for index, line in enumerate(kept) if line.rstrip("\n") == "---"),
        default=None,
    )
    if closing is None or closing == 0:
        return lines
    return kept[:closing] + block + kept[closing:]


def preserve_metadata(
    drafter_content: str, donor_content: str, extra_nested: dict[str, str] | None = None
) -> str:
    """Overlay the drafter's name/description/type onto the DONOR note's frontmatter.

    A consolidation must not silently strip schema fields the harness maintains
    (node_type, originSessionId, any other metadata). The drafter reconstructs a
    minimal frontmatter; this keeps the donor's full frontmatter block and only
    updates name, description, and metadata.type from the drafter's output, then
    appends the drafter's body. extra_nested fields (e.g. honest multi-source
    originSessionIds for a merge) are set inside the nested metadata block.
    A legacy flat-schema donor (top-level type/node_type/originSessionId, no
    metadata: block; ~19% of the corpus) is normalized first: its harness fields
    are lifted, values unchanged, into a nested metadata block, so consolidation
    heals the legacy shape instead of propagating it and extra_nested fields are
    not silently dropped. Returns the drafter content unchanged when either side
    lacks parseable frontmatter (nothing safe to merge).
    """
    donor_fm, _donor_body = split_frontmatter_raw(donor_content)
    drafter_fm, drafter_body = split_frontmatter_raw(drafter_content)
    if not donor_fm or not drafter_fm:
        return drafter_content
    metadata, error, _body, _raw = parse_frontmatter(drafter_content)
    if error or not isinstance(metadata, dict):
        return drafter_content
    lines = _normalize_flat_schema(donor_fm.splitlines(keepends=True))
    if isinstance(metadata.get("name"), str) and metadata["name"].strip():
        _set_fm_field(lines, "name", "", metadata["name"].strip())
    if isinstance(metadata.get("description"), str) and metadata["description"].strip():
        _set_fm_field(lines, "description", "", _fm_quote_if_needed(metadata["description"].strip()))
    nested = metadata.get("metadata")
    if isinstance(nested, dict) and isinstance(nested.get("type"), str) and nested["type"].strip():
        _set_fm_field(lines, "type", "  ", nested["type"].strip())
    for key, value in (extra_nested or {}).items():
        _set_or_insert_nested(lines, key, value)
    return "".join(lines) + drafter_body


def content_tokens(value: str) -> set[str]:
    """Content-word token set for description-similarity checks (recall is routed
    by these one-liners, so two near-identical descriptions cannot be told apart)."""
    return set(re.findall(r"[a-z0-9]{4,}", value.casefold()))


def description_similarity(first: str, second: str) -> float:
    """Jaccard overlap of two descriptions' content words; 0.0 when either is empty."""
    a, b = content_tokens(first), content_tokens(second)
    union = a | b
    return len(a & b) / len(union) if union else 0.0


def origin_session_id(content: str) -> str | None:
    """The note's originSessionId, tolerating both frontmatter shapes (nested
    metadata block or legacy flat top-level); None when absent or unparseable."""
    metadata, error, _body, _raw = parse_frontmatter(content)
    if error or not isinstance(metadata, dict):
        return None
    nested = metadata.get("metadata")
    value = nested.get("originSessionId") if isinstance(nested, dict) else None
    value = value or metadata.get("originSessionId")
    return value.strip() if isinstance(value, str) and value.strip() else None


def redescribe_content(donor_content: str, description: str) -> str | None:
    """The donor note with ONLY its frontmatter description replaced; body, name,
    and every other frontmatter byte are preserved by construction. None when the
    donor has no parseable description line to replace.

    The description arrives RAW from drafter JSON (unlike every other overlay
    value, which passes through the line-based frontmatter parser), so collapse
    all whitespace runs: an embedded newline would otherwise inject arbitrary
    frontmatter lines."""
    donor_fm, donor_body = split_frontmatter_raw(donor_content)
    if not donor_fm:
        return None
    lines = donor_fm.splitlines(keepends=True)
    flattened = " ".join(description.split())
    if not flattened or not _set_fm_field(lines, "description", "", _fm_quote_if_needed(flattened)):
        return None
    return "".join(lines) + donor_body


def is_valid_utf8(raw: bytes) -> bool:
    try:
        raw.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def content_id(proposals: list[dict[str, Any]]) -> str:
    """Content-bound patch-set id: the digest apply recomputes and the operator's token
    must match, so editing any proposal byte after approval invalidates the approval."""
    return hashlib.sha256(json.dumps(proposals, sort_keys=True).encode("utf-8")).hexdigest()[:16]


# --- Dream-pass fix mode (mechanical repairs) --------------------------------


def split_frontmatter_raw(text: str) -> tuple[str, str]:
    """Return (frontmatter-with-fences, body) preserving bytes exactly; ("", text) when none."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        return "", text
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            return "".join(lines[: index + 1]), "".join(lines[index + 1 :])
    return "", text


def entry_fields(note_path: Path, rel: str) -> tuple[str, str]:
    """Link text and hook for a MEMORY.md entry, sourced from the note's frontmatter."""
    fallback = Path(rel).name[:-3] if rel.endswith(".md") else rel
    try:
        text = note_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return fallback, ""
    metadata, _error, _body, _raw = parse_frontmatter(text)
    name = None
    description = None
    if isinstance(metadata, dict):
        candidate_name = metadata.get("name")
        candidate_desc = metadata.get("description")
        if isinstance(candidate_name, str) and candidate_name.strip():
            name = candidate_name.strip()
        if isinstance(candidate_desc, str) and candidate_desc.strip():
            description = candidate_desc.strip()
    return name or fallback, description or ""


def compute_index_reconcile(
    project: str,
    memory_dir: Path,
    records: dict[str, dict[str, Any]],
    restrict_appends_to: set[str] | None = None,
) -> dict[str, Any] | None:
    """Index reconciliation plan: drop all-dead lines, append unindexed notes.

    restrict_appends_to bounds the append set (the dream pass appends ONLY the
    notes it just created): corpus-wide index HEALING, appending pre-existing
    unindexed notes, is a routing-surface change of its own (the shadow experiment
    measured it at most of a +35% index-token jump) and stays a separately gated
    step (`fix` mode passes None and heals everything)."""
    index_path = memory_dir / "MEMORY.md"
    if not index_path.is_file() or index_path.is_symlink():
        return None  # a missing index is an audit finding; fix does not create indexes in v1
    text = index_path.read_text(encoding="utf-8", errors="replace")
    targets, _escaping = index_targets(text)
    live_note_rels = set(records)
    # The archive tiers are index files, not notes (records never hold the legacy
    # MEMORY-archive.md), so a link to one that exists is live, and a note one of
    # them lists is already indexed below the load cut: healing it into MEMORY.md
    # would undo rehook's split.
    live_index_files = {name for name in ("MEMORY-archive.md", ARCHIVE_INDEX_NAME) if (memory_dir / name).is_file()}
    try:
        archived = archive_tier_targets(memory_dir)
    except OSError:
        # Healing without the tier would append its notes back into MEMORY.md, so
        # skip this project, as rehook skips an unreadable tier.
        return None
    gone = {
        target for target in targets
        if target != "MEMORY.md" and target not in live_note_rels and target not in live_index_files
    }
    # A gone target is only "dropped" when its entire index line is dead, matching
    # what apply removes. A mixed line (a dead and a surviving link) is left intact
    # and its dead target is NOT claimed as dropped, so the record never lies; the
    # residual stale ref stays visible as the auditor's missing_index_target.
    droppable: set[str] = set()
    fragment_droppable: set[str] = set()
    for line in text.splitlines():
        line_targets, _escaping = index_targets(line)
        dead_here = line_targets & gone
        if not dead_here:
            continue
        if line_targets.issubset(gone):
            droppable |= dead_here
        else:
            # A dead ref on a mixed (hand-packed) line: the LINE is preserved
            # (KTD7 protects the live fragments' hand-edited content) but the
            # dead fragment itself is removable; a link to a nonexistent file
            # serves nobody (found live: a period-close left a dangling packed
            # fragment the auditor could only report, never repair).
            fragment_droppable |= dead_here
    dropped = sorted(droppable)
    fragment_dropped = sorted(fragment_droppable)
    unindexed = sorted(
        rel for rel in live_note_rels
        if rel not in targets and rel not in archived and (restrict_appends_to is None or rel in restrict_appends_to)
    )
    if not dropped and not unindexed and not fragment_dropped:
        return None
    return {
        "kind": "index_reconcile", "project": project, "path": "MEMORY.md",
        "dropped": dropped, "appended": unindexed, "fragment_dropped": fragment_dropped,
    }


def compute_fix(live_root: Path) -> list[dict[str, Any]]:
    live = project_dirs(live_root, live=True)
    repairs: list[dict[str, Any]] = []
    for project in sorted(live):
        memory_dir = live[project]
        if memory_dir.is_symlink() or memory_dir.parent.is_symlink():
            continue
        records = scan_project_notes(memory_dir)
        stems = {record["stem"] for record in records.values()}
        names = {record["name"] for record in records.values() if record["name"]}
        by_canon = project_by_canon(stems, names)
        for rel, record in sorted(records.items()):
            seen: set[tuple[str, str]] = set()
            for match in WIKILINK_RE.finditer(record["body"]):
                link = match.group(1)
                if link in stems or link in names:
                    continue
                key = canon(re.sub(r"\s+", "", link) if "\n" in link else link)
                candidates = by_canon.get(key, set())
                if len(candidates) != 1:
                    continue
                target = next(iter(candidates))
                if target == link or (rel, link) in seen:
                    continue
                seen.add((rel, link))
                repairs.append(
                    {"kind": "wikilink_rewrite", "project": project, "path": rel, "link": link, "resolves_to": target}
                )
        reconcile = compute_index_reconcile(project, memory_dir, records)
        if reconcile:
            repairs.append(reconcile)
    return repairs


def rewrite_wikilinks(path: Path, items: list[dict[str, Any]]) -> bool:
    """Rewrite [[wikilinks]] atomically, preserving mtime. Returns False (untouched) when
    the file is not valid UTF-8, so a read-modify-write never lossily corrupts stray bytes."""
    stat = path.stat()
    raw = path.read_bytes()
    if not is_valid_utf8(raw):
        return False
    head, body = split_frontmatter_raw(raw.decode("utf-8"))
    for item in items:
        body = body.replace(f"[[{item['link']}]]", f"[[{item['resolves_to']}]]")
    atomic_write(path, (head + body).encode("utf-8"))
    os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    return True


def strip_dead_index_fragments(line: str, dead: set[str]) -> str:
    """Remove '; '-separated fragments of a packed index line whose only .md
    targets are all dead. Live fragments are preserved byte-for-byte (KTD7:
    hand-edited content for live notes is never rewritten); a fragment mixing a
    dead and a live target is conservatively left intact. Returns the line
    unchanged when nothing is safely removable."""
    newline = "\n" if line.endswith("\n") else ""
    body = line.rstrip("\n")
    fragments = body.split("; ")
    kept_fragments: list[str] = []
    for fragment in fragments:
        frag_targets, _escaping = index_targets(fragment)
        if frag_targets and frag_targets.issubset(dead):
            continue
        kept_fragments.append(fragment)
    if len(kept_fragments) == len(fragments):
        return line
    rebuilt = "; ".join(kept_fragments).rstrip("; ").rstrip()
    return rebuilt + newline


def render_index_reconcile(
    index_text: str, memory_dir: Path, reconcile: dict[str, Any], content_by_rel: dict[str, str] | None = None
) -> str:
    """The reconciled MEMORY.md text: drop all-dead lines, append unindexed notes.

    Pure (no I/O beyond reading a note's frontmatter for its entry). content_by_rel
    lets the assembler preview an appended entry for a not-yet-written survivor using
    its drafted frontmatter, so the preview matches what apply will produce."""
    content_by_rel = content_by_rel or {}
    gone = set(reconcile["dropped"])
    fragment_gone = set(reconcile.get("fragment_dropped", []))
    kept: list[str] = []
    for line in index_text.splitlines(keepends=True):
        line_targets, _escaping = index_targets(line)
        if line_targets and line_targets.issubset(gone | fragment_gone):
            continue  # every .md target on this line is gone; drop it
        dead_here = line_targets & fragment_gone
        if dead_here:
            line = strip_dead_index_fragments(line, dead_here)
        kept.append(line)
    result = "".join(kept)
    appended: list[str] = []
    for rel in reconcile["appended"]:
        if rel in content_by_rel:
            name, description = frontmatter_entry(content_by_rel[rel], rel)
        else:
            name, description = entry_fields(memory_dir / rel, rel)
        # ": " separator, not an em dash, per the standing no-em-dash rule; a '#'
        # inside description is literal markdown text here, not a YAML comment.
        appended.append(index_entry_line(name, description, rel) + "\n")
    if appended:
        if result and not result.endswith("\n"):
            result += "\n"
        result += "".join(appended)
    return result


def index_entry_line(name: str, description: str, rel: str) -> str:
    """The canonical MEMORY.md entry for a note (shared by append, refresh, and the
    hand-edit detection that guards refresh)."""
    return f"- [{name}]({rel}): {description}" if description else f"- [{name}]({rel})"


def refresh_index_lines(index_text: str, refresh: dict[str, dict[str, Any]]) -> str:
    """Rewrite the MEMORY.md entry line of each refreshed note to match its current
    frontmatter. refresh: rel -> {"old": (name, description) | None,
    "new": (name, description), "force": bool}.

    Recall is routed by these one-line hooks, so a note the pass just rewrote must
    not keep advertising its pre-consolidation description (the corpus audit found
    index lines and frontmatter descriptions diverging independently). Guardrails:
    only a line whose sole .md target is the refreshed note is considered, and it is
    replaced only when it exactly matches the canonical rendering of the note's
    PRE-rewrite frontmatter; any deviation means a hand-edited line, which is
    preserved (KTD7). "force" (redescribe: updating the routing hook is the action's
    operator-approved purpose, and the index diff is in the preview) replaces the
    sole-target line regardless."""
    if not refresh:
        return index_text
    result: list[str] = []
    for line in index_text.splitlines(keepends=True):
        line_targets, _escaping = index_targets(line)
        if len(line_targets) == 1 and (rel := next(iter(line_targets))) in refresh:
            entry = refresh[rel]
            old = entry.get("old")
            matches_old = old is not None and line.rstrip() == index_entry_line(old[0], old[1], rel)
            if entry.get("force") or matches_old:
                name, description = entry["new"]
                newline = "\n" if line.endswith("\n") else ""
                result.append(f"{index_entry_line(name, description, rel)}{newline}")
                continue
        result.append(line)
    return "".join(result)


def frontmatter_entry(content: str, rel: str) -> tuple[str, str]:
    """Link text and hook from in-memory note content (for previewing a fresh survivor)."""
    fallback = Path(rel).name[:-3] if rel.endswith(".md") else rel
    metadata, _error, _body, _raw = parse_frontmatter(content)
    name = description = None
    if isinstance(metadata, dict):
        candidate_name, candidate_desc = metadata.get("name"), metadata.get("description")
        if isinstance(candidate_name, str) and candidate_name.strip():
            name = candidate_name.strip()
        if isinstance(candidate_desc, str) and candidate_desc.strip():
            description = candidate_desc.strip()
    return name or fallback, description or ""


def apply_index_reconcile(index_path: Path, memory_dir: Path, reconcile: dict[str, Any]) -> None:
    stat = index_path.stat()
    raw_index = index_path.read_bytes()
    index_text = raw_index.decode("utf-8") if is_valid_utf8(raw_index) else raw_index.decode("utf-8", errors="replace")
    result = render_index_reconcile(index_text, memory_dir, reconcile)
    atomic_write(index_path, result.encode("utf-8"))
    os.utime(index_path, ns=(stat.st_atime_ns, stat.st_mtime_ns))


def apply_index_refresh(index_path: Path, refresh: dict[str, dict[str, Any]]) -> None:
    """Refresh index entry lines to match current note frontmatter, mtime-preserving
    (maintenance must never reset the age signal, KTD3)."""
    if not refresh or not index_path.is_file() or index_path.is_symlink():
        return
    stat = index_path.stat()
    raw_index = index_path.read_bytes()
    index_text = raw_index.decode("utf-8") if is_valid_utf8(raw_index) else raw_index.decode("utf-8", errors="replace")
    result = refresh_index_lines(index_text, refresh)
    if result != index_text:
        atomic_write(index_path, result.encode("utf-8"))
        os.utime(index_path, ns=(stat.st_atime_ns, stat.st_mtime_ns))


def apply_fix(live_root: Path, mirror_root: Path, repairs: list[dict[str, Any]], hint: str = "") -> int:
    affected = sorted({repair["project"] for repair in repairs})
    stale = mirror_freshness(live_root, mirror_root, affected)
    if stale:
        for project, kinds in sorted(stale.items()):
            print(
                f"memory-fix: refusing to apply to {project}: mirror not fresh ({', '.join(kinds)})"
                + (f"; {hint}" if hint else ""),
                file=sys.stderr,
            )
        return 1
    live = project_dirs(live_root, live=True)
    rewrites: dict[tuple[str, str], list[dict[str, Any]]] = {}
    reconciles: list[dict[str, Any]] = []
    for repair in repairs:
        if repair["kind"] == "wikilink_rewrite":
            rewrites.setdefault((repair["project"], repair["path"]), []).append(repair)
        elif repair["kind"] == "index_reconcile":
            reconciles.append(repair)
    for (project, rel), items in sorted(rewrites.items()):
        rewrite_wikilinks(live[project] / rel, items)
    for reconcile in sorted(reconciles, key=lambda item: item["project"]):
        memory_dir = live[reconcile["project"]]
        apply_index_reconcile(memory_dir / "MEMORY.md", memory_dir, reconcile)
    return 0


def run_fix(args: argparse.Namespace) -> int:
    live_root = Path(args.live_root).expanduser()
    if not live_root.is_dir():
        print(f"memory-fix: live root is not a directory: {live_root}", file=sys.stderr)
        return 2
    try:
        require_floor(len(project_dirs(live_root, live=True)), 1, "memory fix live projects")
    except FloorNotMet as error:
        print(error, file=sys.stderr)
        return 2
    repairs = compute_fix(live_root)
    exit_code = 0
    if args.apply and repairs:
        hint = PUSHED_MIRROR_HINT if args.mirror_root is None else ""
        exit_code = apply_fix(live_root, mirror_root_path(args.mirror_root), repairs, hint)
    result = {
        "schema_version": 1,
        "command": "fix",
        "applied": bool(args.apply and repairs and exit_code == 0),
        "roots": {"live": str(live_root), "mirror": mirror_root_label(args.mirror_root)},
        "repairs": repairs,
    }
    if args.format == "json":
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    else:
        print(render_fix_human(result))
    return exit_code


def render_fix_human(result: dict[str, Any]) -> str:
    state = "applied" if result["applied"] else "proposed (dry-run)"
    lines = [f"memory-fix: {len(result['repairs'])} repair(s) {state}"]
    for repair in result["repairs"]:
        if repair["kind"] == "wikilink_rewrite":
            lines.append(
                f"  wikilink {repair['project']}/{repair['path']}: "
                f"[[{repair['link']}]] -> [[{repair['resolves_to']}]]"
            )
        elif repair["kind"] == "index_reconcile":
            lines.append(
                f"  index {repair['project']}/MEMORY.md: "
                f"+{len(repair['appended'])} appended, -{len(repair['dropped'])} dropped"
            )
    return "\n".join(lines)


# --- Rehook mode (bare index fragments -> hooked lines, ranked tier split) ---
#
# Recall is routed by MEMORY.md's one-line hooks, and a bare `[-](slug.md)`
# fragment carries none: the model sees a slug. Packed fragment lines were a
# load-cap workaround, and being hand edits by construction the refresh guard
# (KTD7) preserves them forever (#1450: 231 fragments, and the ninth repeat of
# #436 because the relevant line was bare). rehook renders every bare or
# unindexed entry from its note's frontmatter, ranks all entries (user notes
# first, then newest `modified` first), fills MEMORY.md in rank order under the
# load budget, and moves the rest, hooked, into the archive tier. A previously
# hooked line keeps its text byte-for-byte wherever it lands; only the archive
# pointer's hook is regenerated, and only when a run moves something. Preview
# by default; --apply shares fix's mirror-freshness gate and preserves file
# mtimes (KTD3).

REHOOK_MAIN_MAX_LINES = int(INDEX_LOAD_MAX_LINES * INDEX_BUDGET_FRACTION)
REHOOK_MAIN_MAX_BYTES = int(INDEX_LOAD_MAX_BYTES * INDEX_BUDGET_FRACTION)
REHOOK_DESCRIPTION_CLIP = 110
# Display order of note types in the archive pointer's hook (not a rank).
REHOOK_TYPE_ORDER = {"user": 0, "feedback": 1, "project": 2, "reference": 3}
ARCHIVE_INDEX_NAME = "memory-archive-index.md"
ARCHIVE_POINTER_TEXT = "Archive tier"
BARE_FRAGMENT_RE = re.compile(r"\[-\]\((?P<target>[^()\s]+\.md)\)")
ENTRY_LINE_RE = re.compile(r"^\s*[-*]\s+\[(?P<text>[^\]]*)\]\((?P<target>[^()\s]+\.md)\)")
MEMBER_SPLIT_RE = re.compile(r";\s*(?=\[)")


def clip_description(description: str, limit: int = REHOOK_DESCRIPTION_CLIP) -> str:
    """Whitespace-collapsed description cut at `limit` characters on a word boundary."""
    text = " ".join(description.split())
    if len(text) <= limit:
        return text
    cut = text[:limit]
    if text[limit] != " " and " " in cut:
        cut = cut.rsplit(" ", 1)[0]
    return cut.rstrip(" ,;:")


def note_modified(record: dict[str, Any]) -> float:
    """Frontmatter `metadata.modified` as a POSIX timestamp, else the file mtime."""
    value = (record.get("nested_meta") or {}).get("modified")
    if isinstance(value, str) and value.strip():
        try:
            parsed = dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        except ValueError:
            parsed = None
        if parsed is not None:
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
            return parsed.timestamp()
    return float(record["mtime"])


def rehook_rank_key(rel: str, record: dict[str, Any] | None) -> tuple[int, float, str]:
    """Rank: `user` notes first (the operator's standing preferences are few and
    always relevant), then every other type by `modified` descending, dead links
    last; the path breaks ties so the order is stable.

    Recency rather than type because the always-loaded index is a rolling window
    of what sessions are working on (the recall eval samples by the same premise)
    and it matches how the index had been curated by hand. #1450's first draft
    ranked by type first; on the live corpus that filled the index with feedback
    notes back to August and archived every lesson of the last week, including
    the hand-hooked ones (operator decision, 2026-09-28)."""
    if record is None:
        return (2, 0.0, rel)
    note_type = str((record.get("nested_meta") or {}).get("type", "")).strip()
    return (0 if note_type == "user" else 1, -note_modified(record), rel)


def archive_pointer_line(link_text: str, records: dict[str, dict[str, Any]], archive_rels: set[str]) -> str:
    """The MEMORY.md line pointing at the archive tier, hooked with what the tier
    holds (entry count, type split, modified range) so a session knows when to open it."""
    counts: dict[str, int] = {}
    stamps: list[float] = []
    for rel in archive_rels:
        record = records.get(rel)
        if record is None:
            continue
        note_type = str((record.get("nested_meta") or {}).get("type", "")).strip() or "untyped"
        counts[note_type] = counts.get(note_type, 0) + 1
        stamps.append(note_modified(record))
    total = sum(counts.values())
    order = sorted(counts, key=lambda item: (REHOOK_TYPE_ORDER.get(item, len(REHOOK_TYPE_ORDER)), item))
    types = ", ".join(f"{counts[item]} {item}" for item in order)
    span = ""
    if stamps:
        low = dt.datetime.fromtimestamp(min(stamps), dt.timezone.utc).strftime("%Y-%m-%d")
        high = dt.datetime.fromtimestamp(max(stamps), dt.timezone.utc).strftime("%Y-%m-%d")
        span = f", modified {low} to {high}"
    hook = (
        f"{total} hooked pointer{'s' if total != 1 else ''} below this index's load cut ({types}{span}); "
        "open it when a slug, an older lesson, a status note or a vet is asked about"
    )
    return index_entry_line(link_text, hook, ARCHIVE_INDEX_NAME) + "\n"


def archive_seed() -> str:
    """A fresh archive tier for a project that has none yet."""
    return (
        "---\n"
        "name: memory-archive-index\n"
        'description: "Archive tier of this project\'s memory index: hooked pointers moved out of '
        'MEMORY.md to stay under the session load cap; open it when a slug or an older lesson is asked about"\n'
        "metadata:\n"
        "  type: reference\n"
        "---\n"
        "\n"
        "# Memory archive index\n"
        "\n"
        "Pointers moved out of MEMORY.md by memory-audit.py rehook; the note files are unchanged.\n"
    )


def _comment_step(line: str, in_comment: bool) -> tuple[bool, bool]:
    """(this line belongs to a block HTML comment, comment state after the line).
    The loader strips `<!-- ... -->` blocks before counting, so nothing inside one
    is an entry; a comment that opens and closes on one line after an entry's
    link leaves that entry live."""
    if in_comment:
        return True, "-->" not in line
    opener = line.find("<!--")
    if opener < 0:
        return False, False
    closed = "-->" in line[opener + 4 :]
    if line.lstrip().startswith("<!--"):
        return True, not closed
    return (not closed), (not closed)


def split_index_members(line: str) -> list[tuple[str, str, str]] | None:
    """Members of one index bullet: [(kind, rel, text)] with kind "fragment" for a
    bare `[-](rel.md)` and "entry" for a hooked member; None for a line that is
    not a bullet or holds a member of neither shape (such a line is kept verbatim).

    A bullet whose FIRST member is hooked is one entry, never split: its hook may
    legitimately contain `; [link](x.md)`. Only a bullet that opens with a bare
    fragment is a packed line, and then every member must be a bare fragment or
    a hooked member."""
    stripped = line.rstrip("\r\n").lstrip()
    if stripped[:2] not in ("- ", "* "):
        return None
    body = stripped[2:]
    members = [member.strip() for member in MEMBER_SPLIT_RE.split(body) if member.strip()]
    if not members:
        return None
    if not BARE_FRAGMENT_RE.fullmatch(members[0]):
        entry = ENTRY_LINE_RE.match(stripped)
        if entry is None or entry.group("text") == "-":
            return None  # a bare fragment with trailing junk is not a hooked entry
        return [("entry", entry.group("target"), body)]
    parsed: list[tuple[str, str, str]] = []
    for member in members:
        bare = BARE_FRAGMENT_RE.fullmatch(member)
        if bare:
            parsed.append(("fragment", bare.group("target"), member))
            continue
        entry = ENTRY_LINE_RE.match(f"- {member}")
        if entry is None:
            return None
        parsed.append(("entry", entry.group("target"), member))
    return parsed


def parse_index_entries(index_text: str) -> dict[str, Any]:
    """Split MEMORY.md into its frontmatter, preamble lines, the archive pointer,
    one line per entry (hooked lines verbatim, packed members one per line), bare
    fragments, and every other line kept verbatim.

    Frontmatter and block HTML comments are invisible to the loader (the size
    accounting strips them), so nothing inside them is an entry. A line with any
    member of neither shape is left unsplit and verbatim: nothing is ever dropped
    or rewritten by guesswork, and a bare fragment on such a line is reported as
    remaining rather than silently hooked."""
    frontmatter, body = split_frontmatter_raw(index_text)
    preamble: list[str] = []
    other: list[str] = []
    unsplit: list[str] = []
    entries: dict[str, str] = {}
    fragments: list[str] = []
    pointer: tuple[str, str] | None = None
    seen_entry = False
    in_comment = False
    for line in body.splitlines(keepends=True):
        commented, in_comment = _comment_step(line, in_comment)
        if commented:
            (other if seen_entry else preamble).append(line)
            continue
        line_targets, _escaping = index_targets(line)
        if line_targets == {ARCHIVE_INDEX_NAME}:
            if pointer is None:
                match = ENTRY_LINE_RE.match(line)
                pointer = (match.group("text") if match else ARCHIVE_POINTER_TEXT, line)
            else:
                other.append(line)  # a second archive link is kept verbatim, never ranked
            seen_entry = True
            continue
        if not line_targets:
            (other if seen_entry else preamble).append(line)
            continue
        seen_entry = True
        members = split_index_members(line)
        if members is None:
            unsplit.append(line)
            other.append(line)
            continue
        for kind, rel, member in members:
            if rel in entries or rel in fragments:
                continue  # a duplicate member collapses into the first
            if kind == "fragment":
                fragments.append(rel)
            elif len(members) == 1:
                entries[rel] = line if line.endswith("\n") else line + "\n"  # a lone hooked line stays byte-identical
            else:
                entries[rel] = f"- {member}\n"  # a hooked member of a packed line, its text intact
    return {
        "frontmatter": frontmatter,
        "preamble": preamble,
        "pointer": pointer,
        "entries": entries,
        "fragments": fragments,
        "other": other,
        "unsplit": unsplit,
    }


def hook_index_fragments(text: str, memory_dir: Path) -> tuple[str, list[str], list[str]]:
    """Rewrite, in place, every packed line of bare fragments in `text` as hooked
    lines rendered from frontmatter (the archive tier carries its own packed
    lines, #1450). Every other line is untouched. Returns (text, hooked rels,
    hookless rels); a member already linked from an untouched line is dropped
    rather than duplicated."""
    lines = text.splitlines(keepends=True)
    packed: list[list[tuple[str, str, str]] | None] = []
    in_comment = False
    for line in lines:
        commented, in_comment = _comment_step(line, in_comment)
        members = None if commented or not BARE_FRAGMENT_RE.search(line) else split_index_members(line)
        packed.append(members if members and members[0][0] == "fragment" else None)
    seen: set[str] = set()
    for line, members in zip(lines, packed):
        if members is None:
            seen |= index_targets(line)[0]
    out: list[str] = []
    hooked: list[str] = []
    hookless: list[str] = []
    for line, members in zip(lines, packed):
        if members is None:
            out.append(line)
            continue
        for kind, rel, member in members:
            if rel in seen:
                continue
            seen.add(rel)
            if kind == "entry":
                out.append(f"- {member}\n")
                continue
            name, description = entry_fields(memory_dir / rel, rel)
            clipped = clip_description(description)
            (hooked if clipped else hookless).append(rel)
            out.append(index_entry_line(name, clipped, rel) + "\n")
    return "".join(out), hooked, hookless


def compute_rehook(
    project: str,
    memory_dir: Path,
    records: dict[str, dict[str, Any]],
    now: dt.date,
    forced: bool = False,
) -> dict[str, Any] | None:
    """The rehook plan for one project: None without a live MEMORY.md; a plan with
    `skipped` (and nothing to write) when a file cannot be read safely; otherwise
    a plan whose `changed` says whether apply would write anything. Work is only
    proposed when an index carries bare fragments (either tier) or MEMORY.md sits
    at or over the load budget; `forced` (an explicit --project) also lets a run
    that merely adds unindexed notes proceed."""
    index_path = memory_dir / "MEMORY.md"
    if not index_path.is_file() or index_path.is_symlink():
        return None
    summary: dict[str, Any] = {
        "bare_fragments": 0,
        "archive_bare_fragments": 0,
        "unindexed": 0,
        "before": {"lines": 0, "bytes": 0},
        "over_budget": False,
        "changed": False,
    }
    base = {"kind": "index_rehook", "project": project, "path": "MEMORY.md", "summary": summary, "changed": False}

    def skipped(reason: str) -> dict[str, Any]:
        summary["skipped"] = reason
        return {**base, "skipped": reason}

    try:
        raw_index = index_path.read_bytes()
    except OSError as error:
        return skipped(f"unreadable MEMORY.md: {error}")
    if not is_valid_utf8(raw_index):
        return skipped("MEMORY.md is not valid UTF-8; left untouched")
    index_text = raw_index.decode("utf-8")  # bytes, not read_text: CRLF stays CRLF
    archive_path = memory_dir / ARCHIVE_INDEX_NAME
    if archive_path.is_symlink() or (archive_path.exists() and not archive_path.is_file()):
        return skipped(f"{ARCHIVE_INDEX_NAME} is a symlink or not a regular file; left untouched")
    archive_exists = archive_path.is_file()
    archive_text = ""
    if archive_exists:
        try:
            raw_archive = archive_path.read_bytes()
        except OSError as error:
            return skipped(f"unreadable {ARCHIVE_INDEX_NAME}: {error}")
        if not is_valid_utf8(raw_archive):
            return skipped(f"{ARCHIVE_INDEX_NAME} is not valid UTF-8; left untouched")
        archive_text = raw_archive.decode("utf-8")
    archive_targets = (index_targets(archive_text)[0] - {ARCHIVE_INDEX_NAME}) if archive_text else set()
    main_targets, _escaping = index_targets(index_text)
    before_lines, before_bytes = effective_index_size(index_text)
    over_budget = before_lines >= REHOOK_MAIN_MAX_LINES or before_bytes >= REHOOK_MAIN_MAX_BYTES
    parsed = parse_index_entries(index_text)
    fragments = [rel for rel in parsed["fragments"] if rel != ARCHIVE_INDEX_NAME]
    archive_bare = len(BARE_FRAGMENT_RE.findall(archive_text))
    # Unlike the audit, notes listed only in the legacy MEMORY-archive.md count as
    # unindexed here; re-listing them is a harmless duplicate below the load cut.
    unindexed = sorted(
        rel for rel in records
        if rel not in main_targets and rel not in archive_targets and rel != ARCHIVE_INDEX_NAME
    )
    summary.update(
        {
            "bare_fragments": len(BARE_FRAGMENT_RE.findall(index_text)),
            "archive_bare_fragments": archive_bare,
            "unindexed": len(unindexed),
            "before": {"lines": before_lines, "bytes": before_bytes},
            "over_budget": over_budget,
        }
    )
    if not fragments and not over_budget and not archive_bare and not (forced and unindexed):
        return base

    lines_by_rel: dict[str, str] = {
        rel: line for rel, line in parsed["entries"].items() if rel != ARCHIVE_INDEX_NAME
    }
    dangling = [rel for rel in fragments if rel not in records]
    hookless: list[str] = []
    for rel in fragments + unindexed:
        if rel in lines_by_rel or rel not in records:
            continue
        name, description = entry_fields(memory_dir / rel, rel)
        clipped = clip_description(description)
        if not clipped:
            hookless.append(rel)
        lines_by_rel[rel] = index_entry_line(name, clipped, rel) + "\n"
    dead = sorted(rel for rel in lines_by_rel if rel not in records)
    ranked = sorted(lines_by_rel, key=lambda rel: rehook_rank_key(rel, records.get(rel)))
    pointer_text = parsed["pointer"][0] if parsed["pointer"] else ARCHIVE_POINTER_TEXT
    head = parsed["frontmatter"] + "".join(parsed["preamble"])
    other = "".join(parsed["other"])

    def pointer_for(moved: list[str]) -> str | None:
        archive_after = archive_targets | set(moved)
        if moved or (archive_exists and parsed["pointer"] is None):
            return archive_pointer_line(pointer_text, records, archive_after)
        return parsed["pointer"][1] if parsed["pointer"] else None

    def assemble(kept: list[str], pointer_line: str | None) -> str:
        text = head
        if pointer_line is not None:
            if text and not text.endswith("\n"):
                text += "\n"
            text += pointer_line
        text += other
        if text and not text.endswith("\n"):
            text += "\n"
        return text + "".join(lines_by_rel[rel] for rel in kept)

    def fits(text: str) -> bool:
        lines, size = effective_index_size(text)
        return lines < REHOOK_MAIN_MAX_LINES and size < REHOOK_MAIN_MAX_BYTES

    cut = len(ranked)
    for index, _rel in enumerate(ranked):
        if not fits(assemble(ranked[: index + 1], pointer_for(ranked[index + 1 :]))):
            cut = index
            break
    kept, moved = ranked[:cut], ranked[cut:]
    pointer_line = pointer_for(moved)
    main_text = assemble(kept, pointer_line)
    while kept and not fits(main_text):  # the regenerated pointer can grow by a few bytes
        moved.insert(0, kept.pop())
        pointer_line = pointer_for(moved)
        main_text = assemble(kept, pointer_line)

    appended = [rel for rel in moved if rel not in archive_targets]
    deduped = [rel for rel in moved if rel in archive_targets]
    new_archive, archive_hooked, archive_hookless = (
        hook_index_fragments(archive_text, memory_dir) if archive_text else ("", [], [])
    )
    if appended:
        if not archive_exists:
            new_archive = archive_seed()
        if not new_archive.endswith("\n"):
            new_archive += "\n"
        new_archive += f"\n## Moved out on {now.isoformat()} (rehook: ranked tier split under the load cap)\n"
        new_archive += "".join(lines_by_rel[rel] for rel in appended)
    after_lines, after_bytes = effective_index_size(main_text)
    bare_remaining = len(BARE_FRAGMENT_RE.findall(main_text))
    archive_changed = new_archive != archive_text
    changed = main_text != index_text or archive_changed
    summary.update(
        {
            "after": {"lines": after_lines, "bytes": after_bytes},
            "kept": len(kept),
            "moved": len(moved),
            "bare_remaining": bare_remaining,
            "archive_hooked": len(archive_hooked),
            "changed": changed,
        }
    )
    return {
        **base,
        "changed": changed,
        "fragments": fragments,
        "unindexed": unindexed,
        "dangling": dangling,
        "hookless": hookless + archive_hookless,
        "dead": dead,
        "unsplit": len(parsed["unsplit"]),
        "bare_remaining": bare_remaining,
        "kept": kept,
        "moved": moved,
        "archive_appended": appended,
        "archive_deduped": deduped,
        "archive_hooked": archive_hooked,
        "archive_created": bool(appended) and not archive_exists,
        "archive_changed": archive_changed,
        "pointer_line": pointer_line.rstrip("\r\n") if pointer_line else None,
        "main_text": main_text,
        "archive_text": new_archive,
    }


def write_preserving_mtime(path: Path, text: str) -> bool:
    """Atomic write that keeps an existing file's mtime (maintenance never resets
    the age signal, KTD3) and never writes through a symlink. Returns False when
    the content is already identical."""
    if path.is_symlink():
        raise OSError(f"refusing to write through a symlink: {path}")
    data = text.encode("utf-8")
    if path.is_file():
        if path.read_bytes() == data:
            return False
        stat = path.stat()
        atomic_write(path, data)
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        return True
    atomic_write(path, data)
    return True


def apply_rehook(live_root: Path, mirror_root: Path, plans: list[dict[str, Any]], hint: str = "") -> int:
    affected = sorted({plan["project"] for plan in plans})
    stale = mirror_freshness(live_root, mirror_root, affected)
    if stale:
        for project, kinds in sorted(stale.items()):
            print(
                f"memory-rehook: refusing to apply to {project}: mirror not fresh ({', '.join(kinds)})"
                + (f"; {hint}" if hint else ""),
                file=sys.stderr,
            )
        return 1
    live = project_dirs(live_root, live=True)
    exit_code = 0
    for plan in plans:
        memory_dir = live[plan["project"]]
        try:
            # Archive first: a failure between the two writes then leaves a moved
            # entry in both tiers, which dedup tolerates, never in neither.
            if plan["archive_changed"]:
                write_preserving_mtime(memory_dir / ARCHIVE_INDEX_NAME, plan["archive_text"])
            write_preserving_mtime(memory_dir / "MEMORY.md", plan["main_text"])
        except OSError as error:
            print(f"memory-rehook: {plan['project']}: write failed: {error}", file=sys.stderr)
            exit_code = 1
    return exit_code


def public_plan(plan: dict[str, Any]) -> dict[str, Any]:
    """The plan without the full file texts (the preview names entries, not bodies)."""
    return {key: value for key, value in plan.items() if key not in ("main_text", "archive_text")}


def run_rehook(args: argparse.Namespace) -> int:
    live_root = Path(args.live_root).expanduser()
    if not live_root.is_dir():
        print(f"memory-rehook: live root is not a directory: {live_root}", file=sys.stderr)
        return 2
    if args.apply and not (args.project or args.all):
        print("memory-rehook: --apply needs --project NAME or --all (a write touches every qualifying index)", file=sys.stderr)
        return 2
    now = args.now or dt.date.today()
    live = project_dirs(live_root, live=True)
    try:
        require_floor(len(live), 1, "memory rehook live projects")
    except FloorNotMet as error:
        print(error, file=sys.stderr)
        return 2
    projects: dict[str, dict[str, Any]] = {}
    skipped: dict[str, str] = {}
    plans: list[dict[str, Any]] = []
    for project in sorted(live):
        if args.project and project != args.project:
            continue
        memory_dir = live[project]
        if memory_dir.is_symlink() or memory_dir.parent.is_symlink():
            continue
        plan = compute_rehook(project, memory_dir, scan_project_notes(memory_dir), now, forced=bool(args.project))
        if plan is None:
            continue
        projects[project] = plan["summary"]
        if plan.get("skipped"):
            skipped[project] = plan["skipped"]
        elif plan["changed"]:
            plans.append(plan)
    if args.project and not projects:
        print(f"memory-rehook: no live MEMORY.md for project {args.project}", file=sys.stderr)
        return 2
    exit_code = 0
    if args.apply and plans:
        hint = PUSHED_MIRROR_HINT if args.mirror_root is None else ""
        exit_code = apply_rehook(live_root, mirror_root_path(args.mirror_root), plans, hint)
    result = {
        "schema_version": 1,
        "command": "rehook",
        "applied": bool(args.apply and plans and exit_code == 0),
        "roots": {"live": str(live_root), "mirror": mirror_root_label(args.mirror_root)},
        "now": now.isoformat(),
        "budget": {"lines": REHOOK_MAIN_MAX_LINES, "bytes": REHOOK_MAIN_MAX_BYTES},
        "summary": {
            "indexes_scanned": len(projects),
            "changes": len(plans),
            "skipped": skipped,
            "projects": projects,
        },
        "plans": [public_plan(plan) for plan in plans],
    }
    if args.format == "json":
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    else:
        print(render_rehook_human(result))
    return exit_code


def render_rehook_human(result: dict[str, Any]) -> str:
    state = "applied" if result["applied"] else "proposed (dry-run)"
    summary = result["summary"]
    budget = result["budget"]
    lines = [
        f"memory-rehook: {summary['changes']} of {summary['indexes_scanned']} live index(es) need work, {state}"
    ]
    for plan in result["plans"]:
        item = plan["summary"]
        before, after = item["before"], item["after"]
        flag = " (over budget)" if item["over_budget"] else ""
        lines.append(
            f"  {plan['project']}: {item['bare_fragments']} bare fragment(s), {item['unindexed']} unindexed note(s), "
            f"MEMORY.md {before['lines']}/{budget['lines']} lines {before['bytes']}/{budget['bytes']} bytes{flag}"
        )
        lines.append(
            f"    -> keep {item['kept']} entries in MEMORY.md ({after['lines']} lines / {after['bytes']} bytes), "
            f"move {item['moved']} to {ARCHIVE_INDEX_NAME} "
            f"({len(plan['archive_appended'])} appended, {len(plan['archive_deduped'])} already there"
            f"{', file created' if plan['archive_created'] else ''})"
            f"{'; ' + str(len(plan['archive_hooked'])) + ' bare fragment(s) in the archive hooked in place' if plan['archive_hooked'] else ''}"
        )
        extras = [
            f"{label} {len(plan[key]) if isinstance(plan[key], list) else plan[key]}"
            for key, label in (
                ("dangling", "dangling"),
                ("hookless", "hookless"),
                ("dead", "dead"),
                ("unsplit", "unsplit line(s)"),
                ("bare_remaining", "bare fragment(s) left on unsplit lines"),
            )
            if (len(plan[key]) if isinstance(plan[key], list) else plan[key])
        ]
        if extras:
            lines.append("    " + ", ".join(extras))
        if plan["pointer_line"]:
            lines.append(f"    pointer: {plan['pointer_line']}")
    for project, reason in sorted(summary.get("skipped", {}).items()):
        lines.append(f"  skipped {project}: {reason}")
    lines.append(f"changes:{summary['changes']}")
    return "\n".join(lines)


def date_value(value: str) -> dt.date:
    try:
        return dt.date.fromisoformat(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD") from error


def common_parser(subcommand: bool = False) -> argparse.ArgumentParser:
    # A subparser copies its own defaults over the parent namespace, so a flag given
    # before the subcommand (`--live-root X rehook --apply`) would silently fall back
    # to the real store. Subcommand copies set a value only when the flag is written.
    # An unset mirror root stays None and means PUSHED_MIRROR_REF (mirror_root_path).
    def default(value: str) -> str:
        return argparse.SUPPRESS if subcommand else value

    result = argparse.ArgumentParser(add_help=False)
    result.add_argument("--live-root", default=default(os.environ.get("CLAUDE_MEMORY_LIVE_ROOT", "~/.claude/projects")))
    result.add_argument("--mirror-root", default=default(os.environ.get("CLAUDE_MEMORY_MIRROR_ROOT")))
    result.add_argument("--format", choices=("human", "json"), default=default("human"))
    return result


def parser() -> argparse.ArgumentParser:
    common = common_parser()
    sub_common = common_parser(subcommand=True)
    # The bare (no-subcommand) invocation stays the full audit for back-compat:
    # sync.sh and the existing test suite call `memory-audit.py [flags]` directly.
    result = argparse.ArgumentParser(description=__doc__, parents=[common])
    result.add_argument("--as-of", type=date_value, help="inject YYYY-MM-DD for deterministic stale-date review")
    result.add_argument("--stale-days", type=int, default=90)
    result.add_argument("--max-index-bytes", type=int, default=32768)
    result.add_argument("--max-index-lines", type=int, default=400)
    result.add_argument(
        "--scan-content",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="scan bodies for high-signal credential signatures (default: enabled)",
    )
    result.add_argument(
        "--sensitive-exit",
        action="store_true",
        help="exit 1 only when a sensitive indicator is present",
    )
    result.add_argument(
        "--filename-allowlist",
        default=None,
        help="paths whose name is reviewed-safe, one per line (default: memory-filename-allowlist.txt"
        " in the overlay directory, HOV_STACK_OVERLAY or ~/.config/hov-stack, when it exists, else"
        " the tracked copy, which ships no entries)",
    )
    result.add_argument(
        "--copy-gate",
        action="store_true",
        help="emit the per-file copy verdict as JSON and exit 1 only on a whole-push blocker",
    )
    result.add_argument(
        "--enforcer-repo",
        default=str(ENFORCER_REPO_DEFAULT),
        help="checkout whose project's feedback notes must cite existing repo paths and scripts (default: the checkout holding this script; a linked worktree resolves to its main checkout)",
    )
    result.add_argument(
        "--other-repo",
        action="append",
        default=[],
        metavar="NAME",
        help="repository name whose paragraphs the cited-enforcer check skips (repeatable)",
    )
    result.add_argument(
        "--repo-root",
        action="append",
        default=[],
        metavar="DIR",
        help=f"directory of checkouts; those with a live memory project are repository names next to issue refs (default: {' '.join(ENFORCER_REPO_ROOTS_DEFAULT)})",
    )
    result.add_argument(
        "--enforcer-extra-root",
        action="append",
        default=[],
        metavar="DIR",
        help=f"extra tree whose files count as existing enforcers (default: {' '.join(ENFORCER_EXTRA_ROOTS_DEFAULT)})",
    )
    sub = result.add_subparsers(dest="command")
    triage = sub.add_parser(
        "triage", parents=[sub_common], help="score live notes for the dream pass (read-only)"
    )
    triage.add_argument("--now", type=date_value, default=None, help="inject YYYY-MM-DD for deterministic age scoring")
    triage.add_argument("--suppress-applied-days", type=int, default=14, help="drop flags on notes an applied dream pass touched within N days (0 disables)")
    fix = sub.add_parser("fix", parents=[sub_common], help="mechanical repairs (dry-run unless --apply)")
    fix.add_argument("--apply", action="store_true", help="write repairs to live memory (gated on mirror freshness)")
    rehook = sub.add_parser(
        "rehook",
        parents=[sub_common],
        help="hook bare MEMORY.md fragments and split the index by rank under the load cap (dry-run unless --apply)",
    )
    rehook.add_argument("--apply", action="store_true", help="write MEMORY.md and the archive tier in live memory (gated on mirror freshness)")
    rehook.add_argument("--project", default=None, help="one project only; also lets a run that merely adds unindexed notes proceed")
    rehook.add_argument("--now", type=date_value, default=None, help="inject YYYY-MM-DD for the archive section heading")
    rehook.add_argument("--all", action="store_true", help="with --apply: write every live project whose index needs work (default: --apply needs --project)")
    return result


def main() -> int:
    args = parser().parse_args()
    command = getattr(args, "command", None)
    if command == "triage":
        return run_triage(args)
    if command == "fix":
        return run_fix(args)
    if command == "rehook":
        return run_rehook(args)
    try:
        result = audit(args)
    except OSError as error:
        print(f"memory-audit: unable to read audit roots: {error}", file=sys.stderr)
        return 2
    try:
        require_floor(result["summary"]["live_projects"], 1, "memory audit live projects")
    except FloorNotMet as error:
        print(error, file=sys.stderr)
        return 2
    if args.copy_gate:
        # Machine mode for sync.sh: the verdict is the only thing on stdout.
        gate = copy_gate(result)
        print(json.dumps(gate, sort_keys=True, separators=(",", ":")))
        return 1 if gate["blocked"] else 0
    if args.format == "json":
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    else:
        print(render_human(result))
    if args.sensitive_exit:
        return int(
            any(
                item["kind"].startswith("sensitive_") or item["kind"] == "live_symlink"
                for item in result["findings"]
            )
        )
    return 1 if result["summary"]["blocking_findings"] else 0


if __name__ == "__main__":
    raise SystemExit(main())

