# Video QA

Run checks on the rendered artifact, not only the composition source.

## Mechanical checks

The verifier must refuse:

- no video stream;
- zero decoded frames;
- zero or non-finite duration;
- empty files;
- codecs other than H264 for the Phase 1 delivery profile;
- dimensions that differ from the manifest;
- pixel formats other than `yuv420p` for the delivery profile.

Record codec, dimensions, pixel format, decoded frames, duration, and bytes in `VERIFY.md`.

## NarratedBrowserTour provenance and media checks

Before sampling a narrated render, verify that the resolved V1 manifest exactly binds to its finalized complete capture bundle and telemetry. Refuse a run when its source asset path, marker, project, selected source window, or telemetry differ from the capture bundle.

Probe both source and render. The source must match the complete capture duration before window selection. The rendered file must have H264/`yuv420p`, decoded frames, a duration within the declared frame tolerance, and an audio stream at 48kHz. A syntactically valid manifest without a matching finalized capture is not renderable proof.

Use the fixed run-owned output path:

```bash
pnpm narrated:verify \
  --manifest tooling/product-video/public/generated/narrated/<run-id>/resolved.v1.json \
  --input tooling/product-video/out/narrated/<run-id>/narrated-browser-tour.mp4 \
  --ocr required
```

The narrated verifier samples the alignment marker, semantic telemetry, caption cue midpoints, and output bounds. It writes only the run-owned `VERIFY.md`, labeled snapshots, and contact sheet. Existing tool-owned evidence requires explicit `--force`; unrelated files are not removed.

## Visual samples

Extract every scene midpoint. Around each scene cut, extract one frame 0.1 seconds before and one 0.2 seconds after. Tile the samples into a labeled contact sheet.

For narrated tours, include the capture alignment marker, cursor/click/geometry/route samples that fall in the selected source window, every caption midpoint, and beginning/end bounds.

Inspect for overflow, clipped text, unreadable contrast, accidental black frames, stale UI, visual jumps, inconsistent branding, and whether each scene still communicates one idea. A continuing element should not change position, scale, or direction unexpectedly across a cut. Confirm captions remain legible and are not cropped by camera movement.

## Caption hook

When captions or required on-screen copy are expected, run OCR when Tesseract is available and record each expected caption plus its recognition status, never arbitrary raw OCR or runtime UI text. `--ocr auto` may skip with a concrete unavailable-tool reason; `--ocr required` must fail when OCR cannot run or a required cue is absent at its own midpoint. Verification refuses existing reports or tool-owned snapshots unless `--force` is explicit, and never removes unrelated PNGs from the snapshot directory. It does not redact media or create a human-review/redaction receipt.

OCR is a hook, not proof of editorial correctness. Read the contact sheet too.

## Final report

A green report names every observed command and result. A skipped check is explicit. Do not infer that a video is correct from a green TypeScript build or a successful renderer exit.

## RecordedTour checks

`recorded:verify` checks the render against the resolved manifest and the normalized sources in `public/generated/recorded/<run-id>/`:

- provenance: source and audio digests match the manifest;
- H264, `yuv420p`, manifest dimensions, decoded frames equal to the manifest frame count, duration within tolerance, and a 48kHz audio stream;
- frame match: at 20, 50 and 80 percent of every clip, the render's video rectangle must score at least the SSIM threshold against the source frame the plan says is shown there, and no neighbouring source frame (n-2 to n+2) may score more than 0.002 higher. Captions and a full-layout heading chip are blacked out in both images before comparing. Two cases cannot prove timing and are reported "timing not proven", with the scene not marked proven: the source itself barely changes between neighbours, or a neighbour that looks different in the source scores within 0.002 of the expected frame, so the render cannot tell them apart. A neighbour that is the same picture, such as a frame repeated by the frame-rate conversion, may tie;
- required OCR (`--ocr required`) for every caption (read from the caption band crop) and every card title, with characters OCR cannot read, such as emoji, dropped from the expectation.

A frame mismatch fails the run, and `VERIFY.md` is still written first so the numbers are readable. Existing evidence needs `--force`. Read the contact sheet as well: SSIM and OCR do not judge layout taste.
