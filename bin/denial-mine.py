#!/usr/bin/env python3
"""denial-mine.py — mine Claude Code transcripts for denied tool calls.

Ceremony Test (HARNESS.md § Doctrine):
  consumer    — /denial-triage (operator, monthly + after guard/permission changes);
                agents via --json.
  gate        — none: report-only. Any settings.json change it motivates goes
                through the ask-gated update-config path, never applied here.
  defect      — OBSERVED (dotfiles#210): 1,117 denial events in 14 days of
                transcripts; papercut captures first-party guard denials only, so
                settings-rule denials, user prompt-rejections, and automode blocks
                had zero capture anywhere.
  delete-when — Claude Code ships native denial analytics, or papercut grows
                prompt-denial capture.

Sources of a denial and where each is ALREADY counted (skip here by default):
  git-guard / codex-quota / codex-doghouse (historical) / runner-guard
                                             -> papercut (guard_blocked:<name>)
  dcg                                        -> nowhere (third-party hook, papercut
                                                deliberately does not wrap it)
  settings-rule / user-rejected / automode   -> nowhere (this tool's reason to exist)

Transcripts nest to depth 7 under ~/.claude/projects (subagent workflow dirs), so
enumeration walks; a fixed-depth glob undercounts by ~78% (measured 2026-08-06).

The `toolDenialKind` field is internal Claude Code transcript format (observed in
CLI 2.1.217-2.1.220), not a published API. When a scan finds zero of them, the
prose fallback (--no-fallback disables) matches known deny-message shapes so a
field rename degrades to a noisier report instead of a silent zero.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

KEPT_KINDS = {"permission-rule", "user-rejected", "automode-blocked"}
# "interrupted" is a cancel, not a policy signal: no reason payload to classify.

PAPERCUT_COVERED = {
    "git-guard",
    "codex-quota-guard",
    "codex-doghouse",  # historical transcript classification
    "runner-guard",
}

FALLBACK_MARKERS = (
    "has been denied.",
    "The user doesn't want to proceed",
    "BLOCKED by dcg",
)

BUCKETS = ("should-allow", "should-deny-fast", "sandbox-only", "behavioral", "review")
# Buckets a config change can actually address. `behavioral` clusters (guards
# coaching intent) recur forever by design — counting them in the weekly toast
# would train the operator to ignore it, so only these drive denials-flagged:N.
ACTIONABLE_BUCKETS = frozenset({"should-allow", "should-deny-fast", "sandbox-only"})


@dataclass
class Denial:
    kind: str
    source: str
    tool: str
    head: str          # normalized first line of the command / input
    message: str       # truncated deny text
    session: str       # transcript file stem = session identity
    project: str       # project slug (first dir under the transcript root)
    mtime: float


@dataclass
class Cluster:
    source: str
    tool: str
    head: str
    sessions: set[str] = field(default_factory=set)
    count: int = 0
    example: str = ""
    bucket: str = "review"
    # Provenance: without it a sandbox experiment reads as organic friction
    # (first pass: 24 "sessions" of git-remote-v denials were one ablation
    # sweep). dict slug -> event count; judgment reads concentration.
    projects: dict = field(default_factory=dict)
    # A live allow rule already covering this head means the denial came from
    # ANOTHER scope (project settings / don't-ask) — a global allow rule is
    # the wrong fix by construction. Set by annotate_already_allowed().
    already_allowed: str = ""


def classify_source(kind: str, text: str) -> str:
    if kind == "user-rejected":
        return "user-rejected"
    if kind == "automode-blocked":
        return "automode"
    if "BLOCKED by dcg" in text:
        return "dcg"
    if ("ALLOW_DESTRUCTIVE_GIT" in text or "ALLOW_MAIN_COMMIT" in text
            or text.startswith("Blocked:") or "Use specific file paths instead" in text):
        return "git-guard"
    if "Codex quota is explicitly unavailable" in text:
        return "codex-quota-guard"
    if "circuit breaker" in text:
        return "codex-doghouse"
    if "runner-guard" in text or "kill target" in text:
        return "runner-guard"
    if "don't ask mode" in text:
        # Refused only because the session ran unattended — a MODE outcome,
        # not a rule match. Fix menu differs (per-repo grant / mode change /
        # accept fallback), so it must not masquerade as settings-rule.
        return "mode-denial"
    return "settings-rule"


def propose_bucket(c: Cluster) -> str:
    """Conservative heuristics; every proposal is a starting point for review."""
    readonly = re.match(
        r"^(ls|cat|head|tail|grep|rg|find|git (status|log|diff|show|branch)|gh (pr|issue|api) (list|view|status))\b",
        c.head,
    )
    if c.source == "settings-rule" and readonly:
        return "should-allow"
    if "sandbox" in c.example.lower() or "additionalDirectories" in c.example:
        return "sandbox-only"
    if c.source in ("dcg", "git-guard") :
        return "behavioral"          # guards coach ("use specific paths"); config cannot fix intent
    if c.source == "mode-denial":
        # Never auto-flags: the Workflow gate is a recorded standing decision
        # (HARNESS.md), and a mode outcome alone never justifies a global allow.
        return "review"
    if (c.source == "user-rejected" and len(c.sessions) >= 3
            and not c.head.startswith(("User rejected", "Error:"))):
        # Repeatedly hand-denied WITH a recoverable command: make the no
        # automatic. A recoverable command never starts with "Error:" — heads
        # that do are deny/prompt PROSE ("Review dynamic workflow...", "This
        # command requires approval"), and the second pass (2026-08-07) showed
        # them slipping a narrower two-prefix filter and flagging 4 phantom
        # deny-rule proposals, including the operator's own Workflow vetoes.
        return "should-deny-fast"
    return "review"


def normalize_head(text: str) -> str:
    head = text.strip().splitlines()[0][:120] if text.strip() else "(empty)"
    head = re.sub(r"/home/\w+", "~", head)
    head = re.sub(r"\d{4,}", "N", head)
    return head


# Experiment sandboxes masquerade as organic sessions: an ablation sweep running
# agents inside ~/.claude/jobs/<id>/tmp/... produces one project slug PER RUN
# (observed 2026-08-07: 24 "sessions" of `git remote -v` denials were one sweep
# testing restricted permissions on purpose). Their slugs embed the job-tmp path.
SYNTHETIC_SLUG_RE = re.compile(r"-claude-jobs-[0-9a-f]+-tmp-")


def iter_transcripts(root: Path, days: int, include_synthetic: bool = False):
    cutoff = time.time() - days * 86400
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if not name.endswith(".jsonl"):
                continue
            p = Path(dirpath) / name
            if not include_synthetic:
                try:
                    slug = p.relative_to(root).parts[0]
                except ValueError:
                    slug = ""
                if SYNTHETIC_SLUG_RE.search(slug):
                    continue
            try:
                if p.stat().st_mtime >= cutoff:
                    yield p
            except OSError:
                continue


def extract(path: Path, fallback: bool, project: str = "") -> list[Denial]:
    out: list[Denial] = []
    try:
        with open(path, errors="ignore") as fh:
            for line in fh:
                # Quote-wrapped key only: separator-agnostic (live CLI writes
                # compact `":"`, pretty-printers write `": "` — both must hit).
                marker = '"toolDenialKind"' in line
                if not marker and not (fallback and any(m in line for m in FALLBACK_MARKERS)):
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                out.extend(record_denials(rec, path, marker, project))
    except OSError:
        pass
    return out


# Live records (CLI 2.1.217-2.1.220) carry no toolName/toolInput beside the
# denial; the denied tool and command exist only inside the deny prose.
PERM_RE = re.compile(r"Permission to use (\w+)(?: with command (.+?))? has been denied", re.S)
DCG_CMD_RE = re.compile(r"^Command: (.+)$", re.M)
# dcg denials cluster by RULE, not by the command's first line — a heredoc
# prelude (`cd ...`, `set -e`) scatters one rule across dozens of clusters.
DCG_RULE_RE = re.compile(r"^Rule: (\S+)$", re.M)
# A pattern with no rule id (our config.toml custom patterns, dcg's embedded-code
# and parse-failure refusals) prints only a Reason: line. Without it they shared
# one "BLOCKED by dcg" cluster: 285 events in the 30 days to 2026-10-17, 74 of
# them a single chmod -R false positive that #1829 fixed, invisible as such.
DCG_REASON_RE = re.compile(r"^Reason: (.+)$", re.M)


def record_denials(rec: dict, path: Path, has_field: bool, project: str = "") -> list[Denial]:
    found: list[Denial] = []

    def walk(node):
        if isinstance(node, dict):
            kind = node.get("toolDenialKind")
            if kind in KEPT_KINDS or (not has_field and _fallback_hit(node)):
                text = _text_of(node)
                perm = PERM_RE.search(text)
                dcg_cmd = DCG_CMD_RE.search(text)
                tool = (node.get("toolName") or node.get("name")
                        or (perm.group(1) if perm else None)
                        or ("Bash" if dcg_cmd else "?"))
                dcg_rule = DCG_RULE_RE.search(text)
                dcg_reason = DCG_REASON_RE.search(text) if "BLOCKED by dcg" in text else None
                cmd = ((f"rule {dcg_rule.group(1)}" if dcg_rule else "")
                       or (f"reason {dcg_reason.group(1)}" if dcg_reason else "")
                       or _input_of(node)
                       or (perm.group(2) if perm and perm.group(2) else "")
                       or (dcg_cmd.group(1) if dcg_cmd else ""))
                found.append(
                    Denial(
                        kind=kind or "fallback",
                        source=classify_source(kind or "", text),
                        tool=str(tool),
                        head=normalize_head(cmd or text),
                        message=text[:300],
                        session=str(rec.get("sessionId") or rec.get("session_id") or path.stem),
                        project=project,
                        mtime=path.stat().st_mtime,
                    )
                )
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(rec)
    return found


def _fallback_hit(node: dict) -> bool:
    content = node.get("content")
    return isinstance(content, str) and any(m in content for m in FALLBACK_MARKERS)


def _text_of(node: dict) -> str:
    for key in ("toolUseResult", "content", "reason", "message", "text"):
        v = node.get(key)
        if isinstance(v, str) and v:
            return v
        if isinstance(v, list):
            parts = [b.get("text", "") for b in v if isinstance(b, dict)]
            if any(parts):
                return "\n".join(parts)
    return ""


def _input_of(node: dict) -> str:
    v = node.get("toolInput") or node.get("input")
    if isinstance(v, dict):
        return str(v.get("command") or v.get("file_path") or json.dumps(v)[:120])
    return str(v) if v else ""


def annotate_already_allowed(clusters, settings_path: Path) -> None:
    """Mark clusters a live allow rule already covers: the denial then came from
    another scope (project settings / don't-ask), and proposing a global allow
    would be the wrong fix. Report-only; reads the settings file, writes nothing."""
    try:
        allow = json.load(open(settings_path)).get("permissions", {}).get("allow", [])
    except (OSError, json.JSONDecodeError):
        return
    bash_prefixes = []   # ("git remote", "Bash(git remote:*)")
    tool_names = set()   # bare tool rules like "Workflow"
    for rule in allow:
        m = re.match(r"^Bash\((.+?):?\*?\)$", rule)
        if m:
            bash_prefixes.append((m.group(1).rstrip(":"), rule))
        elif re.match(r"^\w+$", rule):
            tool_names.add(rule)
    for c in clusters:
        if c.tool in tool_names:
            c.already_allowed = c.tool
        elif c.tool == "Bash":
            for prefix, rule in bash_prefixes:
                if c.head.startswith(prefix):
                    c.already_allowed = rule
                    break


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--root", type=Path, default=Path.home() / ".claude" / "projects")
    ap.add_argument("--json", action="store_true", help="machine-readable clusters")
    ap.add_argument("--include-papercut-covered", action="store_true",
                    help="also show git-guard/codex-quota/historical-doghouse/runner-guard (papercut already ranks these)")
    ap.add_argument("--no-fallback", action="store_true",
                    help="disable prose-marker fallback when toolDenialKind yields zero")
    ap.add_argument("--digest", action="store_true",
                    help="compact weekly summary + trailing denials-flagged:N (harness-weekly)")
    ap.add_argument("--include-synthetic", action="store_true",
                    help="include experiment-sandbox transcripts (jobs/<id>/tmp run dirs)")
    ap.add_argument("--settings", type=Path, default=Path.home() / ".claude" / "settings.json",
                    help="settings.json for already-allowed scope-conflict annotation")
    ap.add_argument("--flag-sessions", type=int, default=3,
                    help="digest: min distinct sessions for an actionable cluster to flag")
    args = ap.parse_args()

    def _slug(p: Path) -> str:
        try:
            return p.relative_to(args.root).parts[0]
        except (ValueError, IndexError):
            return "?"

    denials: list[Denial] = []
    files = 0
    for path in iter_transcripts(args.root, args.days, args.include_synthetic):
        files += 1
        denials.extend(extract(path, fallback=False, project=_slug(path)))
    if not denials and not args.no_fallback:
        for path in iter_transcripts(args.root, args.days, args.include_synthetic):
            denials.extend(extract(path, fallback=True, project=_slug(path)))

    if not args.include_papercut_covered:
        denials = [d for d in denials if d.source not in PAPERCUT_COVERED]

    clusters: dict[tuple, Cluster] = {}
    for d in denials:
        key = (d.source, d.tool, d.head)
        c = clusters.setdefault(key, Cluster(source=d.source, tool=d.tool, head=d.head))
        c.count += 1
        c.sessions.add(d.session)
        c.projects[d.project] = c.projects.get(d.project, 0) + 1
        if not c.example:
            c.example = d.message
    for c in clusters.values():
        c.bucket = propose_bucket(c)
    annotate_already_allowed(clusters.values(), args.settings)

    # papercut convention: rank by DISTINCT SESSIONS — repetition across sessions
    # is the priority signal, within-session retries are not.
    ranked = sorted(clusters.values(), key=lambda c: (-len(c.sessions), -c.count))

    if args.digest:
        # harness-weekly section body. Top clusters stay visible for week-over-week
        # decay reading; only actionable ones (see ACTIONABLE_BUCKETS) trip the
        # trailing counter that harness-weekly greps into the toast gate.
        flagged = [c for c in ranked
                   if c.bucket in ACTIONABLE_BUCKETS and len(c.sessions) >= args.flag_sessions]
        print(f"denials last {args.days}d: {len(denials)} events, {len(ranked)} clusters "
              f"({files} transcripts; papercut-covered excluded)")
        for c in ranked[:5]:
            print(f"  [{len(c.sessions):>3}s/{c.count:>4}e] {c.bucket:<16} {c.source}: {c.head[:80]}")
        for c in flagged:
            print(f"WARN actionable denial cluster: {c.bucket} {c.source}: {c.head[:80]} "
                  f"({len(c.sessions)} sessions) — run /denial-triage")
        print(f"denials-flagged:{len(flagged)}")
        return 0

    if args.json:
        print(json.dumps({
            "days": args.days, "files_scanned": files, "events": len(denials),
            "clusters": [{
                "source": c.source, "tool": c.tool, "head": c.head,
                "sessions": len(c.sessions), "events": c.count,
                "proposed_bucket": c.bucket, "example": c.example,
                "projects": dict(sorted(c.projects.items(), key=lambda kv: -kv[1])[:3]),
                "already_allowed": c.already_allowed,
            } for c in ranked],
        }, indent=1))
        return 0

    print(f"denial-mine: {len(denials)} events in {len(ranked)} clusters "
          f"({files} transcripts, last {args.days}d; papercut-covered "
          f"{'included' if args.include_papercut_covered else 'excluded'})\n")
    for c in ranked[:40]:
        notes = []
        top = max(c.projects.items(), key=lambda kv: kv[1], default=("", 0))
        if c.count and top[1] / c.count >= 0.6 and len(c.projects) <= 3:
            notes.append(f"mostly {top[0]}")
        if c.already_allowed:
            notes.append(f"already allowed by {c.already_allowed} — denial came from another scope")
        suffix = f"  [{'; '.join(notes)}]" if notes else ""
        print(f"[{len(c.sessions):>3} sessions / {c.count:>4} events] {c.bucket:<15} "
              f"{c.source}:{c.tool}\n    {c.head}{suffix}")
    if len(ranked) > 40:
        print(f"\n... {len(ranked) - 40} more clusters (use --json for all)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
