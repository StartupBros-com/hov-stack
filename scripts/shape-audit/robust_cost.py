#!/usr/bin/env python3
"""Robustness for the Response-Shape audit + real CLAUDE.md token cost.

(A) How concentrated is the POST group? How many distinct sessions? What happens
    to the deltas when the current analysis session is excluded?
(B) What does the always-on CLAUDE.md actually cost in tokens/session?
"""
import os, sys, json, re, time, collections, datetime as _dt
from wilson import wilson
from concurrent.futures import ProcessPoolExecutor

P = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "projects")
BOUNDARY = _dt.datetime.fromisoformat("2026-08-05T19:09:01-04:00").timestamp()
NOW = time.time()
WINDOW_DAYS = 25
THIS_SESSION = "2fc3c352-a9b7-403d-9419-22250b13f7a2"

RX = {
    "preamble": re.compile(
        r"^\s*(?:#{1,4}\s*)?(?:Let me\b|Let's\b|I'll\b|I will\b|I'm going to\b|I am going to\b"
        r"|Great question\b|Good question\b|Sure[,!.]|Certainly\b|Of course\b|Happy to\b"
        r"|I'd be happy to\b|First,? I(?:'ll| will)\b|Now I(?:'ll| will)\b|Let me know\b)", re.I),
    "closer": re.compile(
        r"(Hope (?:this|that) helps|Hope it helps|Let me know if you|Let me know if there"
        r"|feel free to (?:ask|reach|let me know)|Happy to help|glad to help"
        r"|In summary,|To summarize,|To sum up,|Overall,\s|All set!|That's everything"
        r"|I've now (?:done|completed|finished)|I have now (?:done|completed|finished))", re.I),
    "punt": re.compile(
        r"(let me know how you.{0,25}(?:like to )?proceed|how would you like (?:me )?to proceed"
        r"|let me know what you.{0,20}think|just let me know|what would you like to do next"
        r"|let me know if you.{0,20}want me to)", re.I),
    "error_tone": re.compile(
        r"(\bUh[- ]oh\b|\bOops\b|\bWhoops\b|There seems to be a problem|Something went wrong"
        r"|\bUnfortunately,|I apologize|Sorry (?:about|for) (?:that|the))", re.I),
    "step_restate": re.compile(r"Step\s+\d+\s+of\s+\d+", re.I),
    "result_line": re.compile(r"(?:^|\n)\s*result:", re.I),
}
HEAD = TAIL = 400


def scan(fp):
    sess = os.path.basename(fp)[:-6]
    recs, usage = [], []
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
                ts = d.get("timestamp")
                if not ts:
                    continue
                try:
                    t = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except Exception:
                    continue
                msg = d.get("message") or {}
                u = msg.get("usage") or {}
                if u:
                    usage.append((t, sess, bool(d.get("isSidechain")),
                                  u.get("input_tokens", 0) or 0,
                                  u.get("cache_creation_input_tokens", 0) or 0,
                                  u.get("cache_read_input_tokens", 0) or 0,
                                  u.get("output_tokens", 0) or 0))
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                txt = "\n".join(c.get("text", "") for c in content
                                if isinstance(c, dict) and c.get("type") == "text").strip()
                if len(txt) >= 20:
                    recs.append((t, sess, bool(d.get("isSidechain")), txt[:HEAD], txt[-TAIL:]))
    except Exception:
        return [], []
    return recs, usage


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
    allrecs, allusage = [], []
    with ProcessPoolExecutor(max_workers=min(8, os.cpu_count() or 4)) as ex:
        for r, u in ex.map(scan, files, chunksize=8):
            allrecs.extend(r)
            allusage.extend(u)

    main_recs = [r for r in allrecs if not r[2]]
    pre = [r for r in main_recs if r[0] < BOUNDARY]
    post = [r for r in main_recs if r[0] >= BOUNDARY]
    post_ex = [r for r in post if r[1] != THIS_SESSION]

    print("\n" + "=" * 96)
    print("(A) POST-GROUP CONCENTRATION")
    print("=" * 96)
    sess_post = collections.Counter(r[1] for r in post)
    print(f"POST main-thread messages : {len(post):,} across {len(sess_post)} distinct sessions")
    print(f"  this analysis session   : {sess_post.get(THIS_SESSION,0):,} "
          f"({100*sess_post.get(THIS_SESSION,0)/max(1,len(post)):.1f}% of POST)")
    print("  top 8 contributing sessions:")
    for s, n in sess_post.most_common(8):
        tag = "  <-- this session" if s == THIS_SESSION else ""
        print(f"     {n:5d}  {s[:40]}{tag}")
    print(f"\nPRE  main-thread messages : {len(pre):,} across "
          f"{len(set(r[1] for r in pre))} distinct sessions")

    print("\n" + "=" * 96)
    print("(B) DELTAS, WITH THIS SESSION EXCLUDED FROM POST")
    print("=" * 96)
    print(f"{'signal':16s} {'PRE %':>21s} {'POST %':>21s} {'POST-ex %':>21s} {'d(ex) pp':>9s}")
    for name, rx in RX.items():
        kp = sum(1 for r in pre if rx.search(r[3]) or rx.search(r[4]))
        ko = sum(1 for r in post if rx.search(r[3]) or rx.search(r[4]))
        ke = sum(1 for r in post_ex if rx.search(r[3]) or rx.search(r[4]))
        a, al, ah = wilson(kp, len(pre))
        b, bl, bh = wilson(ko, len(post))
        c, cl, ch = wilson(ke, len(post_ex))
        sig = "  *" if (ch < al or cl > ah) else ""
        print(f"{name:16s} {a:6.2f}[{al:5.2f},{ah:5.2f}] {b:6.2f}[{bl:5.2f},{bh:5.2f}] "
              f"{c:6.2f}[{cl:5.2f},{ch:5.2f}] {c-a:+8.2f}{sig}")
    print(f"\n  n_pre={len(pre):,}  n_post={len(post):,}  n_post_excl_this_session={len(post_ex):,}")
    print("  (* = POST-ex 95% Wilson CI does not overlap PRE)")

    # ---------------- cost ----------------
    print("\n" + "=" * 96)
    print("(C) ALWAYS-ON CLAUDE.md TOKEN COST")
    print("=" * 96)
    md = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "CLAUDE.md")
    nch = os.path.getsize(md)
    est_tok = nch / 3.6  # markdown w/ punctuation runs denser than 4 ch/tok
    print(f"CLAUDE.md: {nch:,} bytes  ~= {est_tok:,.0f} tokens (at 3.6 ch/tok)")
    rs = 2793  # Response Shape section size per PR #161 commit message
    print(f"  of which Response Shape section: {rs:,} bytes ~= {rs/3.6:,.0f} tokens "
          f"({100*rs/nch:.1f}% of file)")

    recent = [u for u in allusage if (NOW - u[0]) < 7 * 86400]
    sess = collections.defaultdict(lambda: [0, 0, 0, 0, 0])  # msgs, cc, cr, in, out
    for t, s, side, i, cc, cr, o in recent:
        e = sess[(s, side)]
        e[0] += 1; e[1] += cc; e[2] += cr; e[3] += i; e[4] += o
    main_s = {k: v for k, v in sess.items() if not k[1]}
    sub_s = {k: v for k, v in sess.items() if k[1]}
    print(f"\nlast 7 days: {len(main_s):,} main sessions, {len(sub_s):,} subagent streams")
    for nm, grp in (("main", main_s), ("subagent", sub_s)):
        if not grp:
            continue
        msgs = sorted(v[0] for v in grp.values())
        cc = sorted(v[1] for v in grp.values())
        cr = sorted(v[2] for v in grp.values())
        print(f"  {nm:9s} median msgs/session {msgs[len(msgs)//2]:5d} | "
              f"median cache_creation {cc[len(cc)//2]:9,d} | median cache_read {cr[len(cr)//2]:11,d}")
    tot_cc = sum(v[1] for v in sess.values())
    tot_cr = sum(v[2] for v in sess.values())
    n_streams = len(sess)
    print(f"\n  7d totals: cache_creation {tot_cc:,}  cache_read {tot_cr:,}  streams {n_streams:,}")
    # CLAUDE.md is part of the cached prefix: paid once per stream at creation,
    # then re-read on every subsequent request in that stream.
    reads_per_stream = (sum(v[0] for v in sess.values()) / max(1, n_streams))
    md_cc = est_tok * n_streams
    md_cr = est_tok * (sum(v[0] for v in sess.values()) - n_streams)
    print(f"  attributable to CLAUDE.md (approx, 7d):")
    print(f"    cache-creation ~{md_cc:,.0f} tok  ({100*md_cc/max(1,tot_cc):.1f}% of all cache_creation)")
    print(f"    cache-read     ~{md_cr:,.0f} tok  ({100*md_cr/max(1,tot_cr):.1f}% of all cache_read)")
    print(f"    mean requests/stream = {reads_per_stream:.1f}")
    rs_tok = rs / 3.6
    print(f"  Response-Shape share only: ~{rs_tok*n_streams:,.0f} creation + "
          f"~{rs_tok*(sum(v[0] for v in sess.values())-n_streams):,.0f} read tokens / 7d")


if __name__ == "__main__":
    main()
