#!/usr/bin/env python3
"""Is the preamble drop confounded by a model change at the boundary?

Compare model mix pre/post, and compute the preamble rate WITHIN each model
so the comparison is model-matched.
"""
import os, sys, json, re, time, collections, datetime as _dt
from wilson import wilson
from concurrent.futures import ProcessPoolExecutor

P = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
BOUNDARY = _dt.datetime.fromisoformat("2026-08-05T19:09:01-04:00").timestamp()
NOW = time.time()

PRE_RX = re.compile(
    r"^\s*(?:#{1,4}\s*)?(?:Let me\b|Let's\b|I'll\b|I will\b|I'm going to\b|I am going to\b"
    r"|Great question\b|Good question\b|Sure[,!.]|Certainly\b|Of course\b|Happy to\b"
    r"|I'd be happy to\b|First,? I(?:'ll| will)\b|Now I(?:'ll| will)\b|Let me know\b)", re.I)
STEP_RX = re.compile(r"Step\s+\d+\s+of\s+\d+", re.I)


def scan(fp):
    out = []
    try:
        with open(fp, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"assistant"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") != "assistant" or d.get("isSidechain"):
                    continue
                ts = d.get("timestamp")
                if not ts:
                    continue
                try:
                    t = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except Exception:
                    continue
                msg = d.get("message") or {}
                model = msg.get("model") or "?"
                c = msg.get("content")
                if not isinstance(c, list):
                    continue
                txt = "\n".join(x.get("text", "") for x in c
                                if isinstance(x, dict) and x.get("type") == "text").strip()
                if len(txt) < 20:
                    continue
                out.append((t, model, bool(PRE_RX.search(txt[:400])), bool(STEP_RX.search(txt[:400] + txt[-400:]))))
    except Exception:
        return []
    return out


def main():
    files = []
    for root, _, fns in os.walk(P):
        for fn in fns:
            if fn.endswith(".jsonl"):
                fp = os.path.join(root, fn)
                try:
                    if (NOW - os.stat(fp).st_mtime) < 25 * 86400:
                        files.append(fp)
                except OSError:
                    pass
    recs = []
    with ProcessPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as ex:
        for r in ex.map(scan, files, chunksize=8):
            recs.extend(r)

    pre = [r for r in recs if r[0] < BOUNDARY]
    post = [r for r in recs if r[0] >= BOUNDARY]
    print("=" * 92)
    print("MODEL MIX  (main-thread assistant messages)")
    print("=" * 92)
    cp = collections.Counter(r[1] for r in pre)
    co = collections.Counter(r[1] for r in post)
    models = sorted(set(cp) | set(co), key=lambda m: -(cp[m] + co[m]))
    print(f"{'model':44s} {'PRE n':>8s} {'PRE %':>7s} {'POST n':>8s} {'POST %':>7s}")
    for m in models[:12]:
        print(f"{m[:44]:44s} {cp[m]:8,d} {100*cp[m]/max(1,len(pre)):6.1f}% "
              f"{co[m]:8,d} {100*co[m]/max(1,len(post)):6.1f}%")

    print("\n" + "=" * 92)
    print("MODEL-MATCHED PREAMBLE RATE  (only models present on BOTH sides, n>=100 each)")
    print("=" * 92)
    print(f"{'model':40s} {'PRE %':>20s} {'POST %':>20s} {'delta':>9s}")
    any_matched = False
    for m in models:
        a = [r for r in pre if r[1] == m]
        b = [r for r in post if r[1] == m]
        if len(a) < 100 or len(b) < 100:
            continue
        any_matched = True
        ka = sum(1 for r in a if r[2]); kb = sum(1 for r in b if r[2])
        x, xl, xh = wilson(ka, len(a)); y, yl, yh = wilson(kb, len(b))
        sig = "  *" if (yh < xl or yl > xh) else ""
        print(f"{m[:40]:40s} {x:6.2f}[{xl:5.2f},{xh:5.2f}] {y:6.2f}[{yl:5.2f},{yh:5.2f}] {y-x:+8.2f}{sig}")
        ka = sum(1 for r in a if r[3]); kb = sum(1 for r in b if r[3])
        x, xl, xh = wilson(ka, len(a)); y, yl, yh = wilson(kb, len(b))
        sig = "  *" if (yh < xl or yl > xh) else ""
        print(f"{'  ^ step_restate':40s} {x:6.2f}[{xl:5.2f},{xh:5.2f}] {y:6.2f}[{yl:5.2f},{yh:5.2f}] {y-x:+8.2f}{sig}")
    if not any_matched:
        print("  NO model appears with n>=100 on both sides -> the pre/post comparison is")
        print("  fully confounded with a model change. Report as such.")
    print("\n  (* = non-overlapping 95% Wilson CIs)")


if __name__ == "__main__":
    main()
