#!/usr/bin/env python3
"""Response-Shape natural experiment.

!! KNOWN DEFECTS -- prefer validate_eval.py !!
  (a) scores every assistant message, but only ~12.9% are a response to the
      user -- the rest is mid-turn tool narration, which dilutes every rate;
  (b) applies a ^-anchored regex to the message TAIL as well as the head,
      where ^ binds to an arbitrary 400-char cut point.
Kept for provenance. Its numbers are superseded by validate_eval.py.

Boundary: PR #161 (41c5ef1) landed the Response Shape section in CLAUDE.md at
2026-08-05 19:09:01 -0400. Assistant messages before that timestamp are the
CONTROL (no response-shape rules); after are TREATMENT.

Measures per-bullet violation/compliance signals on assistant text.
"""
import os, sys, json, re, time, collections
from wilson import wilson
from concurrent.futures import ProcessPoolExecutor

P = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
BOUNDARY = 1786000141.0  # 2026-08-05T19:09:01-04:00 epoch; recomputed below
import datetime as _dt
BOUNDARY = _dt.datetime.fromisoformat("2026-08-05T19:09:01-04:00").timestamp()

# Only scan files that could contain messages near the boundary.
WINDOW_DAYS = float(os.environ.get("WINDOW_DAYS", "25"))
NOW = time.time()

# ---------- detectors ----------
# Violations the Response Shape section is meant to suppress
RX = {
    # bullet 1: lead with the answer, no preamble
    "preamble": re.compile(
        r"^\s*(?:#{1,4}\s*)?(?:Let me\b|Let's\b|I'll\b|I will\b|I'm going to\b|I am going to\b"
        r"|Great question\b|Good question\b|Sure[,!.]|Certainly\b|Of course\b|Happy to\b"
        r"|I'd be happy to\b|First,? I(?:'ll| will)\b|Now I(?:'ll| will)\b|Let me know\b)",
        re.I),
    # bullet 2: no closers or recaps
    "closer": re.compile(
        r"(Hope (?:this|that) helps|Hope it helps|Let me know if you|Let me know if there"
        r"|feel free to (?:ask|reach|let me know)|Happy to help|glad to help"
        r"|In summary,|To summarize,|To sum up,|Overall,\s|All set!|That's everything"
        r"|I've now (?:done|completed|finished)|I have now (?:done|completed|finished))", re.I),
    # bullet 5: end with the next concrete action (violation = punting to user)
    "punt": re.compile(
        r"(let me know how you.{0,25}(?:like to )?proceed|how would you like (?:me )?to proceed"
        r"|let me know what you.{0,20}think|just let me know|what would you like to do next"
        r"|let me know if you.{0,20}want me to)", re.I),
    # bullet 9: errors matter-of-fact
    "error_tone": re.compile(
        r"(\bUh[- ]oh\b|\bOops\b|\bWhoops\b|There seems to be a problem|Something went wrong"
        r"|\bUnfortunately,|I apologize|Sorry (?:about|for) (?:that|the))", re.I),
}
# Compliance signals
RXC = {
    "numbered_steps": re.compile(r"(?:^|\n)\s*(?:\*\*)?\d+[\.\)]\s+\S"),
    "step_restate": re.compile(r"Step\s+\d+\s+of\s+\d+", re.I),
    "ran_evidence": re.compile(r"(\bran\b|\bI ran\b)[^.\n]{0,60}`|`[^`\n]{2,80}`[^.\n]{0,40}\b\d+\s*/\s*\d+\b"),
    "result_line": re.compile(r"(?:^|\n)\s*result:", re.I),
}

HEAD, TAIL = 400, 400


def scan_file(fp):
    """Return list of (ts, is_sidechain, head, tail, nchars)."""
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
                if d.get("type") != "assistant":
                    continue
                msg = d.get("message") or {}
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                texts = [c.get("text", "") for c in content
                         if isinstance(c, dict) and c.get("type") == "text"]
                txt = "\n".join(t for t in texts if t).strip()
                if len(txt) < 20:
                    continue
                ts = d.get("timestamp")
                if not ts:
                    continue
                try:
                    t = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except Exception:
                    continue
                out.append((t, bool(d.get("isSidechain")), txt[:HEAD], txt[-TAIL:], len(txt)))
    except Exception:
        return []
    return out


def main():
    files = []
    for root, _, fnames in os.walk(P):
        for fn in fnames:
            if not fn.endswith(".jsonl"):
                continue
            fp = os.path.join(root, fn)
            try:
                mt = os.stat(fp).st_mtime
            except OSError:
                continue
            if (NOW - mt) < WINDOW_DAYS * 86400:
                files.append(fp)
    print(f"scanning {len(files)} transcripts (mtime within {WINDOW_DAYS}d)", file=sys.stderr)

    groups = {("pre", False): [], ("post", False): [], ("pre", True): [], ("post", True): []}
    n_done = 0
    with ProcessPoolExecutor(max_workers=min(8, (os.cpu_count() or 4))) as ex:
        for recs in ex.map(scan_file, files, chunksize=8):
            n_done += 1
            if n_done % 2000 == 0:
                print(f"  {n_done}/{len(files)}", file=sys.stderr)
            for t, side, head, tail, n in recs:
                key = ("post" if t >= BOUNDARY else "pre", side)
                groups[key].append((head, tail, n))

    print(f"\nBOUNDARY = 2026-08-05 19:09:01 -0400  (PR #161 / 41c5ef1)\n")
    for sidechain in (False, True):
        label = "SUBAGENT (sidechain)" if sidechain else "MAIN-THREAD assistant messages"
        pre = groups[("pre", sidechain)]
        post = groups[("post", sidechain)]
        print("=" * 104)
        print(f"### {label}   n_pre={len(pre):,}   n_post={len(post):,}")
        print("=" * 104)
        if not pre or not post:
            print("  (insufficient data)\n")
            continue
        rows = []
        for name, rx in list(RX.items()):
            kp = sum(1 for h, t, _ in pre if rx.search(h) or rx.search(t))
            ko = sum(1 for h, t, _ in post if rx.search(h) or rx.search(t))
            rows.append(("VIOL " + name, kp, len(pre), ko, len(post)))
        for name, rx in list(RXC.items()):
            kp = sum(1 for h, t, _ in pre if rx.search(h) or rx.search(t))
            ko = sum(1 for h, t, _ in post if rx.search(h) or rx.search(t))
            rows.append(("COMP " + name, kp, len(pre), ko, len(post)))
        print(f"{'signal':22s} {'PRE %':>22s} {'POST %':>22s} {'delta pp':>10s}")
        for name, kp, np_, ko, no_ in rows:
            a, al, ah = wilson(kp, np_)
            b, bl, bh = wilson(ko, no_)
            sig = "  *" if (bh < al or bl > ah) else ""
            print(f"{name:22s} {a:6.2f} [{al:5.2f},{ah:5.2f}] {b:6.2f} [{bl:5.2f},{bh:5.2f}] {b-a:+9.2f}{sig}")
        mp = sorted(x[2] for x in pre)
        mo = sorted(x[2] for x in post)
        print(f"\n  median chars/msg   PRE {mp[len(mp)//2]:6d}   POST {mo[len(mo)//2]:6d}")
        print(f"  mean   chars/msg   PRE {sum(mp)/len(mp):6.0f}   POST {sum(mo)/len(mo):6.0f}")
        print("  (* = non-overlapping 95% Wilson CIs)\n")


if __name__ == "__main__":
    main()
