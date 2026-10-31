import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildSyntheticNarratedCaptureBundle,
  buildSyntheticNarratedTelemetry,
  syntheticCaptureFilter,
  syntheticNarratedCaptions,
  syntheticNarratedDurationMs,
  syntheticNarratedMarker,
} from './narrated-fixture';
import { parseStrictSrt } from './narrated-media';

test('synthetic narrated fixture uses only canonical local assets and safe telemetry', () => {
  const runId = 'synthetic-test-run';
  const capture = buildSyntheticNarratedCaptureBundle(runId, {
    telemetrySha256: '1'.repeat(64),
    videoSha256: '2'.repeat(64),
  });
  const telemetry = buildSyntheticNarratedTelemetry(runId);

  assert.equal(capture.status, 'complete');
  assert.equal(
    capture.assets?.video,
    'generated/narrated/synthetic-test-run/capture.webm',
  );
  assert.equal(telemetry.durationMs, syntheticNarratedDurationMs);
  assert.deepEqual(
    telemetry.events.map((event) => event.channel),
    ['cursor', 'click', 'element', 'scroll', 'route'],
  );
});

test('synthetic fixture captions are strict operator-style SRT cues', () => {
  assert.deepEqual(
    parseStrictSrt(syntheticNarratedCaptions).map((cue) => cue.text),
    ['Open reports.', 'Review progress.'],
  );
});

test('synthetic fixture renders a visible clapperboard at its alignment marker', () => {
  assert.deepEqual(syntheticNarratedMarker, {
    type: 'clapperboard',
    tMs: 500,
  });
  assert.match(syntheticCaptureFilter, /between\(t,0\.5,1\.1\)/);
  assert.match(syntheticCaptureFilter, /x=500:y=168:w=280:h=38/);
});
