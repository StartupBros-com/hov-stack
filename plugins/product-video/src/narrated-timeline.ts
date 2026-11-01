import type { NarratedTelemetryEvent } from './narrated-contracts';
import type {
  NarratedCaptionCue,
  NarratedResolvedManifest,
} from './narrated-resolved-contracts';

export type NarratedCameraState = {
  scale: number;
  panX: number;
  panY: number;
};

export type NarratedRipple = {
  x: number;
  y: number;
  progress: number;
};

type EventForChannel<T extends NarratedTelemetryEvent['channel']> = Extract<
  NarratedTelemetryEvent,
  { channel: T }
>;

type SemanticEvent = Extract<
  NarratedTelemetryEvent,
  { channel: 'click' | 'element' }
>;

export type PreparedNarratedTimeline = {
  clicks: readonly EventForChannel<'click'>[];
  cursors: readonly EventForChannel<'cursor'>[];
  elements: readonly EventForChannel<'element'>[];
  routes: readonly EventForChannel<'route'>[];
  semantic: readonly SemanticEvent[];
};

const clickRippleFrames = 18;
const cameraFocusMs = 1_500;
const routeResetMs = 400;

/**
 * Samples further apart than this are idle gaps, not motion. Interpolating
 * across them drags the pointer slowly over content it never visited.
 */
export const maxCursorInterpolationMs = 250;

function clamp(value: number, minimum: number, maximum: number) {
  return Math.min(maximum, Math.max(minimum, value));
}

function lastAtOrBefore<T extends { tMs: number }>(
  events: readonly T[],
  timeMs: number,
) {
  let low = 0;
  let high = events.length - 1;
  let match: T | undefined;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const candidate = events[middle]!;
    if (candidate.tMs <= timeMs) {
      match = candidate;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return match;
}

function firstAfter<T extends { tMs: number }>(
  events: readonly T[],
  timeMs: number,
) {
  let low = 0;
  let high = events.length - 1;
  let match: T | undefined;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const candidate = events[middle]!;
    if (candidate.tMs > timeMs) {
      match = candidate;
      high = middle - 1;
    } else {
      low = middle + 1;
    }
  }
  return match;
}

export function prepareNarratedTimeline(
  events: readonly NarratedTelemetryEvent[],
): PreparedNarratedTimeline {
  const clicks: EventForChannel<'click'>[] = [];
  const cursors: EventForChannel<'cursor'>[] = [];
  const elements: EventForChannel<'element'>[] = [];
  const routes: EventForChannel<'route'>[] = [];
  const semantic: SemanticEvent[] = [];

  for (const event of events) {
    if (event.channel === 'click') {
      clicks.push(event);
      semantic.push(event);
    } else if (event.channel === 'cursor') {
      cursors.push(event);
    } else if (event.channel === 'element') {
      elements.push(event);
      semantic.push(event);
    } else if (event.channel === 'route') {
      routes.push(event);
    }
  }

  return { clicks, cursors, elements, routes, semantic };
}

export function getCursorPosition(
  timeline: PreparedNarratedTimeline,
  timeMs: number,
) {
  if (timeline.cursors.length === 0 || timeMs < timeline.cursors[0]!.tMs) {
    return null;
  }

  const previous = lastAtOrBefore(timeline.cursors, timeMs);
  if (!previous) {
    return null;
  }
  const next = firstAfter(timeline.cursors, timeMs);
  if (!next || next.tMs - previous.tMs > maxCursorInterpolationMs) {
    return { x: previous.x, y: previous.y };
  }
  const progress = clamp(
    (timeMs - previous.tMs) / Math.max(1, next.tMs - previous.tMs),
    0,
    1,
  );

  // Catmull-Rom through the neighbouring samples. A straight lerp corners at
  // every sample, which reads as a faint zigzag once the pointer is moving.
  const index = timeline.cursors.indexOf(previous);
  const before = timeline.cursors[index - 1] ?? previous;
  const after = timeline.cursors[index + 2] ?? next;
  const continuous =
    next.tMs - before.tMs <= maxCursorInterpolationMs * 2 &&
    after.tMs - previous.tMs <= maxCursorInterpolationMs * 2;
  if (!continuous) {
    return {
      x: previous.x + (next.x - previous.x) * progress,
      y: previous.y + (next.y - previous.y) * progress,
    };
  }
  return {
    x: catmullRom(before.x, previous.x, next.x, after.x, progress),
    y: catmullRom(before.y, previous.y, next.y, after.y, progress),
  };
}

/** Smooths the path through four consecutive samples. */
export function catmullRom(
  p0: number,
  p1: number,
  p2: number,
  p3: number,
  t: number,
) {
  const t2 = t * t;
  const t3 = t2 * t;
  return (
    0.5 *
    (2 * p1 +
      (-p0 + p2) * t +
      (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
      (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
  );
}

export function getClickRipple(
  timeline: PreparedNarratedTimeline,
  timeMs: number,
  fps: number,
): NarratedRipple | null {
  const click = lastAtOrBefore(timeline.clicks, timeMs);
  if (!click) {
    return null;
  }
  const elapsedFrames = ((timeMs - click.tMs) * fps) / 1_000;
  if (elapsedFrames < 0 || elapsedFrames > clickRippleFrames) {
    return null;
  }
  return {
    x: click.x,
    y: click.y,
    progress: elapsedFrames / clickRippleFrames,
  };
}

export function getActiveCaptionCues(
  cues: readonly NarratedCaptionCue[],
  timeMs: number,
) {
  return cues.filter((cue) => cue.startMs <= timeMs && timeMs < cue.endMs);
}

function getLastRoute(timeline: PreparedNarratedTimeline, timeMs: number) {
  return lastAtOrBefore(timeline.routes, timeMs);
}

export function getNarratedFocusRect(
  timeline: PreparedNarratedTimeline,
  timeMs: number,
) {
  const lastRoute = getLastRoute(timeline, timeMs);
  const element = lastAtOrBefore(timeline.elements, timeMs);
  if (
    !element ||
    (lastRoute && element.tMs <= lastRoute.tMs) ||
    timeMs - element.tMs > cameraFocusMs
  ) {
    return null;
  }
  return element.rect;
}

function getLatestSemanticTarget(
  timeline: PreparedNarratedTimeline,
  timeMs: number,
) {
  const lastRoute = getLastRoute(timeline, timeMs);
  if (lastRoute && timeMs - lastRoute.tMs <= routeResetMs) {
    return null;
  }
  const event = lastAtOrBefore(timeline.semantic, timeMs);
  if (
    !event ||
    (lastRoute && event.tMs <= lastRoute.tMs) ||
    timeMs - event.tMs > cameraFocusMs
  ) {
    return null;
  }
  if (event.channel === 'element') {
    return {
      event,
      x: event.rect.x + event.rect.width / 2,
      y: event.rect.y + event.rect.height / 2,
    };
  }
  return { event, x: event.x, y: event.y };
}

function panToTarget({
  target,
  scale,
  width,
  height,
  safeMargin,
}: {
  target: { x: number; y: number };
  scale: number;
  width: number;
  height: number;
  safeMargin: number;
}) {
  const safeMarginX = width * safeMargin;
  const safeMarginY = height * safeMargin;
  const maxPanX = Math.max(0, ((scale - 1) * width) / 2 - safeMarginX);
  const maxPanY = Math.max(0, ((scale - 1) * height) / 2 - safeMarginY);
  return {
    panX: clamp((0.5 - target.x) * width * scale, -maxPanX, maxPanX),
    panY: clamp((0.5 - target.y) * height * scale, -maxPanY, maxPanY),
  };
}

export function deriveNarratedCamera({
  camera,
  timeline,
  overrides,
  overrideTimeMs,
  timeMs,
  width,
  height,
}: {
  camera: NarratedResolvedManifest['project']['camera'];
  timeline: PreparedNarratedTimeline;
  overrides: NarratedResolvedManifest['cameraOverrides'];
  overrideTimeMs?: number;
  timeMs: number;
  width: number;
  height: number;
}): NarratedCameraState {
  const resolvedOverrideTimeMs = overrideTimeMs ?? timeMs;
  const override = overrides.find(
    (candidate) =>
      candidate.startMs <= resolvedOverrideTimeMs &&
      resolvedOverrideTimeMs < candidate.endMs,
  );
  if (override) {
    const scale = clamp(override.zoom, 1, camera.maxZoom);
    return {
      scale,
      ...panToTarget({
        target: override.target,
        scale,
        width,
        height,
        safeMargin: camera.safeMargin,
      }),
    };
  }

  const target = getLatestSemanticTarget(timeline, timeMs);
  if (!target) {
    return { scale: 1, panX: 0, panY: 0 };
  }
  const elapsedMs = timeMs - target.event.tMs;
  const fadeIn = clamp(elapsedMs / 120, 0, 1);
  const fadeOut = clamp((cameraFocusMs - elapsedMs) / 250, 0, 1);
  const scale = clamp(
    1 + (Math.min(camera.maxZoom, 1.18) - 1) * fadeIn * fadeOut,
    1,
    camera.maxZoom,
  );
  return {
    scale,
    ...panToTarget({
      target,
      scale,
      width,
      height,
      safeMargin: camera.safeMargin,
    }),
  };
}

export function getNarratedSourceTimeMs(
  frame: number,
  fps: number,
  sourceStartMs: number,
) {
  return sourceStartMs + (frame * 1_000) / fps;
}
