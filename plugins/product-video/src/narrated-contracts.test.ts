import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  type NarratedScenario,
  getNarratedCaptureLayout,
  narratedCaptureBundleSchema,
  narratedScenarioSchema,
} from './narrated-contracts';
import {
  getNarratedDurationInFrames,
  parseNarratedResolvedManifest,
} from './narrated-resolved-contracts';

export const validNarratedScenario: NarratedScenario = {
  schemaVersion: 1,
  id: 'demo-browser-tour',
  project: {
    schemaVersion: 1,
    id: 'demo-product',
    compositionId: 'NarratedBrowserTour',
    viewport: { width: 1280, height: 720 },
    fps: 30,
    captureScale: 1,
    colors: {
      matte: '#07111f',
      cursor: '#ffffff',
      focus: '#2dd4bf',
      click: '#fb7185',
      captionBackground: '#07111f',
      captionForeground: '#ffffff',
    },
    camera: { maxZoom: 1.45, safeMargin: 0.04 },
  },
  baseUrl: 'https://demo.example.test/home',
  allowedHosts: ['demo.example.test'],
  routes: [
    { id: 'home', path: '/home' },
    { id: 'reports', path: '/reports' },
  ],
  maxDurationMs: 6_000,
  maxEvents: 500,
  steps: [
    { type: 'chapter', title: 'Open the workspace', durationMs: 800 },
    { type: 'goto', routeId: 'home', waitFor: 'load' },
    {
      type: 'click',
      selector: '[data-test="reports"]',
      approachMs: 400,
      pauseAfterMs: 400,
    },
    {
      type: 'move',
      selector: '[data-test="summary"]',
      durationMs: 400,
      pauseAfterMs: 200,
    },
    { type: 'scroll', deltaY: 420, pauseAfterMs: 500 },
    { type: 'pause', durationMs: 500 },
  ],
};

export const validResolvedManifest = {
  schemaVersion: 1,
  compositionId: 'NarratedBrowserTour',
  runId: 'demo-run',
  project: validNarratedScenario.project,
  durationMs: 6_000,
  source: {
    video: 'generated/narrated/demo-run/capture.webm',
    videoSha256: '1'.repeat(64),
    telemetry: 'generated/narrated/demo-run/telemetry.v1.json',
    telemetrySha256: '2'.repeat(64),
    sourceStartMs: 0,
    sourceEndMs: 6_000,
    marker: { type: 'clapperboard', tMs: 500 },
  },
  telemetry: {
    schemaVersion: 1,
    runId: 'demo-run',
    durationMs: 6_000,
    channels: ['cursor', 'click', 'element', 'scroll', 'route'],
    events: [],
  },
  narration: {
    audio: 'generated/narrated/demo-run/narration.v1.wav',
    audioSha256: '3'.repeat(64),
    offsetMs: 0,
  },
  captions: [
    { id: 'caption-one', startMs: 500, endMs: 2_000, text: 'Open reports.' },
    {
      id: 'caption-two',
      startMs: 2_200,
      endMs: 4_000,
      text: 'Review progress.',
    },
  ],
  cameraOverrides: [
    {
      id: 'reports-focus',
      startMs: 2_000,
      endMs: 3_000,
      target: { x: 0.7, y: 0.3 },
      zoom: 1.3,
    },
  ],
};

test('narrated scenario accepts only bounded safe actions', () => {
  const parsed = narratedScenarioSchema.parse(validNarratedScenario);
  assert.equal(parsed.steps.length, 6);
  assert.equal(parsed.project.compositionId, 'NarratedBrowserTour');

  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        steps: [{ type: 'fill', selector: '#name', value: 'nope' }],
      }),
    /matching discriminator|bounded action/i,
  );
});

test('narrated scenario refuses credential, login, query, hash, and off-host targets', () => {
  for (const selector of [
    'input[type="password"]',
    '[data-test="login"]',
    '[data-test="enable-microphone"]',
    '[data-test="publish-tour"]',
  ]) {
    assert.throws(
      () =>
        narratedScenarioSchema.parse({
          ...validNarratedScenario,
          steps: [{ type: 'click', selector }],
        }),
      /unsafe|credential|login|mfa|prohibited/i,
    );
  }
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        baseUrl: 'https://demo.example.test/home?token=unsafe',
      }),
    /query|hash/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        routes: [{ id: 'outside', path: 'https://other.example.test/' }],
        steps: [{ type: 'pause', durationMs: 500 }],
      }),
    /route path/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        routes: [{ id: 'hashed', path: '/home#settings' }],
        steps: [{ type: 'pause', durationMs: 500 }],
      }),
    /route path/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        routes: [{ id: 'login', path: '/login' }],
        steps: [{ type: 'pause', durationMs: 500 }],
      }),
    /route path/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        baseUrl: 'https://demo.example.test/recovery',
      }),
    /base URL/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        routes: [{ id: 'encoded-query', path: '/home%3Ftoken=unsafe' }],
        steps: [{ type: 'pause', durationMs: 500 }],
      }),
    /route path/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        routes: [
          { id: 'first-home', path: '/home' },
          { id: 'second-home', path: '/home' },
        ],
        steps: [{ type: 'pause', durationMs: 500 }],
      }),
    /unambiguous/i,
  );
});

test('narrated scenario rejects ambiguous hosts, routes, and wait budgets', () => {
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        allowedHosts: ['other.example.test'],
      }),
    /base URL host/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        allowedHosts: ['demo.example.test', 'demo.example.test'],
      }),
    /hosts must be unique/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        maxDurationMs: 1_000,
        steps: [{ type: 'pause', durationMs: 600 }],
      }),
    /must fit inside/i,
  );
  assert.throws(
    () =>
      narratedScenarioSchema.parse({
        ...validNarratedScenario,
        steps: [{ type: 'goto', routeId: 'missing-route', waitFor: 'load' }],
      }),
    /unknown declared route/i,
  );
});

test('resolved manifest is local, frame-addressable, and rejects overlapping cues', () => {
  const parsed = parseNarratedResolvedManifest(validResolvedManifest);
  assert.equal(getNarratedDurationInFrames(parsed), 180);

  assert.throws(
    () =>
      parseNarratedResolvedManifest({
        ...validResolvedManifest,
        source: {
          ...validResolvedManifest.source,
          video: 'https://cdn.example.test/capture.webm',
        },
      }),
    /local public asset/i,
  );
  assert.throws(
    () =>
      parseNarratedResolvedManifest({
        ...validResolvedManifest,
        captions: [
          validResolvedManifest.captions[0],
          {
            id: 'overlap',
            startMs: 1_900,
            endMs: 2_500,
            text: 'Overlaps.',
          },
        ],
      }),
    /overlap/i,
  );
});

test('capture bundles keep aborted runs non-renderable', () => {
  const complete = narratedCaptureBundleSchema.parse({
    schemaVersion: 1,
    kind: 'narrated-capture-bundle',
    status: 'complete',
    renderable: true,
    runId: 'demo-run',
    scenarioId: validNarratedScenario.id,
    project: validNarratedScenario.project,
    routeIds: ['home', 'reports'],
    viewport: validNarratedScenario.project.viewport,
    fps: 30,
    durationMs: 6_000,
    marker: { type: 'clapperboard', tMs: 500 },
    assets: {
      video: 'generated/narrated/demo-run/capture.webm',
      telemetry: 'generated/narrated/demo-run/telemetry.v1.json',
    },
    digests: {
      telemetrySha256: '2'.repeat(64),
      videoSha256: '1'.repeat(64),
    },
  });
  assert.equal(complete.status, 'complete');

  const aborted = narratedCaptureBundleSchema.parse({
    schemaVersion: 1,
    kind: 'narrated-capture-bundle',
    status: 'aborted',
    renderable: false,
    runId: 'demo-run',
    scenarioId: validNarratedScenario.id,
    project: validNarratedScenario.project,
    routeIds: ['home', 'reports'],
    viewport: validNarratedScenario.project.viewport,
    fps: 30,
  });
  assert.equal(aborted.renderable, false);
  assert.throws(
    () => narratedCaptureBundleSchema.parse({ ...aborted, renderable: true }),
    /renderable/i,
  );
});

test('capture scale must divide the viewport into whole CSS pixels', () => {
  const withScale = (
    viewport: { width: number; height: number },
    captureScale: number,
  ) =>
    narratedScenarioSchema.parse({
      ...validNarratedScenario,
      project: { ...validNarratedScenario.project, captureScale, viewport },
    });

  const hiDpi = withScale({ width: 1920, height: 1080 }, 1.5);
  assert.deepEqual(getNarratedCaptureLayout(hiDpi.project), {
    width: 1280,
    height: 720,
  });

  assert.throws(
    () => withScale({ width: 1280, height: 720 }, 1.5),
    /whole CSS pixel layout/i,
  );
  assert.throws(
    () => withScale({ width: 960, height: 720 }, 3),
    /at least 320 CSS pixels/i,
  );
});
