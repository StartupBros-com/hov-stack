#!/usr/bin/env python3
"""Validate the shape-audit eval itself.

Fixes two defects and measures a third:
  (1) DENOMINATOR: score only "response-initial" messages (the first assistant
      text block after a genuine user turn) and "response-final" (last assistant
      text before the next user turn), instead of every assistant message
      including mid-turn tool narration.
  (2) ANCHOR BUG: apply ^-anchored regexes to the head only.
  (3) PRECISION: dump a random sample of matches per detector for hand-labeling.

A "genuine user turn" excludes tool_result carrier messages and system-injected
reminders, which Claude Code also records with type=="user".
"""
import os, sys, json, re, random, time, collections, datetime as _dt
from wilson import wilson
from concurrent.futures import ProcessPoolExecutor

P = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
BOUNDARY = _dt.datetime.fromisoformat("2026-08-05T19:09:01-04:00").timestamp()
NOW = time.time()
WINDOW_DAYS = 25
random.seed(11)

HEAD_ONLY = {
    "preamble": re.compile(
        r"^\s*(?:#{1,4}\s*)?(?:Let me\b|Let's\b|I'll\b|I will\b|I'm going to\b|I am going to\b"
        r"|Great question\b|Good question\b|Sure[,!.]|Certainly\b|Of course\b|Happy to\b"
        r"|I'd be happy to\b|First,? I(?:'ll| will)\b|Now I(?:'ll| will)\b)", re.I),
}
TAIL_OK = {
    "closer": re.compile(
        r"(Hope (?:this|that) helps|Hope it helps|Let me know if you|Let me know if there"
        r"|feel free to (?:ask|reach|let me know)|Happy to help|glad to help"
        r"|In summary,|To summarize,|To sum up,|All set!|That's everything"
        r"|I've now (?:done|completed|finished)|I have now (?:done|completed|finished))", re.I),
    "punt": re.compile(
        r"(let me know how you.{0,25}(?:like to )?proceed|how would you like (?:me )?to proceed"
        r"|let me know what you.{0,20}think|just let me know|what would you like to do next"
        r"|let me know if you.{0,20}want me to)", re.I),
    "error_tone": re.compile(
        r"(\bUh[- ]oh\b|\bOops\b|\bWhoops\b|There seems to be a problem|Something went wrong"
        r"|\bUnfortunately,|I apologize|Sorry (?:about|for) (?:that|the))", re.I),
    "step_restate": re.compile(r"Step\s+\d+\s+of\s+\d+", re.I),
}


def is_real_user_turn(d):
    if d.get("type") != "user":
        return False
    msg = d.get("message") or {}
    c = msg.get("content")
    if isinstance(c, str):
        return "<system-reminder>" not in c and bool(c.strip())
    if isinstance(c, list):
        has_tool_result = any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c)
        if has_tool_result:
            return False
        txt = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
        return bool(txt.strip()) and "<system-reminder>" not in txt
    return False


def scan(fp):
    """Return (initial, final, allmsgs) triples: (ts, model, text)."""
    initial, final, allm = [], [], []
    try:
        with open(fp, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except Exception:
        return [], [], []
    awaiting = False   # next assistant text starts a response
    last_asst = None
    for line in lines:
        if '"user"' not in line and '"assistant"' not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("isSidechain"):
            continue
        if is_real_user_turn(d):
            if last_asst is not None:
                final.append(last_asst)
                last_asst = None
            awaiting = True
            continue
        if d.get("type") != "assistant":
            continue
        msg = d.get("message") or {}
        c = msg.get("content")
        if not isinstance(c, list):
            continue
        txt = "\n".join(x.get("text", "") for x in c
                        if isinstance(x, dict) and x.get("type") == "text").strip()
        if len(txt) < 20:
            continue
        ts = d.get("timestamp")
        if not ts:
            continue
        try:
            t = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except Exception:
            continue
        rec = (t, msg.get("model") or "?", txt)
        allm.append(rec)
        last_asst = rec
        if awaiting:
            initial.append(rec)
            awaiting = False
    if last_asst is not None:
        final.append(last_asst)
    return initial, final, allm


def rate(rows, rx, head_only):
    k = 0
    hits = []
    for t, m, txt in rows:
        s = txt[:400] if head_only else (txt[:400] + "\n...\n" + txt[-400:])
        if rx.search(s):
            k += 1
            hits.append((t, m, txt))
    return k, len(rows), hits


def main():
    files = []
    for root, _, fns in os.walk(P):
        for fn in fns:
            if fn.endswith(".jsonl"):
                fp = os.path.join(root, fn)
                try:
                    if (NOW - os.stat(fp).st_mtime) < WINDOW_DAYS * 86400:
                        files.append(fp)
                except OSError:
                    pass
    print(f"scanning {len(files)} files", file=sys.stderr)
    I, F, A = [], [], []
    with ProcessPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as ex:
        for i, f, a in ex.map(scan, files, chunksize=8):
            I.extend(i); F.extend(f); A.extend(a)

    print("=" * 100)
    print("(1) DENOMINATOR: how much of the corpus is actually a 'response'?")
    print("=" * 100)
    print(f"  all main-thread assistant text messages : {len(A):,}")
    print(f"  response-INITIAL (first after user turn) : {len(I):,}  ({100*len(I)/max(1,len(A)):.1f}%)")
    print(f"  response-FINAL   (last before next user) : {len(F):,}  ({100*len(F)/max(1,len(A)):.1f}%)")
    print("  -> the original audit used the 'all' denominator for every rule.")

    # OWNER: whoever re-runs this audit (README "Re-run 2026-08-26") — re-measure
    # the corpus's dominant model and bump this literal before trusting any delta.
    # PROVENANCE: the 2026-08-06 run measured the POST window at 96.4% this exact
    # model string (README Trap 1: model-match or you manufacture an effect).
    # DISCOVERY-GAP: deliberately NOT an alias/runtime lookup — this pins a frozen
    # historical population, not today's default. Silent failure mode: once the
    # fleet moves past opus-5 the filter still runs; samples just decay toward zero.
    OPUS5 = "claude-opus-5"
    for label, rows, detectors in (
        ("RESPONSE-INITIAL  (preamble / lead-with-answer)", I, HEAD_ONLY),
        ("RESPONSE-FINAL    (closer / punt / error / step)", F, TAIL_OK),
    ):
        pre = [r for r in rows if r[0] < BOUNDARY and r[1] == OPUS5]
        post = [r for r in rows if r[0] >= BOUNDARY and r[1] == OPUS5]
        print("\n" + "=" * 100)
        print(f"(2) {label}   MODEL-MATCHED opus-5   n_pre={len(pre):,} n_post={len(post):,}")
        print("=" * 100)
        for name, rx in detectors.items():
            ho = name in HEAD_ONLY
            ka, na, _ = rate(pre, rx, ho)
            kb, nb, _ = rate(post, rx, ho)
            a, al, ah = wilson(ka, na)
            b, bl, bh = wilson(kb, nb)
            sig = "  *" if (bh < al or bl > ah) else ""
            print(f"  {name:14s} PRE {a:6.2f}[{al:5.2f},{ah:5.2f}] ({ka}/{na})   "
                  f"POST {b:6.2f}[{bl:5.2f},{bh:5.2f}] ({kb}/{nb})   {b-a:+7.2f}pp{sig}")

    print("\n" + "=" * 100)
    print("(3) PRECISION SAMPLES — are the detectors matching what we think?")
    print("=" * 100)
    for name, rx in list(HEAD_ONLY.items()) + list(TAIL_OK.items()):
        ho = name in HEAD_ONLY
        src = I if ho else F
        _, _, hits = rate(src, rx, ho)
        print(f"\n--- {name}: {len(hits)} matches in {len(src):,} scored messages ---")
        for t, m, txt in random.sample(hits, min(6, len(hits))):
            snippet = (txt[:150] if ho else txt[-190:]).replace("\n", " / ")
            when = _dt.datetime.fromtimestamp(t).strftime("%m-%d")
            print(f"   [{when} {m[:16]:16s}] {snippet}")


if __name__ == "__main__":
    main()
