import assert from 'node:assert/strict';
import { test } from 'node:test';

import fixture from '../fixtures/narrated-browser-tour.json';
import { parseNarratedResolvedManifest } from './narrated-resolved-contracts';
import {
  deriveNarratedCamera,
  getActiveCaptionCues,
  getClickRipple,
  getCursorPosition,
  maxCursorInterpolationMs,
  prepareNarratedTimeline,
} from './narrated-timeline';

const manifest = parseNarratedResolvedManifest(fixture);
const telemetry = {
  schemaVersion: 1 as const,
  runId: 'demo-run',
  durationMs: 6_000,
  channels: ['cursor', 'click', 'element', 'scroll', 'route'] as const,
  events: [
    { channel: 'cursor' as const, seq: 0, tMs: 100, x: 0.1, y: 0.2 },
    { channel: 'cursor' as const, seq: 1, tMs: 300, x: 0.5, y: 0.6 },
    { channel: 'click' as const, seq: 2, tMs: 500, x: 0.7, y: 0.3 },
    {
      channel: 'element' as const,
      seq: 3,
      tMs: 500,
      rect: { x: 0.6, y: 0.2, width: 0.2, height: 0.2 },
    },
    { channel: 'scroll' as const, seq: 4, tMs: 1_000, x: 0, y: 0.5 },
    { channel: 'route' as const, seq: 5, tMs: 4_000, routeId: 'reports' },
  ],
};
const timeline = prepareNarratedTimeline(telemetry.events);

test('narrated timeline interpolates cursor holds and bounds click ripples', () => {
  const interpolated = getCursorPosition(timeline, 200);
  assert.ok(interpolated);
  assert.ok(Math.abs(interpolated.x - 0.3) < Number.EPSILON);
  assert.ok(Math.abs(interpolated.y - 0.4) < Number.EPSILON);
  assert.deepEqual(getCursorPosition(timeline, 350), {
    x: 0.5,
    y: 0.6,
  });
  assert.equal(getClickRipple(timeline, 500, 30)?.progress, 0);
  assert.equal(getClickRipple(timeline, 1_200, 30), null);
});

test('narrated timeline indexes the 10,000-event ceiling once', () => {
  const events = Array.from({ length: 10_000 }, (_, seq) => ({
    channel: 'cursor' as const,
    seq,
    tMs: seq,
    x: seq / 10_000,
    y: 0.5,
  }));
  const prepared = prepareNarratedTimeline(events);
  assert.equal(prepared.cursors.length, 10_000);
  assert.deepEqual(getCursorPosition(prepared, 9_999), {
    x: 0.9999,
    y: 0.5,
  });
});

test('narrated timeline keeps captions output-space and chooses active cues', () => {
  assert.deepEqual(getActiveCaptionCues(manifest.captions, 600), [
    manifest.captions[0],
  ]);
  assert.deepEqual(getActiveCaptionCues(manifest.captions, 2_000), []);
});

test('camera follows semantic geometry, route resets, and explicit overrides win', () => {
  const focused = deriveNarratedCamera({
    camera: manifest.project.camera,
    timeline,
    height: 720,
    overrides: [],
    timeMs: 550,
    width: 1280,
  });
  assert.ok(focused.scale > 1);
  assert.notEqual(focused.panX, 0);

  const reset = deriveNarratedCamera({
    camera: manifest.project.camera,
    timeline,
    height: 720,
    overrides: [],
    timeMs: 4_000,
    width: 1280,
  });
  assert.deepEqual(reset, { panX: 0, panY: 0, scale: 1 });

  const override = deriveNarratedCamera({
    camera: manifest.project.camera,
    timeline,
    height: 720,
    overrides: manifest.cameraOverrides,
    timeMs: 2_500,
    width: 1280,
  });
  assert.equal(override.scale, 1.3);

  const trimmedOverride = deriveNarratedCamera({
    camera: manifest.project.camera,
    timeline,
    height: 720,
    overrides: [
      {
        id: 'output-space-override',
        startMs: 400,
        endMs: 600,
        target: { x: 0.7, y: 0.3 },
        zoom: 1.3,
      },
    ],
    overrideTimeMs: 500,
    timeMs: 2_500,
    width: 1280,
  });
  assert.equal(trimmedOverride.scale, 1.3);
});

test('cursor holds still across idle gaps instead of drifting', () => {
  const idle = prepareNarratedTimeline([
    { channel: 'cursor', seq: 0, tMs: 1_000, x: 0.1, y: 0.1 },
    {
      channel: 'cursor',
      seq: 1,
      tMs: 1_000 + maxCursorInterpolationMs + 1,
      x: 0.9,
      y: 0.9,
    },
  ]);
  const midGap = getCursorPosition(idle, 1_000 + maxCursorInterpolationMs / 2);
  assert.deepEqual(midGap, { x: 0.1, y: 0.1 });

  const moving = prepareNarratedTimeline([
    { channel: 'cursor', seq: 0, tMs: 1_000, x: 0.2, y: 0.2 },
    { channel: 'cursor', seq: 1, tMs: 1_100, x: 0.4, y: 0.6 },
  ]);
  const midMove = getCursorPosition(moving, 1_050);
  assert.ok(midMove);
  assert.ok(midMove.x > 0.2 && midMove.x < 0.4);
  assert.ok(midMove.y > 0.2 && midMove.y < 0.6);
});
