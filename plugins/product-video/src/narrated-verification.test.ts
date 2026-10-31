import assert from 'node:assert/strict';
import { test } from 'node:test';

import fixture from '../fixtures/narrated-browser-tour.json';
import { parseNarratedResolvedManifest } from './narrated-resolved-contracts';
import {
  assertCaptionMidpointOcr,
  assertNarratedSamplePlanWithinBounds,
  buildNarratedSamplePlan,
  isGeneratedNarratedSnapshotName,
  maxNarratedVerificationSamples,
  validateNarratedRenderProbe,
  validateNarratedSourceProbe,
} from './narrated-verification';

const manifest = parseNarratedResolvedManifest(fixture);
const validProbe = {
  format: { duration: '6.000000', size: '240000' },
  streams: [
    {
      codec_name: 'h264',
      codec_type: 'video',
      height: 720,
      nb_read_frames: '180',
      pix_fmt: 'yuv420p',
      width: 1280,
    },
    { codec_name: 'aac', codec_type: 'audio', sample_rate: '48000' },
  ],
};

test('narrated verification requires an audio stream and exact delivery video', () => {
  const verified = validateNarratedRenderProbe(validProbe, manifest);
  assert.equal(verified.audio.sampleRate, 48_000);
  assert.equal(verified.video.frameCount, 180);
  assert.throws(
    () =>
      validateNarratedRenderProbe(
        { ...validProbe, streams: [validProbe.streams[0]!] },
        manifest,
      ),
    /audio stream/i,
  );
});

test('narrated source verification rejects missing, mismatched, and invalid video', () => {
  assert.deepEqual(validateNarratedSourceProbe(validProbe, manifest), {
    durationMs: 6_000,
  });
  assert.throws(
    () =>
      validateNarratedSourceProbe(
        { ...validProbe, streams: [validProbe.streams[1]!] },
        manifest,
      ),
    /no video stream/i,
  );
  assert.throws(
    () =>
      validateNarratedSourceProbe(
        {
          ...validProbe,
          streams: [{ ...validProbe.streams[0]!, width: 640 }],
        },
        manifest,
      ),
    /dimensions/i,
  );
  assert.throws(
    () =>
      validateNarratedSourceProbe(
        { ...validProbe, format: { ...validProbe.format, duration: '0' } },
        manifest,
      ),
    /positive duration/i,
  );
});

test('narrated sample plan covers marker, semantic telemetry, captions, and bounds', () => {
  const samples = buildNarratedSamplePlan(manifest);
  assert.equal(
    samples.find((sample) => sample.label === 'first')?.milliseconds,
    0,
  );
  assert.ok(
    (samples.find((sample) => sample.label === 'last')?.milliseconds ??
      Infinity) <=
      manifest.durationMs - 2_000 / manifest.project.fps,
  );
  const labels = samples.map((sample) => sample.label);
  for (const label of [
    'first',
    'last',
    'marker',
    'click-1',
    'focus-2',
    'scroll-settled-3',
    'route-4',
    'caption-cue-one-start',
    'caption-cue-one-mid',
    'caption-cue-one-end',
  ]) {
    assert.ok(labels.includes(label));
  }
  assert.doesNotThrow(() =>
    assertNarratedSamplePlanWithinBounds(samples, manifest.durationMs),
  );
  assert.throws(
    () =>
      assertNarratedSamplePlanWithinBounds(
        [...samples, { label: 'overflow', milliseconds: 6_000 }],
        manifest.durationMs,
      ),
    /overflow/i,
  );
});

test('required OCR binds each caption to its own midpoint', () => {
  const samples = buildNarratedSamplePlan(manifest);
  const texts = samples.map((sample) =>
    sample.label === 'caption-cue-one-mid'
      ? 'Open reports.'
      : sample.label === 'caption-cue-two-mid'
        ? 'Review progress.'
        : '',
  );
  assert.doesNotThrow(() =>
    assertCaptionMidpointOcr(samples, texts, manifest.captions),
  );
  const missingSecondCueText = texts.map((text, index) =>
    samples[index]!.label === 'caption-cue-two-mid' ? '' : text,
  );
  assert.throws(
    () =>
      assertCaptionMidpointOcr(
        samples,
        missingSecondCueText,
        manifest.captions,
      ),
    /cue-two-mid/i,
  );
});

test('resolved manifests reject evidence plans that cannot be fully verified', () => {
  assert.throws(
    () =>
      parseNarratedResolvedManifest({
        ...fixture,
        telemetry: {
          ...fixture.telemetry,
          events: Array.from(
            { length: maxNarratedVerificationSamples },
            (_, seq) => ({
              channel: 'click',
              seq,
              tMs: 100 + seq,
              x: 0.5,
              y: 0.5,
            }),
          ),
        },
      }),
    /evidence plan exceeds/i,
  );
  assert.ok(
    isGeneratedNarratedSnapshotName('narrated-browser-tour-1000-click-10.png'),
  );
});

test('scroll evidence settles within the final source frame', () => {
  const nearEndScroll = parseNarratedResolvedManifest({
    ...fixture,
    telemetry: {
      ...fixture.telemetry,
      events: [
        {
          channel: 'scroll',
          seq: 0,
          tMs: fixture.durationMs - 1,
          x: 0,
          y: 0.5,
        },
      ],
    },
  });
  const samples = buildNarratedSamplePlan(nearEndScroll);
  const settled = samples.find((sample) => sample.label === 'scroll-settled-0');
  assert.ok(settled);
  assert.ok(settled.milliseconds < nearEndScroll.durationMs);
  assert.doesNotThrow(() =>
    assertNarratedSamplePlanWithinBounds(samples, nearEndScroll.durationMs),
  );
});
