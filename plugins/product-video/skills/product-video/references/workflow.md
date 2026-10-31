# Product-tour workflow

## 1. Lock the source contract

Write a bounded manifest before writing composition code. Name the audience, destination, dimensions, target duration, CTA, source for every product claim, and one or more non-empty scenes. Record whether the request is capture-first or screenshot-first.

Do not add unsupported claims to make a scene feel complete. If a visual or claim cannot be traced to the product, brief, or supplied source, remove it.

For a narrated browser tour, write a versioned `NarratedScenarioV1` first: fixed project contract, explicit allowed hosts and routes, bounded actions, chapter timing, and a total-duration budget. A route path must be unambiguous and credential-like selectors are prohibited.

## 2. Prepare safe product material

Prefer committed fixtures for generic repeatable work. For a recipient-specific walkthrough, use that recipient's own read-only account through the supported impersonation flow; never substitute a generic demo account. Follow [capture.md](capture.md) for every live product capture. Remove unrelated or sensitive data before capture; blur-after-recording is a fallback, not the default.

Extract a small brand contract from the product: canvas, surfaces, foreground, accent, type scale, spacing, radius, logo, and density. Generated title cards and overlays should feel native to the product rather than applying a generic video skin.

For narrated media, supply a strict plain-text SRT and either operator-recorded audio or a voice synthesized with `narrated:voice`, which speaks each caption cue and places it at that cue's own start time so the voice cannot drift from the words on screen. Do not open a microphone, and do not clone a real person's voice without their consent. Automatic redaction is still out: the pipeline creates no human-review or redaction receipt, so record any required review outside the run before capture.

## 3. Capture and prepare a narrated source

Use dry run before any CDP attachment:

```bash
pnpm narrated:capture \
  --scenario fixtures/narrated-scenario.example.json \
  --run-id product-tour-v1 \
  --dry-run
```

Only after the operator verifies the approved fixture or intended recipient-visible account state and the installed capability probe passes, make the loopback-only capture. It produces an exclusive local run with `capture.v1.json`, `capture.webm`, and `telemetry.v1.json`. Prepare the source with the operator's audio and captions:

```bash
pnpm narrated:prepare \
  --capture tooling/product-video/public/generated/narrated/product-tour-v1/capture.v1.json \
  --audio /safe/local/narration.wav \
  --captions /safe/local/captions.srt
```

Preparation normalizes narration to 48kHz PCM WAV and creates the immutable `resolved.v1.json`. If trimming source material is necessary, pass both `--start-ms` and `--end-ms`; do not use an implicit source window.

Use `narrated:smoke` for a complete neutral local fixture/render/verify pass when no live browser capture is appropriate.

## 4. Storyboard before motion

Give every scene one job. Specify its source image/clip, title, supporting line, duration, and transition. Let narration determine scene timing when narration exists. Reserve rest frames after information lands; cutting immediately after the final animation makes the work unreadable.

Use one primary motion idea per scene. Reuse the product's visual language; do not repeat a showpiece animation as filler. For `NarratedBrowserTour`, derive camera motion from safe normalized geometry and keep captions in output space so camera transforms cannot crop them.

## 5. Build deterministically

Use the `@kit/product-video` fixture as the reference composition. Parameterize content through a validated manifest. Use `useCurrentFrame()`, `useVideoConfig()`, `interpolate()`, and explicit easing. Clamp interpolation boundaries. Keep source assets local for the render.

Preview the resolved narrated manifest separately from rendering:

```bash
pnpm narrated:studio \
  --manifest tooling/product-video/public/generated/narrated/product-tour-v1/resolved.v1.json

pnpm narrated:render \
  --manifest tooling/product-video/public/generated/narrated/product-tour-v1/resolved.v1.json
```

Studio is an interactive local preview process only. Rendering writes only the run-owned H264/`yuv420p` MP4 path; it does not upload or publish.

## 6. Verify the artifact

Run the package verification command and inspect its generated contact sheet before delivery. Follow [qa.md](qa.md). When the result is user-facing, run a fresh-context visual review of only the contact sheet, storyboard, and checklist so the reviewer is not biased by implementation history.

For narrated runs, invoke `narrated:verify` with the same resolved manifest and its fixed owned MP4 path. Treat missing prerequisites, failed OCR, mismatched provenance, or a skipped required check as non-delivery.
