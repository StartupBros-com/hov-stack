import assert from 'node:assert/strict';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

import scenarioFixture from '../fixtures/narrated-scenario.example.json';
import { buildNarratedCapabilityProbe } from './narrated-capture-probe';
import { buildNarratedCaptureScript } from './narrated-capture-script';
import { parseNarratedScenario } from './narrated-contracts';
import { getNarratedRunPaths } from './narrated-files';

const scenario = parseNarratedScenario(scenarioFixture);

test('narrated capture script is deterministic and records only safe telemetry', () => {
  const options = {
    scenario,
    paths: getNarratedRunPaths('demo-run'),
  };
  const first = buildNarratedCaptureScript(options);
  const second = buildNarratedCaptureScript(options);

  assert.equal(first, second);
  assert.match(first, /page\.screencast\.start/);
  // The alignment clapperboard is no longer painted: telemetry and video
  // share an origin by construction, and the overlay leaked into deliverables.
  assert.doesNotMatch(first, /CAPTURE ALIGNMENT MARKER/);
  assert.match(first, /markerTimeMs = 0;/);
  assert.match(first, /context\.route/);
  assert.match(first, /popup/);
  assert.match(first, /download/);
  assert.match(first, /pointermove/);
  assert.match(first, /scroll/);
  assert.match(first, /locator\.count/);
  assert.match(first, /locator\.evaluate/);
  assert.match(first, /prohibitedTargetPattern/);
  assert.match(first, /telemetry\.v1\.json/);
  assert.match(first, /captureStartedAt = Date\.now\(\);/);
  assert.match(first, /markerTimeMs = 0;/);
  assert.match(first, /Emulation\.setDeviceMetricsOverride/);
  assert.match(first, /Emulation\.clearDeviceMetricsOverride/);
  assert.match(first, /page\.mouse\.move/);
  assert.match(first, /marker: \{type: 'clapperboard', tMs: markerTimeMs\}/);
  assert.match(first, /link\(temporaryPath, targetPath\)/);
  assert.match(first, /chmod\(output\.videoPath, 0o600\)/);
  assert.match(first, /createHash\('sha256'\)/);
  assert.match(first, /declared\.pathname === target\.pathname/);
  assert.match(first, /page\.frames\(\)\.find/);
  assert.match(first, /__narratedTelemetryDrainV1/);
  assert.match(first, /digests: \{videoSha256, telemetrySha256\}/);
  assert.doesNotMatch(first, /\.fill\(|pressSequentially|clipboard/i);
  assert.doesNotMatch(first, /selector:\s*step\.selector/);
});

test('narrated capture aborts before recording an unsafe child frame', async () => {
  const script = buildNarratedCaptureScript({
    paths: getNarratedRunPaths('unsafe-child-frame-run'),
    scenario,
  });
  const capture = runInNewContext(`(${script})`, {
    Buffer,
    URL,
    clearTimeout,
    process,
    setTimeout,
  }) as (page: unknown) => Promise<void>;
  const mainFrame = { url: () => 'https://prbot.ai/home' };
  let captureStarted = false;
  const context = {
    route: async () => undefined,
    unroute: async () => undefined,
  };
  const page = {
    context: () => context,
    evaluate: async () => undefined,
    exposeBinding: async () => undefined,
    frames: () => [
      mainFrame,
      { url: () => 'https://checkout.stripe.com/session' },
    ],
    isClosed: () => false,
    mainFrame: () => mainFrame,
    off: () => undefined,
    on: () => undefined,
    screencast: {
      showChapter: async () => undefined,
      start: async () => {
        captureStarted = true;
      },
      stop: async () => undefined,
    },
    url: () => 'https://prbot.ai/home',
  };

  await assert.rejects(() => capture(page), /unsafe child-frame/i);
  assert.equal(captureStarted, false);
});

test('narrated capability probe rejects unsafe frames before temporary recording', async () => {
  const script = buildNarratedCapabilityProbe('/safe/probe.webm', scenario);
  const probe = runInNewContext(`(${script})`, { URL }) as (
    page: unknown,
  ) => Promise<void>;
  let captureStarted = false;
  const page = {
    context: () => ({
      newCDPSession: () => undefined,
      route: () => undefined,
      unroute: () => undefined,
    }),
    evaluate: async () => true,
    exposeBinding: () => undefined,
    frames: () => [
      { url: () => 'https://prbot.ai/home' },
      { url: () => 'https://checkout.stripe.com/session' },
    ],
    goto: () => undefined,
    isClosed: () => false,
    locator: () => ({
      boundingBox: async () => ({ height: 10, width: 10, x: 0, y: 0 }),
      count: async () => 1,
      evaluate: async () => true,
    }),
    mainFrame: () => undefined,
    mouse: { move: () => undefined, wheel: () => undefined },
    off: () => undefined,
    on: () => undefined,
    screencast: {
      showChapter: async () => undefined,
      start: async () => {
        captureStarted = true;
      },
      stop: async () => undefined,
    },
    url: () => 'https://prbot.ai/home',
    waitForTimeout: () => undefined,
  };

  await assert.rejects(() => probe(page), /unsafe frame before probe/i);
  assert.equal(captureStarted, false);
});

test('narrated capture capability probe executes the adapters used by v1', () => {
  const probe = buildNarratedCapabilityProbe('/safe/probe.webm', scenario);
  for (const capability of [
    'screencast.start',
    'screencast.stop',
    'screencast.showChapter',
    'context.route',
    'context.newCDPSession',
    'locator.boundingBox',
    'page.mouse.move',
    'page.exposeBinding',
    'page.evaluate',
    'page.goto',
    'page.isClosed',
    'page.frames',
    'page.locator',
    'page.mouse.wheel',
    'page.off',
    'page.on',
    'page.url',
    'page.waitForTimeout',
  ]) {
    assert.match(probe, new RegExp(capability.replace('.', '\\.')));
  }
  assert.match(probe, /path: "\/safe\/probe\.webm"/);
  assert.match(probe, /await page\.screencast\.start/);
  assert.match(probe, /await page\.screencast\.showChapter/);
  assert.match(probe, /await page\.screencast\.stop/);
  assert.doesNotMatch(probe, /fill|pressSequentially/);
});
