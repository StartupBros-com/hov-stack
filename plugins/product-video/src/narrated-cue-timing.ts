import type { NarratedTelemetryEvent } from './narrated-contracts';

/**
 * Caption windows authored by hand drift from the footage. On the first narrated
 * tour every cue started 416-951ms *after* the route change it described, so the
 * voice always arrived once the screen had already moved on. Anchoring cue starts
 * to the telemetry that changed the screen removes the guess.
 */

/** Speech reads as "on cue" slightly after the paint, not simultaneous with it. */
export const cueLeadInMs = 120;

/** A cue anchored further than this from any event was never about that event. */
export const maxAnchorDriftMs = 2_500;

export type CueAnchor = {
  /** Telemetry time that changed what is on screen. */
  tMs: number;
  kind: 'route' | 'click';
};

export function collectCueAnchors(
  events: readonly NarratedTelemetryEvent[],
): CueAnchor[] {
  const anchors: CueAnchor[] = [];
  for (const event of events) {
    if (event.channel === 'route') {
      anchors.push({ tMs: event.tMs, kind: 'route' });
    } else if (event.channel === 'click') {
      anchors.push({ tMs: event.tMs, kind: 'click' });
    }
  }
  // Consecutive route events for the same navigation describe one screen change.
  return anchors.filter(
    (anchor, index) =>
      index === 0 || anchor.tMs - anchors[index - 1]!.tMs > 400,
  );
}

export type TimedCue = { startMs: number; endMs: number };

/**
 * Snap each cue start onto the nearest preceding screen change. Cues keep their
 * authored duration and order, and a cue with no plausible anchor is left alone
 * rather than dragged somewhere arbitrary.
 */
export function alignCuesToAnchors(
  cues: readonly TimedCue[],
  anchors: readonly CueAnchor[],
  durationMs: number,
  floorMs = 0,
): TimedCue[] {
  const aligned: TimedCue[] = [];
  // An anchor can sit before the delivered window when the head is trimmed;
  // snapping to it would push a cue outside the window entirely.
  let previousEnd = floorMs;

  for (const cue of cues) {
    const span = cue.endMs - cue.startMs;
    const candidate = anchors
      .filter((anchor) => anchor.tMs <= cue.startMs + maxAnchorDriftMs)
      .reduce<CueAnchor | undefined>((best, anchor) => {
        const bestDelta = best ? Math.abs(cue.startMs - best.tMs) : Infinity;
        return Math.abs(cue.startMs - anchor.tMs) < bestDelta ? anchor : best;
      }, undefined);

    let startMs = cue.startMs;
    if (
      candidate &&
      Math.abs(cue.startMs - candidate.tMs) <= maxAnchorDriftMs
    ) {
      startMs = candidate.tMs + cueLeadInMs;
    }
    startMs = Math.max(startMs, previousEnd);
    const endMs = Math.min(startMs + span, durationMs);
    aligned.push({ startMs, endMs });
    previousEnd = endMs;
  }

  return aligned;
}

/** How far each cue sits from the screen change it describes. */
export function measureCueLag(
  cues: readonly TimedCue[],
  anchors: readonly CueAnchor[],
): number[] {
  return cues.map((cue) => {
    const preceding = anchors.filter((anchor) => anchor.tMs <= cue.startMs);
    const nearest = preceding[preceding.length - 1];
    return nearest ? cue.startMs - nearest.tMs : cue.startMs;
  });
}
