#!/usr/bin/env python3
"""Head-to-head eval: Claude Code auto-memory (stock store + custom tooling) vs
cass-memory (cm) on the same session-derived ground truth.

Sibling of memory-recall-eval.py and reuses its discipline:
  * Ground truth is CONTENT-ANCHORED: every question carries a verbatim
    answer_snippet mined from a real session; `freeze` verifies the snippet
    against the session source byte-for-byte (normalized), so fabricated
    questions are rejected deterministically.
  * The suite is FROZEN once and scored repeatedly.
  * Deterministic plumbing lives here; LLM stages (question mining, routing,
    semantic judging) are dispatched as subagents and validated here.

Fairness design: questions are mined from SESSION LOGS (the shared corpus both
systems claim to capture), never from either system's store. Each system is
scored on what its real retrieval path returns:
  * current system: a routing judge sees ONLY the repo store's MEMORY.md index
    lines (that is how recall actually works) and picks up to 3 notes; retrieved
    text = those note bodies.
  * cm: retrieved text = `cm context "<question>" --json` output.

Metrics per system: strict (normalized snippet containment in retrieved text),
semantic (majority of judge verdicts), and retrieved-context size (chars).

Commands:
  freeze    --candidates F --out suite.json [--min-per-repo N]
  collect-cm --suite suite.json --out F      (runs `cm context` per question)
  routing-inputs --suite suite.json --out F  (emits judge inputs per question)
  score     --suite S --cm F --routing F --semantic F --out report.json
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

SUITE_SCHEMA_VERSION = 1


def load_sibling(filename: str, module_name: str) -> Any:
    path = Path(__file__).resolve().parent / filename
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


RECALL = load_sibling("memory-recall-eval.py", "memory_recall_eval")
AUDIT = load_sibling("memory-audit.py", "memory_audit")


# Configure stores explicitly, including staged stores for scoring without live writes:
# FACEOFF_STORES='{"acme-app": "/path/to/memory", "acme-evals": "/other/memory"}'
try:
    _stores = json.loads(os.environ.get("FACEOFF_STORES") or "{}")
    if (
        not isinstance(_stores, dict)
        or not _stores
        or any(
            not isinstance(k, str) or not k or not isinstance(v, str) or not v
            for k, v in _stores.items()
        )
    ):
        raise ValueError("expected a non-empty JSON object of name -> memory dir")
except (ValueError, TypeError) as exc:
    print(
        f"ERROR: FACEOFF_STORES must be a non-empty JSON object of name -> memory dir "
        f'(e.g. {{"acme-app": "/path/to/memory"}}): {exc}',
        file=sys.stderr,
    )
    sys.exit(1)
STORES = {k: Path(v) for k, v in _stores.items()}


def contains(haystack: str, needle: str) -> bool:
    return RECALL.normalize(needle) in RECALL.normalize(haystack)


def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def read_source_text(cand: dict) -> str:
    """Session text for anchor verification: raw jsonl path first (exact),
    `cass read` as fallback."""
    p = cand.get("source_path")
    if p and Path(p).expanduser().exists():
        return Path(p).expanduser().read_text(errors="replace")
    cid = cand.get("conversation_id")
    if cid:
        try:
            out = subprocess.run(
                ["cass", "read", str(cid)], capture_output=True, text=True, timeout=60
            )
            if out.returncode == 0 and out.stdout:
                return out.stdout
        except Exception:
            pass
    return ""


def cmd_freeze(args: argparse.Namespace) -> None:
    cands = json.loads(Path(args.candidates).read_text())
    if isinstance(cands, dict):
        cands = cands.get("candidates", [])
    kept, rejected = [], []
    seen_snippets: set[str] = set()
    for c in cands:
        q, snip, repo = c.get("question", ""), c.get("answer_snippet", ""), c.get("repo", "")
        reason = None
        if repo not in STORES:
            reason = f"unknown repo {repo!r}"
        elif not (RECALL.SNIPPET_MIN_CHARS <= len(snip) <= RECALL.SNIPPET_MAX_CHARS):
            reason = f"snippet length {len(snip)}"
        elif len(q) < 15 or not q.endswith("?"):
            reason = "malformed question"
        elif RECALL.normalize(snip) in seen_snippets:
            reason = "duplicate snippet"
        else:
            src = read_source_text(c)
            if not src:
                reason = "source unreadable"
            elif not contains(src, snip):
                reason = "snippet NOT in source (fabricated?)"
        if reason:
            rejected.append({"question": q[:80], "reason": reason})
        else:
            seen_snippets.add(RECALL.normalize(snip))
            kept.append(
                {
                    "id": f"q{len(kept)+1:03d}",
                    "repo": repo,
                    "question": q,
                    "answer_snippet": snip,
                    "conversation_id": c.get("conversation_id"),
                    "source_path": c.get("source_path"),
                }
            )
    per_repo = {r: sum(1 for k in kept if k["repo"] == r) for r in STORES}
    for r, n in per_repo.items():
        if n < args.min_per_repo:
            print(f"WARN: only {n} anchored questions for {r} (want >= {args.min_per_repo})")
    suite = {
        "schema_version": SUITE_SCHEMA_VERSION,
        "questions": kept,
        "rejected": rejected,
        "per_repo": per_repo,
    }
    Path(args.out).write_text(json.dumps(suite, indent=2))
    print(f"frozen: {len(kept)} questions ({per_repo}); rejected {len(rejected)}")
    for r in rejected:
        print(f"  reject: {r['reason']:38s} {r['question']}")


def cmd_collect_cm(args: argparse.Namespace) -> None:
    suite = json.loads(Path(args.suite).read_text())
    out = {}
    for q in suite["questions"]:
        try:
            r = subprocess.run(
                ["cm", "context", q["question"], "--json"],
                capture_output=True, text=True, timeout=args.timeout,
            )
            payload = r.stdout
            try:
                data = json.loads(payload)
                text = json.dumps(data.get("data", data))
            except json.JSONDecodeError:
                text = payload
            out[q["id"]] = {"ok": r.returncode == 0, "text": text, "chars": len(text)}
        except (subprocess.TimeoutExpired, OSError) as e:
            # cm not installed / crashed / hung: record the failure and keep going
            # rather than aborting the whole collection run over one bad question.
            out[q["id"]] = {"ok": False, "text": "", "chars": 0, "error": str(e)}
        print(f"  {q['id']}: {'ok' if out[q['id']]['ok'] else 'FAIL'} ({out[q['id']]['chars']} chars)")
        # Persist after every question so a late crash (or Ctrl-C) keeps the
        # results collected so far instead of losing the whole run.
        Path(args.out).write_text(json.dumps(out, indent=2))


def cmd_routing_inputs(args: argparse.Namespace) -> None:
    """Judge inputs: per question, the target repo store's MEMORY.md lines.
    The routing subagent must pick up to 3 note filenames using ONLY the index.

    Truncated to the same loaded surface (200 lines / 25600 bytes,
    AUDIT.loaded_index_text) a real Claude Code session actually loads —
    otherwise the judge can route successfully on over-cap entries that are
    invisible in production, inflating the current-system score (pro-gate-145
    #5)."""
    suite = json.loads(Path(args.suite).read_text())
    tasks = []
    for q in suite["questions"]:
        raw_index = (STORES[q["repo"]] / "MEMORY.md").read_text(errors="replace")
        index = AUDIT.loaded_index_text(raw_index)
        tasks.append({"id": q["id"], "question": q["question"], "index": index})
    Path(args.out).write_text(json.dumps({"tasks": tasks}, indent=2))
    print(f"routing inputs: {len(tasks)}")


def note_bodies(repo: str, filenames: list[str]) -> str:
    store = STORES[repo]
    texts = []
    for fn in filenames[:3]:
        fp = store / Path(fn).name
        if fp.exists() and fp.suffix == ".md" and fp.name != "MEMORY.md":
            texts.append(fp.read_text(errors="replace"))
    return "\n\n".join(texts)


def cmd_score(args: argparse.Namespace) -> None:
    suite = json.loads(Path(args.suite).read_text())
    cm_resp = json.loads(Path(args.cm).read_text())
    routing = json.loads(Path(args.routing).read_text())  # {qid: [filenames]}
    semantic = (
        json.loads(Path(args.semantic).read_text()) if args.semantic else {}
    )  # {qid: {"current": bool, "cm": bool}}
    rows = []
    for q in suite["questions"]:
        qid = q["id"]
        cur_text = note_bodies(q["repo"], routing.get(qid, []))
        cmr = cm_resp.get(qid, {})
        row = {
            "id": qid,
            "repo": q["repo"],
            "current_strict": contains(cur_text, q["answer_snippet"]),
            "cm_strict": contains(cmr.get("text", ""), q["answer_snippet"]),
            "current_chars": len(cur_text),
            "cm_chars": cmr.get("chars", 0),
            "current_semantic": semantic.get(qid, {}).get("current"),
            "cm_semantic": semantic.get(qid, {}).get("cm"),
        }
        rows.append(row)

    def pct(key: str) -> float:
        vals = [r[key] for r in rows if r[key] is not None]
        return round(100 * sum(bool(v) for v in vals) / len(vals), 1) if vals else float("nan")

    report = {
        "n": len(rows),
        "current": {"strict_pct": pct("current_strict"), "semantic_pct": pct("current_semantic"),
                    "median_chars": sorted(r["current_chars"] for r in rows)[len(rows) // 2] if rows else 0},
        "cm": {"strict_pct": pct("cm_strict"), "semantic_pct": pct("cm_semantic"),
               "median_chars": sorted(r["cm_chars"] for r in rows)[len(rows) // 2] if rows else 0},
        "rows": rows,
    }
    Path(args.out).write_text(json.dumps(report, indent=2))
    print(json.dumps({k: v for k, v in report.items() if k != "rows"}, indent=2))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("freeze"); f.add_argument("--candidates", required=True)
    f.add_argument("--out", required=True); f.add_argument("--min-per-repo", type=int, default=8)
    c = sub.add_parser("collect-cm"); c.add_argument("--suite", required=True)
    c.add_argument("--out", required=True); c.add_argument("--timeout", type=int, default=120)
    r = sub.add_parser("routing-inputs"); r.add_argument("--suite", required=True)
    r.add_argument("--out", required=True)
    s = sub.add_parser("score"); s.add_argument("--suite", required=True)
    s.add_argument("--cm", required=True); s.add_argument("--routing", required=True)
    s.add_argument("--semantic", default=""); s.add_argument("--out", required=True)
    args = ap.parse_args()
    {"freeze": cmd_freeze, "collect-cm": cmd_collect_cm,
     "routing-inputs": cmd_routing_inputs, "score": cmd_score}[args.cmd](args)


if __name__ == "__main__":
    main()
