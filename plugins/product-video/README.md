# Product video tooling

Credential-free tooling for deterministic PRBot product tours, including the additive `NarratedBrowserTour` V1 pipeline. Existing `ProductTour` commands and fixtures remain independent.

## Existing ProductTour commands

Run from the repository root:

```bash
pnpm capture --help
pnpm render --help
pnpm verify --help
pnpm studio
pnpm test:render
```

`capture` attaches to an already-authenticated loopback CDP browser and refuses credential fields and off-host navigation. It never installs a browser tool or automates login. `render` consumes a validated local manifest and writes H264 MP4. `verify` probes the final artifact, extracts scene/cut samples, optionally runs OCR, and writes `VERIFY.md` plus a contact sheet. `studio` starts the long-running local Remotion editor without opening a browser automatically; stop it with Ctrl-C. Output commands refuse existing files unless `--force` is explicit, and even forced output cannot overwrite an input manifest, source asset, scenario, or video.

## NarratedBrowserTour V1

Narrated tours are a separate, versioned pipeline. Every run has a lower-case kebab-case ID and owns one ignored local directory:

```text
public/generated/narrated/<run-id>/
  capture.v1.json       finalized status, source binding, and alignment marker
  capture.webm          bounded browser screencast
  telemetry.v1.json     normalized safe telemetry only
  narration.v1.wav      local 48kHz PCM narration
  resolved.v1.json      immutable render manifest
out/narrated/<run-id>/
  narrated-browser-tour.mp4
  VERIFY.md, snapshots/, narrated-browser-tour-contact-sheet.png
```

The package does not commit this generated media. Runs are exclusive, canonical paths are enforced, files are mode `0600`, run directories are mode `0700`, and a render/Studio/verifier rejects a manifest that does not bind exactly to its finalized capture and telemetry.

### Synthetic local smoke

Use the synthetic path to validate the pipeline without attaching to a browser or using product data:

```bash
pnpm narrated:smoke
```

It generates a neutral viewport, a 440Hz tone, and two local captions; then prepares, renders, and verifies the result with required OCR. Missing FFmpeg, FFprobe, Tesseract, or a Chrome-compatible browser is reported as a **non-pass**, not a successful skipped test. To inspect only its input fixture, run:

```bash
pnpm narrated:fixture --run-id synthetic-demo
```

Both commands write only ignored local artifacts. They do not attach to CDP, capture a browser, synthesize narration, upload, publish, or access customer data.

### Live capture and delivery sequence

1. The operator authenticates the existing dedicated browser profile and confirms either approved fixture data or the intended walkthrough recipient's own read-only account is visible through the supported impersonation flow. Never substitute a generic demo account for a recipient-specific walkthrough. Do not expose credentials, unrelated customer data, private communications, internal-only values, or secrets, and do not automate login, MFA, CAPTCHA, password/token entry, account recovery, consent walls, or browser/profile setup. V1 does not redact recorded content or create a human-review/redaction receipt; any required preflight approval remains outside this pipeline.
2. Define a `NarratedScenarioV1` with an explicit allowlist, route IDs, bounded timeline, deliberate pauses, and only safe click/move/scroll/navigation actions. Set `project.captureScale` so the browser lays out at `viewport / captureScale` CSS pixels while recording at `viewport` device pixels; capture forces that geometry through a device-metrics override and clears it afterwards, so a tall or narrow operator window still records full-bleed instead of padded matte. Use `move` steps and `click.approachMs` to glide the pointer along an eased path — cursor telemetry only exists where the mouse actually moved. Credential-like selectors, URLs with credentials/query/hash, ambiguous routes, off-host redirects, downloads, popups, and unbounded actions are refused. Every top-level and child frame must stay on a declared route; embedded third-party or otherwise undeclared frames abort capture before their content can be recorded.
3. Review the deterministic program before an attachment; dry run writes nothing:

   ```bash
   pnpm narrated:capture \
     --scenario fixtures/narrated-scenario.example.json \
     --run-id product-tour-v1 \
     --dry-run
   ```

4. If and only if the capability probe and dry run are acceptable, capture from the operator's already-authenticated **loopback-only** CDP endpoint:

   ```bash
   pnpm narrated:capture \
     --scenario fixtures/narrated-scenario.example.json \
     --run-id product-tour-v1 \
     --cdp http://127.0.0.1:9223
   ```

   The live command fails closed before creating a run when the repository-pinned Playwright runtime cannot prove the V1 APIs. Its proof connects directly to CDP without CLI session snapshots, creates a short private temporary screencast, exercises chapter/stop, verifies non-empty output, disconnects without closing the browser, and deletes the probe before capture. It records only cursor/click/element geometry/scroll/declared-route telemetry; it never persists runtime URLs, selectors, DOM text, accessible names, storage, requests, or account data.

5. Supply operator-recorded audio and plain-text SRT locally. Preparation normalizes narration to 48kHz PCM WAV, checks cue order and timing, and writes one resolved manifest:

   ```bash
   pnpm narrated:prepare \
     --capture tooling/product-video/public/generated/narrated/product-tour-v1/capture.v1.json \
     --audio /safe/local/narration.wav \
     --captions /safe/local/captions.srt
   ```

   To synthesize that narration instead of recording it, run `narrated:voice`
   first. It speaks each caption cue separately and places it at that cue's own
   start time, so the voice cannot drift from the words on screen:

   ```bash
   pnpm narrated:voice \
     --captions /safe/local/captions.srt \
     --duration-ms 33308 \
     --voice SAz9YHcvj6GT2YYXdXww \
     --out /safe/local/narration.wav
   ```

   `--duration-ms` is the capture's `durationMs`. It needs `ELEVENLABS_API_KEY`
   and writes one local WAV; a cue whose speech overruns its caption window
   fails closed rather than talking over the next line.

   A bounded `--start-ms`/`--end-ms` source window may be supplied together when the selected source is shorter than the complete capture. `prepare` consumes narration; it does not synthesize it. The command never opens a microphone, redacts automatically, uploads, or publishes.

6. Preview only the validated resolved manifest in Studio, then render its fixed owned output:

   ```bash
   pnpm narrated:studio \
     --manifest tooling/product-video/public/generated/narrated/product-tour-v1/resolved.v1.json

   pnpm narrated:render \
     --manifest tooling/product-video/public/generated/narrated/product-tour-v1/resolved.v1.json
   ```

   Studio is a preview process, not a renderer. The render uses H264 and `yuv420p`; captions are output-space overlays so camera movement cannot crop them.

7. Verify the final owned MP4 and inspect the generated contact sheet:

   ```bash
   pnpm narrated:verify \
     --manifest tooling/product-video/public/generated/narrated/product-tour-v1/resolved.v1.json \
     --input tooling/product-video/out/narrated/product-tour-v1/narrated-browser-tour.mp4 \
     --ocr required
   ```

   Verification proves capture/manifest binding, source and render duration, H264/`yuv420p`, decoded frames, 48kHz rendered audio, marker/semantic/caption samples, and required caption OCR. A successful renderer exit is not delivery evidence.

## ProductTour manifest

`fixtures/prbot-product-tour.json` is the reference legacy manifest. Every tour has fixed dimensions, frame rate, brand data, and at least one scene with an explicit frame duration. Assets are paths beneath this package's `public/` directory.

The fixture preparation command copies existing committed PRBot assets into the ignored `public/generated/` directory, so the repository does not carry duplicate image blobs.

Narration can be operator-recorded or synthesized with `narrated:voice`, which needs `ELEVENLABS_API_KEY` and writes one local WAV. There is no publishing or upload path, and nothing clones a real person's voice.
