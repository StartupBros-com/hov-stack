#!/usr/bin/env python3
"""asr_run.py — standing ASR rig for the Mac host (M3 Ultra / MLX / Metal).

Scores are LEDGER-BACKED from acme-evals experiments/asr_eval (corpus 3128edcd2490f233),
produced by score_asr.py --record. Do not edit them here by hand.

  engine      repo                                     unprimed  primed
  qwen3       Qwen/Qwen3-ASR-1.7B                          5/9      8/9
  vibevoice   microsoft/VibeVoice-ASR-Streaming-1.5B       6/9      8/9   <= 59 MIN ONLY
  large-v3    mlx-community/whisper-large-v3-mlx           6/9      7/9
  moss        OpenMOSS-Team/MOSS-Transcribe-Diarize        6/9      7/9   native diarization
  parakeet    mlx-community/parakeet-tdt-0.6b-v3           4/9       --   no priming hook

  combination (primed)                score
  large-v3 + vibevoice                9/9   <= 59 min only
  qwen3 + vibevoice                   9/9   <= 59 min only
  large-v3 + qwen3  (--model union)   8/9   long-form safe

WHY `union` IS large-v3 + qwen3 DESPITE `best` SCORING 9/9 ON CLIPS:
Both 9/9 pairs require VibeVoice, and CLIP SCORES DO NOT TRANSFER TO LONG FORM.
mlx_audio caps VibeVoice at 59 min and TRIMS past it; this script chunks on silence instead,
which fixes the truncation. But measured on a real 80-min call, chunked VibeVoice still
(a) rendered a company name it gets RIGHT on a 15s clip as something else entirely, and
(b) produced a localized repetition loop ("Word model" x33) near minute 79. Neither failure
is visible to a 9-clip corpus of 15-30s fixtures. So `union` — large-v3 + qwen3, both proven
end-to-end on 80 minutes — stays the default for real calls, and `best` is offered for short
audio or a second opinion, not as the long-form recommendation. Trust the clip ledger for
clip-shaped questions only.

PRIMING IS A TRADE, NOT A FREE WIN. It is measured non-monotonic. On large-v3 it fixes
"Claude"/the email domain but regresses two items: "Blank" -> "Blink" (a proper-noun-heavy
prompt biases the decoder to read ordinary words as product names) and a 69% text loss on one
clip. Prime for vocabulary you know is missing, then CHECK the primed run did not lose text.
Seed --prompt only after probing a pilot clip; a prompt guessed before hearing the audio
measurably corrupts output.

  ./transcribe.sh --input call.mp4 --model union --prompt "ProductA, ProtocolB, Claude Code"
  ./transcribe.sh --input short.wav --model best --prompt "..."   # 9/9 on CLIPS
  ./transcribe.sh --input call.mp4 --model moss                          # speakers, not words
"""
import argparse, json, os, re, subprocess, sys, time, wave

OUT_DEFAULT = os.path.expanduser("~/asr/out")
WHISPER_REPO = "mlx-community/whisper-large-v3-mlx"
PARAKEET_REPO = "mlx-community/parakeet-tdt-0.6b-v3"
QWEN3_REPO = "Qwen/Qwen3-ASR-1.7B"          # NOT the 0.6B the library defaults to
MOSS_REPO = "OpenMOSS-Team/MOSS-Transcribe-Diarize"
VIBEVOICE_REPO = "microsoft/VibeVoice-ASR-Streaming-1.5B"

VIBEVOICE_MAX_SECONDS = 59 * 60  # mirrors MAX_DURATION_SECONDS in mlx_audio's vibevoice_asr


def wav_seconds(path):
    try:
        with wave.open(path, "rb") as w:
            return w.getnframes() / float(w.getframerate())
    except Exception:
        return None


def _silence_windows(wav, noise_db="-32dB", min_silence="0.6"):
    """Silence intervals via ffmpeg silencedetect, as [(start, end), ...]."""
    p = subprocess.run(
        ["ffmpeg", "-nostdin", "-i", wav, "-af",
         f"silencedetect=noise={noise_db}:d={min_silence}", "-f", "null", "-"],
        capture_output=True, text=True)
    log = p.stderr
    starts = [float(m) for m in re.findall(r"silence_start:\s*([0-9.]+)", log)]
    ends = [float(m) for m in re.findall(r"silence_end:\s*([0-9.]+)", log)]
    return list(zip(starts, ends))


def plan_chunks(wav, cap_seconds, target_seconds=None, search=300.0):
    """Split points under `cap_seconds`, snapped to the silence nearest each target.

    Returns [(start, end), ...] covering the whole file with no gaps. A cut is placed at the
    MIDPOINT of a silence window so neither side clips speech. If no silence is found within
    `search` of the target, falls back to a hard cut and flags it — a hard cut can sever a
    word, and that should be visible, not silent.
    """
    dur = wav_seconds(wav) or 0.0
    if dur <= cap_seconds:
        return [(0.0, dur)], []

    target = target_seconds or (cap_seconds * 0.85)
    sil = _silence_windows(wav)
    cuts, warnings, pos = [], [], 0.0

    while dur - pos > cap_seconds:
        want = pos + target
        cands = [s for s in sil if pos + 60 < (s[0] + s[1]) / 2 < min(pos + cap_seconds, dur - 5)]
        if cands:
            best = min(cands, key=lambda s: abs((s[0] + s[1]) / 2 - want))
            cut = (best[0] + best[1]) / 2
        else:
            cut = min(pos + cap_seconds - 30, dur - 5)
            warnings.append(
                f"no silence found near {want/60:.1f} min; hard cut at {cut/60:.1f} min "
                "may sever a word"
            )
        cuts.append(cut)
        pos = cut

    bounds, prev = [], 0.0
    for c in cuts:
        bounds.append((prev, c))
        prev = c
    bounds.append((prev, dur))
    return bounds, warnings



def _loop_report(text, min_run=10):
    """Longest CONSECUTIVE repeat run per phrase, not total occurrences.

    Total counts cannot separate a decoder loop from normal speech: on a real 80-minute call
    "Yeah" x29 and "Alright" x23 are backchannel, while "Word model" x33 is degeneration, and
    all three are short phrases repeated ~30 times. Adjacency is what distinguishes them —
    a loop repeats back-to-back, backchannel is spread across the call.\n\n    min_run=10 is calibrated against real 80-min runs, not guessed: large-v3 (clean) tops out\n    at 7 consecutive ("all right", "yeah"), while degenerate VibeVoice hit 31 and 19. Ten sits\n    in that gap.
    """
    stripped = re.sub(r"Speaker \d+:", " ", text or "")
    sents = [s.strip().lower() for s in re.split(r"[.!?\n]+", stripped) if s.strip()]
    best, run_phrase, run_len = {}, None, 0
    for s in sents:
        if s == run_phrase:
            run_len += 1
        else:
            if run_phrase and run_len > best.get(run_phrase, 0):
                best[run_phrase] = run_len
            run_phrase, run_len = s, 1
    if run_phrase and run_len > best.get(run_phrase, 0):
        best[run_phrase] = run_len
    hot = [(p, n) for p, n in best.items() if n >= min_run]
    return sorted(hot, key=lambda x: -x[1])[:6]


def _slice_wav(wav, start, end, out_dir, idx):
    dst = os.path.join(out_dir, f".chunk_{idx:02d}.wav")
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", wav,
                    "-ss", f"{start:.3f}", "-to", f"{end:.3f}",
                    "-c", "copy", dst], check=True)
    return dst


def ensure_16k_mono(src, workdir):
    base = os.path.splitext(os.path.basename(src))[0]
    dst = os.path.join(workdir, base + "_16k.wav")
    if os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
        print(f"[audio] reusing {dst}", flush=True); return dst
    print(f"[audio] converting -> {dst}", flush=True)
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", src,
                    "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", dst], check=True)
    return dst


def write_segments(segments, path, key="start"):
    lines = []
    for s in segments:
        st = s.get(key, 0.0) or 0.0
        spk = s.get("speaker")
        tag = f"{spk}: " if spk else ""
        lines.append("[%03d:%04.1f] %s%s" % (int(st // 60), st % 60, tag, (s.get("text") or "").strip()))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return len(lines)


def run_whisper(wav, out, prompt):
    import mlx_whisper
    print(f"[large-v3] {WHISPER_REPO}", flush=True)
    t0 = time.time()
    kw = dict(path_or_hf_repo=WHISPER_REPO, language="en",
              word_timestamps=True, condition_on_previous_text=True)
    if prompt:
        kw["initial_prompt"] = prompt
    r = mlx_whisper.transcribe(wav, **kw)
    with open(os.path.join(out, "asr_largev3.json"), "w") as f:
        json.dump(r, f)
    n = write_segments(r.get("segments", []), os.path.join(out, "asr_largev3_segments.txt"))
    print(f"[large-v3] {(time.time()-t0)/60:.1f} min, {len(r['text'].split())} words, {n} segs", flush=True)
    return r["text"]


def run_qwen3(wav, out, prompt):
    """Priming hook is `context=`, not initial_prompt."""
    from mlx_qwen3_asr import transcribe
    print(f"[qwen3] {QWEN3_REPO}", flush=True)
    t0 = time.time()
    r = transcribe(wav, model=QWEN3_REPO, context=prompt or "", return_timestamps=True)
    text = getattr(r, "text", "") or ""
    segs = []
    raw = (getattr(r, "chunks", None) or getattr(r, "segments", None)
           or getattr(r, "timestamps", None) or [])
    for c in raw:
        if isinstance(c, dict):
            st, tx = c.get("start", c.get("timestamp", [0.0])), c.get("text", "")
        else:
            st, tx = getattr(c, "start", getattr(c, "timestamp", 0.0)), getattr(c, "text", "")
        if isinstance(st, (list, tuple)):
            st = st[0] if st else 0.0
        segs.append({"start": st or 0.0, "text": tx})
    with open(os.path.join(out, "asr_qwen3.json"), "w") as f:
        json.dump({"text": text, "segments": segs}, f)
    if segs:
        write_segments(segs, os.path.join(out, "asr_qwen3_segments.txt"))
    print(f"[qwen3] {(time.time()-t0)/60:.1f} min, {len(text.split())} words, {len(segs)} segs", flush=True)
    return text


def run_vibevoice(wav, out, prompt):
    """Priming hook is `context=`. Also diarizes (Speaker N:).

    mlx_audio caps VibeVoice at 59 min (MAX_DURATION_SECONDS) and TRIMS past it with only a
    warning. That is not a model limit: at 7.5 audio tokens/s (24kHz / compress-ratio 3200)
    against a 65536-token context, 59 min uses ~26.5k tokens — about 40% of the window — and
    the checkpoint is a streaming model (22-frame chunks, 4-frame lookahead). So we chunk
    below the cap and stitch, rather than lose the tail.
    """
    from mlx_audio.stt.generate import load_model
    print(f"[vibevoice] {VIBEVOICE_REPO}", flush=True)
    t0 = time.time()
    model = load_model(VIBEVOICE_REPO)
    kw = {"context": prompt} if prompt else {}

    bounds, warns = plan_chunks(wav, VIBEVOICE_MAX_SECONDS)
    for w in warns:
        print(f"[vibevoice] WARNING: {w}", flush=True)
    if len(bounds) > 1:
        print(f"[vibevoice] {len(bounds)} chunks (cap is 59 min): "
              + ", ".join(f"{s/60:.1f}-{e/60:.1f}m" for s, e in bounds), flush=True)

    texts, segs = [], []
    for i, (s, e) in enumerate(bounds):
        piece = wav if len(bounds) == 1 else _slice_wav(wav, s, e, out, i)
        r = model.generate(piece, **kw)
        txt = (getattr(r, "text", "") or "").strip()
        texts.append(txt)
        for seg in (getattr(r, "segments", None) or []):
            if not isinstance(seg, dict):
                continue
            segs.append({"start": (seg.get("start", 0.0) or 0.0) + s,
                         "text": seg.get("text", ""),
                         "speaker": seg.get("speaker_id")})
        if len(bounds) > 1:
            print(f"[vibevoice]   chunk {i}: {len(txt.split())} words", flush=True)
            try:
                os.remove(piece)
            except OSError:
                pass

    text_all = " ".join(t for t in texts if t)
    with open(os.path.join(out, "asr_vibevoice.json"), "w") as f:
        json.dump({"text": text_all, "segments": segs, "chunks": len(bounds)}, f)
    if segs:
        write_segments(segs, os.path.join(out, "asr_vibevoice_segments.txt"))
    print(f"[vibevoice] {(time.time()-t0)/60:.1f} min, {len(text_all.split())} words, "
          f"{len(bounds)} chunk(s)", flush=True)
    return text_all


def run_moss(wav, out, prompt):
    """The diarization engine. FOOTGUN: hotwords WITHOUT an explicit prompt silently drops the
    [Sxx] instructions inside merge_hotwords, so you lose speakers and get plain text back."""
    from mlx_audio.stt.generate import load_model
    from mlx_audio.stt.models.moss_transcribe_diarize.moss_transcribe_diarize import DEFAULT_PROMPT
    print(f"[moss] {MOSS_REPO} (diarizing)", flush=True)
    t0 = time.time()
    model = load_model(MOSS_REPO)
    hot = [w.strip(",. ") for w in prompt.replace(",", " ").split() if w.strip(",. ")] if prompt else None
    r = model.generate(wav, prompt=DEFAULT_PROMPT, hotwords=hot, max_tokens=8192)
    text = getattr(r, "text", "") or str(r)
    segs = []
    for s in (getattr(r, "segments", None) or []):
        d = s if isinstance(s, dict) else {}
        txt = (d.get("text") or "").strip()
        spk = d.get("speaker_id")
        if spk and txt.startswith(f"[{spk}]"):
            txt = txt[len(spk) + 2:].strip()
        segs.append({"start": d.get("start", 0.0), "text": txt, "speaker": spk})
    with open(os.path.join(out, "asr_moss.json"), "w") as f:
        json.dump({"text": text, "segments": segs}, f)
    if segs:
        write_segments(segs, os.path.join(out, "asr_moss_segments.txt"))
        print(f"[moss] speakers: {sorted({s['speaker'] for s in segs if s.get('speaker')})}", flush=True)
    print(f"[moss] {(time.time()-t0)/60:.1f} min, {len(text.split())} words, {len(segs)} segs", flush=True)
    return text


def run_parakeet(wav, out, _prompt):
    from parakeet_mlx import from_pretrained
    print(f"[parakeet] {PARAKEET_REPO}", flush=True)
    t0 = time.time()
    r = from_pretrained(PARAKEET_REPO).transcribe(wav)
    segs = [{"start": getattr(s, "start", 0.0), "text": getattr(s, "text", "")}
            for s in (getattr(r, "sentences", None) or [])]
    with open(os.path.join(out, "asr_parakeet.json"), "w") as f:
        json.dump({"text": r.text, "segments": segs}, f)
    if segs:
        write_segments(segs, os.path.join(out, "asr_parakeet_segments.txt"))
    print(f"[parakeet] {(time.time()-t0)/60:.1f} min, {len(r.text.split())} words", flush=True)
    return r.text


ENGINES = {
    "large-v3": run_whisper, "qwen3": run_qwen3, "vibevoice": run_vibevoice,
    "moss": run_moss, "parakeet": run_parakeet,
}
SETS = {
    "union": ["large-v3", "qwen3"],            # 8/9 but LONG-FORM SAFE — the default
    "best": ["large-v3", "vibevoice"],         # measured 9/9; chunks past 59 min
    "both": ["large-v3", "parakeet"],          # legacy, kept for compatibility
    "all": ["large-v3", "qwen3", "vibevoice", "moss", "parakeet"],
}


def main():
    ap = argparse.ArgumentParser(description="MLX ASR rig on the Mac host",
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    ap.add_argument("--input", required=True)
    ap.add_argument("--out", default=OUT_DEFAULT)
    ap.add_argument("--prompt", default="",
                    help="domain nouns. Probe a pilot clip FIRST; a guessed prompt corrupts output.")
    ap.add_argument("--model", default="union", choices=list(ENGINES) + list(SETS))
    a = ap.parse_args()

    if not os.path.exists(a.input):
        sys.exit(f"ERROR: no such input: {a.input}")
    os.makedirs(a.out, exist_ok=True)
    wav = ensure_16k_mono(a.input, a.out)

    secs = wav_seconds(wav)
    if secs:
        print(f"[audio] {secs/60:.1f} min", flush=True)
    if not a.prompt:
        print("[warn] no --prompt: 7 architectures all hear 'cloud code' for 'Claude Code' "
              "unprimed. Probe a pilot clip and seed the real nouns.", flush=True)

    texts = {}
    for name in SETS.get(a.model, [a.model]):
        try:
            texts[name] = ENGINES[name](wav, a.out, a.prompt)
        except Exception as e:
            print(f"[{name}] FAILED: {type(e).__name__}: {e}", flush=True)

    # Cross-engine length check: a big shortfall is the silent-omission signature, and it is
    # invisible to any check against a single engine's own output.
    # Repetition loops: a long-form-only failure mode. Checked per engine, because one
    # engine can degenerate while another on the same audio does not.
    for k, v in sorted(texts.items()):
        hot = _loop_report(v)
        for phrase, n in hot:
            print(f"[check] {k}: {phrase[:40]!r} repeats {n}x CONSECUTIVELY — decoder loop; "
                  "that region is invented, not transcribed.", flush=True)

    if len(texts) > 1:
        lens = {k: len(v.split()) for k, v in texts.items() if v}
        if lens:
            best = max(lens.values())
            for k, n in sorted(lens.items()):
                if best and n < best * 0.85:
                    print(f"[check] {k} returned {n} words vs {best} best — possible dropped "
                          f"speech; diff before trusting it.", flush=True)
            # A LONGER output is not automatically a better one: loop junk inflates counts.
            longest = max(lens, key=lens.get)
            if _loop_report(texts.get(longest, "")):
                print(f"[check] {longest} is the longest output BUT contains a repeat loop — "
                      "do not treat its extra length as extra coverage.", flush=True)
    print("ASR_RUN_OK")


if __name__ == "__main__":
    main()
