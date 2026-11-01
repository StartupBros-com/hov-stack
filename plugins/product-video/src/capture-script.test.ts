import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  buildHeroScript,
  parseCaptureDimensions,
  parseCdpEndpoint,
} from './capture-script';
import { captureScenarioSchema } from './contracts';

const scenario = captureScenarioSchema.parse({
  baseUrl: 'https://prbot.ai/home',
  allowedHosts: ['prbot.ai'],
  steps: [
    {
      type: 'chapter',
      title: 'Open the workspace',
      description: 'Start from the dashboard',
      durationMs: 1500,
    },
    { type: 'goto', path: '/home/example', waitFor: 'networkidle' },
    { type: 'click', selector: '[data-test="members"]', pauseAfterMs: 700 },
    { type: 'fill', selector: '[data-test="search"]', value: 'Example' },
    { type: 'pause', durationMs: 900 },
  ],
});

test('buildHeroScript produces a deterministic bounded screencast', () => {
  const options = {
    scenario,
    outputPath: '/work/out/demo.webm',
    width: 1280,
    height: 720,
  };
  const first = buildHeroScript(options);
  const second = buildHeroScript(options);

  assert.equal(first, second);
  assert.match(first, /page\.screencast\.start/);
  assert.match(first, /page\.screencast\.showChapter/);
  assert.match(first, /allowedHosts\.includes/);
  assert.match(first, /assertAllowed\(page\.url\(\)\)/);
  assert.match(first, /autocomplete/);
  assert.match(first, /pressSequentially/);
  assert.match(first, /page\.screencast\.stop/);
  assert.doesNotMatch(first, /not-a-real-password|secret-value/i);
});

test('parseCdpEndpoint accepts loopback and refuses remote browser endpoints', () => {
  assert.equal(
    parseCdpEndpoint('http://127.0.0.1:9223'),
    'http://127.0.0.1:9223/',
  );
  assert.throws(
    () => parseCdpEndpoint('http://browser.example.com:9223'),
    /loopback/i,
  );
  assert.throws(() => parseCdpEndpoint('file:///tmp/socket'), /http/i);
});

test('parseCaptureDimensions accepts bounded positive dimensions', () => {
  assert.deepEqual(parseCaptureDimensions('1280', '720'), {
    width: 1280,
    height: 720,
  });
  assert.throws(
    () => parseCaptureDimensions('0', '720'),
    /between 320 and 7680/i,
  );
  assert.throws(
    () => parseCaptureDimensions('1280', '99999'),
    /between 320 and 7680/i,
  );
});

test('buildHeroScript JSON-escapes scenario content', () => {
  const script = buildHeroScript({
    scenario: captureScenarioSchema.parse({
      baseUrl: 'https://prbot.ai/home',
      allowedHosts: ['prbot.ai'],
      steps: [
        {
          type: 'chapter',
          title: 'Quote: "safe"',
          description: 'Line one\nLine two',
        },
      ],
    }),
    outputPath: '/work/out/demo.webm',
    width: 1280,
    height: 720,
  });

  assert.match(script, /Quote: \\"safe\\"/);
  assert.match(script, /Line one\\nLine two/);
});
