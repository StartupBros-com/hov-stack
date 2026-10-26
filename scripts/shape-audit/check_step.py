#!/usr/bin/env python3
"""Precision-check the ONE surviving positive finding: 'Step N of M' restatement.

Scored on ALL main-thread assistant messages (the correct denominator for this
rule -- it applies to every turn of tracked multi-step work, including mid-turn
narration, not just the final message).
"""
import os, sys, json, re, random, time, datetime as _dt, collections
from wilson import wilson
from concurrent.futures import ProcessPoolExecutor

P = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
BOUNDARY = _dt.datetime.fromisoformat("2026-08-05T19:09:01-04:00").timestamp()
NOW = time.time()
random.seed(5)
RX = re.compile(r"Step\s+\d+\s+of\s+\d+", re.I)


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
                c = msg.get("content")
                if not isinstance(c, list):
                    continue
                txt = "\n".join(x.get("text", "") for x in c
                                if isinstance(x, dict) and x.get("type") == "text").strip()
                if len(txt) < 20:
                    continue
                m = RX.search(txt)
                out.append((t, msg.get("model") or "?", bool(m),
                            txt[max(0, m.start()-90):m.end()+90] if m else "",
                            os.path.basename(fp)[:-6]))
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

    # OWNER: whoever re-runs this audit (README "Re-run 2026-08-26") — re-measure
    # the corpus's dominant model and bump this literal before trusting any delta.
    # PROVENANCE: the 2026-08-06 run measured the POST window at 96.4% this exact
    # model string (README Trap 1: model-match or you manufacture an effect).
    # DISCOVERY-GAP: deliberately NOT an alias/runtime lookup — this pins a frozen
    # historical population, not today's default. Silent failure mode: once the
    # fleet moves past opus-5 the filter still runs; samples just decay toward zero.
    O = "claude-opus-5"
    pre = [r for r in recs if r[0] < BOUNDARY and r[1] == O]
    post = [r for r in recs if r[0] >= BOUNDARY and r[1] == O]
    ka = sum(1 for r in pre if r[2]); kb = sum(1 for r in post if r[2])
    a, al, ah = wilson(ka, len(pre)); b, bl, bh = wilson(kb, len(post))
    print("=" * 96)
    print("'Step N of M'  — ALL main-thread messages, model-matched to opus-5")
    print("=" * 96)
    print(f"  PRE  {a:6.3f}% [{al:.3f},{ah:.3f}]  ({ka}/{len(pre):,})")
    print(f"  POST {b:6.3f}% [{bl:.3f},{bh:.3f}]  ({kb}/{len(post):,})")
    print(f"  delta {b-a:+.3f}pp   overlap={'NO (significant)' if (bh<al or bl>ah) else 'YES (n.s.)'}")

    hits_post = [r for r in post if r[2]]
    sess = collections.Counter(r[4] for r in hits_post)
    print(f"\n  POST hits concentrated in {len(sess)} distinct sessions:")
    for s, n in sess.most_common(10):
        print(f"     {n:3d}  {s[:44]}")

    print("\n  --- POST match samples (precision check) ---")
    for r in random.sample(hits_post, min(10, len(hits_post))):
        print(f"   [{_dt.datetime.fromtimestamp(r[0]).strftime('%m-%d %H:%M')}] "
              f"...{r[3].replace(chr(10),' / ')}...")
    hits_pre = [r for r in pre if r[2]]
    print(f"\n  --- PRE match samples ({len(hits_pre)} total) ---")
    for r in random.sample(hits_pre, min(5, len(hits_pre))):
        print(f"   [{_dt.datetime.fromtimestamp(r[0]).strftime('%m-%d')}] "
              f"...{r[3].replace(chr(10),' / ')}...")


if __name__ == "__main__":
    main()
