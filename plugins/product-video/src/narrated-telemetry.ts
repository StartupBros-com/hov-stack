import {
  type NarratedCaptureBundle,
  type NarratedTelemetry,
  type NarratedTelemetryEvent,
  maxNarratedDurationMs,
  maxNarratedEvents,
  parseNarratedTelemetry,
} from './narrated-contracts';

export const pointerThrottleMs = 50;
export const scrollCoalesceMs = 120;
export const maxNarratedTelemetryBytes = 5 * 1024 * 1024;

type UnsafeTelemetryEvent =
  | { channel: 'cursor'; x: number; y: number }
  | { channel: 'click'; x: number; y: number }
  | {
      channel: 'element';
      rect: { x: number; y: number; width: number; height: number };
    }
  | { channel: 'scroll'; x: number; y: number }
  | { channel: 'route'; routeId: string };

type RecorderOptions = {
  runId: string;
  maxEvents: number;
  maxBytes: number;
};

function assertNormalized(value: number) {
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error('Telemetry geometry must be normalized between 0 and 1');
  }
  return value;
}

function sanitizeEvent(event: UnsafeTelemetryEvent) {
  if (event.channel === 'route') {
    if (!/^[a-z0-9][a-z0-9-]*$/.test(event.routeId)) {
      throw new Error('Telemetry route IDs must use lowercase kebab-case');
    }
    return { channel: event.channel, routeId: event.routeId } as const;
  }
  if (event.channel === 'element') {
    const rect = {
      x: assertNormalized(event.rect.x),
      y: assertNormalized(event.rect.y),
      width: assertNormalized(event.rect.width),
      height: assertNormalized(event.rect.height),
    };
    if (
      rect.width === 0 ||
      rect.height === 0 ||
      rect.x + rect.width > 1 ||
      rect.y + rect.height > 1
    ) {
      throw new Error(
        'Telemetry element geometry must fit within the viewport',
      );
    }
    return { channel: event.channel, rect } as const;
  }
  return {
    channel: event.channel,
    x: assertNormalized(event.x),
    y: assertNormalized(event.y),
  } as const;
}

function estimatedBytes(runId: string, events: NarratedTelemetryEvent[]) {
  return Buffer.byteLength(
    JSON.stringify({
      schemaVersion: 1,
      runId,
      durationMs: maxNarratedDurationMs,
      channels: ['cursor', 'click', 'element', 'scroll', 'route'],
      events,
    }),
    'utf8',
  );
}

export function createTelemetryRecorder({
  runId,
  maxEvents,
  maxBytes,
}: RecorderOptions) {
  if (!/^[a-z0-9][a-z0-9-]*$/.test(runId)) {
    throw new Error('Telemetry run ID must use lowercase kebab-case');
  }
  if (
    !Number.isInteger(maxEvents) ||
    maxEvents < 1 ||
    maxEvents > maxNarratedEvents
  ) {
    throw new Error(
      `Telemetry event cap must be between 1 and ${maxNarratedEvents}`,
    );
  }
  if (
    !Number.isInteger(maxBytes) ||
    maxBytes < 1_024 ||
    maxBytes > maxNarratedTelemetryBytes
  ) {
    throw new Error(
      `Telemetry byte cap must be between 1024 and ${maxNarratedTelemetryBytes}`,
    );
  }

  const events: NarratedTelemetryEvent[] = [];
  let lastTime = -1;

  const record = (unsafeEvent: UnsafeTelemetryEvent, tMs: number) => {
    if (!Number.isInteger(tMs) || tMs < 0 || tMs < lastTime) {
      throw new Error(
        'Telemetry timestamps must be non-negative and monotonic',
      );
    }
    const sanitized = sanitizeEvent(unsafeEvent);
    const previous = events.at(-1);
    const canCoalesce =
      previous &&
      previous.channel === sanitized.channel &&
      ((sanitized.channel === 'cursor' &&
        tMs - previous.tMs < pointerThrottleMs) ||
        (sanitized.channel === 'scroll' &&
          tMs - previous.tMs < scrollCoalesceMs));

    if (canCoalesce) {
      const replacement = {
        ...sanitized,
        seq: previous.seq,
        tMs,
      } as NarratedTelemetryEvent;
      const candidate = [...events.slice(0, -1), replacement];
      if (estimatedBytes(runId, candidate) > maxBytes) {
        throw new Error('Telemetry byte cap exceeded');
      }
      events.splice(-1, 1, replacement);
      lastTime = tMs;
      return;
    }

    if (events.length >= maxEvents) {
      throw new Error('Telemetry event cap exceeded');
    }
    const next = {
      ...sanitized,
      seq: events.length,
      tMs,
    } as NarratedTelemetryEvent;
    if (estimatedBytes(runId, [...events, next]) > maxBytes) {
      throw new Error('Telemetry byte cap exceeded');
    }
    events.push(next);
    lastTime = tMs;
  };

  return {
    record,
    finalize(durationMs: number) {
      return parseNarratedTelemetry({
        schemaVersion: 1,
        runId,
        durationMs,
        channels: ['cursor', 'click', 'element', 'scroll', 'route'],
        events,
      });
    },
  };
}

export { parseNarratedTelemetry } from './narrated-contracts';

export function assertTelemetryMatchesCapture(
  telemetry: NarratedTelemetry,
  capture: NarratedCaptureBundle,
) {
  if (telemetry.runId !== capture.runId) {
    throw new Error('Telemetry run ID does not match the capture bundle');
  }
  if (!capture.durationMs || telemetry.durationMs !== capture.durationMs) {
    throw new Error(
      'Telemetry duration does not match the complete capture bundle',
    );
  }
  const declaredRoutes = new Set(capture.routeIds);
  for (const event of telemetry.events) {
    if (event.channel === 'route' && !declaredRoutes.has(event.routeId)) {
      throw new Error(
        `Telemetry contains an undeclared route ID: ${event.routeId}`,
      );
    }
  }
}
