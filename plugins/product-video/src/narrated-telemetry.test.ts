import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  createTelemetryRecorder,
  parseNarratedTelemetry,
} from './narrated-telemetry';

test('telemetry recorder keeps safe normalized events monotonic', () => {
  const recorder = createTelemetryRecorder({
    maxBytes: 20_000,
    maxEvents: 20,
    runId: 'demo-run',
  });
  recorder.record({ channel: 'cursor', x: 0.1, y: 0.2 }, 100);
  recorder.record({ channel: 'click', x: 0.25, y: 0.4 }, 200);
  recorder.record(
    { channel: 'element', rect: { height: 0.2, width: 0.3, x: 0.1, y: 0.2 } },
    200,
  );
  recorder.record({ channel: 'scroll', x: 0, y: 0.6 }, 500);
  recorder.record({ channel: 'route', routeId: 'reports' }, 800);

  const telemetry = recorder.finalize(1_000);
  assert.deepEqual(
    telemetry.events.map((event) => event.seq),
    [0, 1, 2, 3, 4],
  );
  assert.equal(telemetry.events.at(-1)?.tMs, 800);
  assert.deepEqual(telemetry.channels, [
    'cursor',
    'click',
    'element',
    'scroll',
    'route',
  ]);
});

test('telemetry recorder throttles pointer moves and coalesces scroll events', () => {
  const recorder = createTelemetryRecorder({
    maxBytes: 20_000,
    maxEvents: 20,
    runId: 'demo-run',
  });
  recorder.record({ channel: 'cursor', x: 0.1, y: 0.1 }, 100);
  recorder.record({ channel: 'cursor', x: 0.2, y: 0.2 }, 120);
  recorder.record({ channel: 'scroll', x: 0, y: 0.1 }, 300);
  recorder.record({ channel: 'scroll', x: 0, y: 0.3 }, 350);

  const telemetry = recorder.finalize(1_000);
  assert.deepEqual(telemetry.events, [
    { channel: 'cursor', seq: 0, tMs: 120, x: 0.2, y: 0.2 },
    { channel: 'scroll', seq: 1, tMs: 350, x: 0, y: 0.3 },
  ]);
});

test('telemetry refuses unsafe geometry, non-monotonic time, event caps, and oversized payloads', () => {
  const recorder = createTelemetryRecorder({
    maxBytes: 20_000,
    maxEvents: 1,
    runId: 'demo-run',
  });
  assert.throws(
    () => recorder.record({ channel: 'cursor', x: 1.2, y: 0.2 }, 10),
    /normalized/i,
  );
  recorder.record({ channel: 'cursor', x: 0.2, y: 0.2 }, 10);
  assert.throws(
    () => recorder.record({ channel: 'click', x: 0.2, y: 0.2 }, 11),
    /event cap/i,
  );

  assert.throws(
    () =>
      parseNarratedTelemetry({
        schemaVersion: 1,
        runId: 'demo-run',
        durationMs: 1_000,
        channels: ['cursor', 'click', 'element', 'scroll', 'route'],
        events: [
          { channel: 'cursor', seq: 1, tMs: 100, x: 0.1, y: 0.1 },
          { channel: 'click', seq: 0, tMs: 50, x: 0.1, y: 0.1 },
        ],
      }),
    /sequence|monotonic/i,
  );
  assert.throws(
    () =>
      parseNarratedTelemetry({
        schemaVersion: 1,
        runId: 'demo-run',
        durationMs: 1_000,
        channels: ['cursor', 'click', 'element', 'scroll', 'route'],
        events: [{ channel: 'cursor', seq: 0, tMs: 1_000, x: 0.1, y: 0.1 }],
      }),
    /precede/i,
  );
});

test('telemetry byte caps include the finalized telemetry envelope', () => {
  const recorder = createTelemetryRecorder({
    maxBytes: 1_024,
    maxEvents: 100,
    runId: 'demo-run',
  });

  let capError: Error | undefined;
  for (let index = 0; index < 100; index += 1) {
    try {
      recorder.record(
        { channel: 'click', x: 0.123456789, y: 0.987654321 },
        index * 10,
      );
    } catch (error) {
      capError = error instanceof Error ? error : new Error(String(error));
      break;
    }
  }

  assert.match(capError?.message ?? '', /byte cap/i);
});
