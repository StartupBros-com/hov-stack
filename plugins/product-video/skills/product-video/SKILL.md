---
name: product-video
description: Build or edit deterministic product walkthroughs, SaaS demo videos, feature tours, launch clips, narrated browser tours, and captioned screen recordings. Use whenever a user asks to record a product flow, turn app screens into a video, create a walkthrough/demo/promo, improve an existing product video, or mechanically verify a rendered MP4—even when they do not mention Remotion.
compatibility: Requires Node 24, the repository pnpm toolchain, FFmpeg/FFprobe, and an installed Chrome-compatible browser. Required narrated OCR verification additionally needs Tesseract. Authenticated capture additionally requires the existing wsl-cdp profile and the repository-pinned Playwright capture runtime; the skill never installs browser tooling at runtime.
---

# Product video

Produce product videos from source-traceable product material. A polished render is not proof of a correct walkthrough: preserve the real interface, keep claims tied to evidence, and verify the final media artifact mechanically and visually.

## Route the request

1. **New ProductTour or promo:** read [workflow.md](references/workflow.md).
2. **Narrated browser tour:** read [workflow.md](references/workflow.md), [capture.md](references/capture.md), and [qa.md](references/qa.md). Use `NarratedBrowserTour` V1 rather than modifying the legacy `ProductTour` composition.
3. **Authenticated browser capture:** read [capture.md](references/capture.md) before opening or attaching to a browser.
4. **Existing-video timing or composition edit:** preserve the accepted story and edit only the requested layer; then use [qa.md](references/qa.md).
5. **Render or verification only:** use [qa.md](references/qa.md).
6. **Music, external publishing, or third-party generation:** stop at the boundary in [effects.md](references/effects.md). Do not improvise credentials or publish. Narration is in scope — synthesize it with `narrated:voice` using the operator's own provider key, never by cloning a real person's voice without consent.

## Non-negotiable boundaries

- Use real product captures for real product screens. Rebuild only an explicitly stylized scene or one isolated element that must animate.
- Use either committed fixtures or the intended walkthrough recipient's own read-only account through the product's supported impersonation flow. Never substitute demo data when the request is recipient-specific. Before recording, verify that the viewport contains only recipient-visible product state and no credentials, unrelated customer data, private communications, internal-only values, or secrets. V1 does not redact media or create a human-review/redaction receipt.
- Never automate login, MFA, CAPTCHA, password entry, token entry, or account recovery. Attach only to the dedicated profile after the operator has authenticated it.
- Narrated live capture is loopback-CDP only, fail-closed, and dry-run first. Persist only normalized cursor/click/element geometry/scroll/declared-route telemetry—never URLs, selectors, DOM text, storage, requests, or account data.
- Never install or update third-party skills, CLIs, browser extensions, or providers at runtime. Use only dependencies pinned and reviewed in the repository, and follow [UPSTREAM.md](UPSTREAM.md) for provenance. Do not install the Playwright CLI's bundled skill instructions.
- Drive animation from frames. Do not use CSS transitions, CSS keyframes, clocks, or unseeded randomness in rendered compositions.
- Refuse zero-scene plans and zero-frame renders. A successful process exit without content is a failure.
- Render locally by default. Sending or publishing the result requires explicit authorization for that destination.

## Commands

Run commands from the repository root through the workspace package:

```bash
pnpm capture --help
pnpm render --help
pnpm verify --help
pnpm narrated:capture --help
pnpm narrated:prepare --help
pnpm narrated:studio --help
pnpm narrated:render --help
pnpm narrated:verify --help
```

Scripts are black boxes: use `--help` before reading their source. The legacy fixture smoke path is `test:render`. The narrated local-only synthetic smoke path is:

```bash
pnpm narrated:smoke
```

It creates ignored neutral media, renders it, and verifies captions with required OCR. A missing FFmpeg, FFprobe, Tesseract, or Chrome-compatible browser is a **non-pass**, not a skipped pass. It never attaches to CDP or captures product/customer data.

## Narrated completion contract

A delivered narrated render includes:

- the run ID, MP4 path, actual duration, and resolved V1 manifest path;
- a finalized capture bundle whose source video and telemetry exactly bind the resolved manifest;
- FFprobe evidence for H264, dimensions, `yuv420p`, duration, size, decoded frame count, audio stream, and 48kHz sample rate;
- marker, semantic telemetry, and caption midpoint samples plus the contact sheet;
- required caption OCR status when captions are expected;
- any skipped or non-pass check and its concrete reason;
- the narration source: operator-recorded audio, or the synthesized voice ID and cue count from `narrated:voice`;
- confirmation that no upload or publishing occurred unless it was explicitly requested and separately authorized.

`public/generated/narrated/<run-id>/` and `out/narrated/<run-id>/` are local, ignored, run-owned artifact roots. Do not repoint a run to a different capture or overwrite outputs outside those roots.
