import { getNarratedDurationToleranceMs } from './narrated-duration';
import {
  type NarratedCaptureBundle,
  assertRenderableNarratedCapture,
  maxNarratedEvidenceSamples,
} from './narrated-contracts';
import type {
  NarratedCaptionCue,
  NarratedResolvedManifest,
} from './narrated-resolved-contracts';
import {
  type ProbeResult,
  assertRequiredOcrText,
  validateProbe,
} from './verification';

type NarratedProbeStream = NonNullable<ProbeResult['streams']>[number] & {
  codec_type?: string;
  sample_rate?: string;
};

export type NarratedProbeResult = Omit<ProbeResult, 'streams'> & {
  streams?: NarratedProbeStream[];
};

export type NarratedVerificationSample = {
  label: string;
  milliseconds: number;
};

export type VerifiedNarratedRender = {
  video: ReturnType<typeof validateProbe>;
  audio: { codec: string; sampleRate?: number };
};

export const maxNarratedVerificationSamples = maxNarratedEvidenceSamples;

const narratedSnapshotPattern =
  /^narrated-browser-tour-(?:contact-sheet|\d+-[a-z0-9-]+)\.png$/;

function positiveInteger(value: string | undefined) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : undefined;
}

export function validateNarratedRenderProbe(
  probe: NarratedProbeResult,
  manifest: NarratedResolvedManifest,
): VerifiedNarratedRender {
  const videoStream = probe.streams?.find(
    (stream) => stream.codec_type === 'video' || stream.width !== undefined,
  );
  if (!videoStream) {
    throw new Error('Narrated verification found no video stream');
  }
  const video = validateProbe(
    {
      format: probe.format,
      streams: [videoStream],
    },
    manifest.project.viewport,
  );
  const audioStream = probe.streams?.find(
    (stream) => stream.codec_type === 'audio',
  );
  if (!audioStream?.codec_name) {
    throw new Error('Narrated verification found no audio stream');
  }
  const sampleRate = positiveInteger(audioStream.sample_rate);
  if (sampleRate !== 48_000) {
    throw new Error('Narrated verification requires 48kHz rendered audio');
  }
  return {
    video,
    audio: {
      codec: audioStream.codec_name,
      sampleRate,
    },
  };
}

export function validateNarratedSourceProbe(
  probe: NarratedProbeResult,
  manifest: NarratedResolvedManifest,
) {
  const videoStream = probe.streams?.find(
    (stream) => stream.codec_type === 'video' || stream.width !== undefined,
  );
  if (!videoStream) {
    throw new Error('Narrated capture source has no video stream');
  }
  if (
    videoStream.width !== manifest.project.viewport.width ||
    videoStream.height !== manifest.project.viewport.height
  ) {
    throw new Error(
      'Narrated capture source dimensions do not match the manifest',
    );
  }
  const durationSeconds = Number(probe.format?.duration);
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    throw new Error('Narrated capture source has no positive duration');
  }
  return { durationMs: Math.round(durationSeconds * 1_000) };
}

export function assertNarratedDurationMatches(
  observedDurationMs: number,
  manifest: NarratedResolvedManifest,
) {
  const toleranceMs = getNarratedDurationToleranceMs(manifest.project.fps);
  if (Math.abs(observedDurationMs - manifest.durationMs) > toleranceMs) {
    throw new Error(
      `Narrated duration drift exceeds ${toleranceMs}ms; refusing to hide source/render mismatch`,
    );
  }
}

export function assertNarratedManifestMatchesCapture(
  manifest: NarratedResolvedManifest,
  capture: NarratedCaptureBundle,
) {
  const completeCapture = assertRenderableNarratedCapture(capture);
  if (
    JSON.stringify(manifest.project) !== JSON.stringify(completeCapture.project)
  ) {
    throw new Error(
      'Resolved manifest project does not match the capture bundle',
    );
  }
  if (
    manifest.source.video !== completeCapture.assets.video ||
    manifest.source.videoSha256 !== completeCapture.digests.videoSha256 ||
    manifest.source.telemetry !== completeCapture.assets.telemetry ||
    manifest.source.telemetrySha256 !== completeCapture.digests.telemetrySha256
  ) {
    throw new Error(
      'Resolved manifest source assets do not match the capture bundle',
    );
  }
  if (
    manifest.source.marker.type !== completeCapture.marker.type ||
    manifest.source.marker.tMs !== completeCapture.marker.tMs
  ) {
    throw new Error(
      'Resolved manifest marker does not match the capture bundle',
    );
  }
  if (
    manifest.source.sourceStartMs < 0 ||
    manifest.source.sourceEndMs > completeCapture.durationMs
  ) {
    throw new Error(
      'Resolved manifest source window exceeds the capture bundle',
    );
  }
  if (manifest.telemetry.durationMs !== completeCapture.durationMs) {
    throw new Error(
      'Resolved manifest telemetry duration does not match the capture bundle',
    );
  }
}

function addSample(
  samples: NarratedVerificationSample[],
  label: string,
  milliseconds: number,
) {
  if (samples.some((sample) => sample.label === label)) {
    throw new Error(`Narrated sample plan has a duplicate label: ${label}`);
  }
  if (samples.length >= maxNarratedVerificationSamples) {
    throw new Error(
      `Narrated sample plan exceeds its ${maxNarratedVerificationSamples}-sample evidence cap`,
    );
  }
  samples.push({ label, milliseconds });
}

export function buildNarratedSamplePlan(manifest: NarratedResolvedManifest) {
  const samples: NarratedVerificationSample[] = [];
  const frameMs = 1_000 / manifest.project.fps;
  const sourceToOutputTime = (sourceMs: number) =>
    sourceMs - manifest.source.sourceStartMs;

  addSample(samples, 'first', 0);
  addSample(
    samples,
    'last',
    manifest.durationMs - Math.min(frameMs * 2, 1_000),
  );
  const markerOutputMs = sourceToOutputTime(manifest.source.marker.tMs);
  if (markerOutputMs >= 0 && markerOutputMs < manifest.durationMs) {
    addSample(samples, 'marker', markerOutputMs);
  }

  const selectedEvents = manifest.telemetry.events.filter(
    (event) =>
      event.tMs >= manifest.source.sourceStartMs &&
      event.tMs < manifest.source.sourceEndMs,
  );
  for (const event of selectedEvents) {
    const outputTime = sourceToOutputTime(event.tMs);
    if (event.channel === 'click') {
      addSample(samples, `click-${event.seq}`, outputTime);
    }
    if (event.channel === 'element') {
      addSample(samples, `focus-${event.seq}`, outputTime);
    }
    if (event.channel === 'scroll') {
      addSample(
        samples,
        `scroll-settled-${event.seq}`,
        Math.min(outputTime + 500, manifest.durationMs - frameMs),
      );
    }
    if (event.channel === 'route') {
      addSample(samples, `route-${event.seq}`, outputTime);
    }
  }

  for (const cue of manifest.captions) {
    addSample(samples, `caption-${cue.id}-start`, cue.startMs);
    addSample(samples, `caption-${cue.id}-mid`, (cue.startMs + cue.endMs) / 2);
    addSample(samples, `caption-${cue.id}-end`, cue.endMs - 1);
  }

  return samples;
}

export function assertNarratedSamplePlanWithinBounds(
  samples: readonly NarratedVerificationSample[],
  durationMs: number,
) {
  for (const sample of samples) {
    if (
      !Number.isFinite(sample.milliseconds) ||
      sample.milliseconds < 0 ||
      sample.milliseconds >= durationMs
    ) {
      throw new Error(
        `Narrated sample plan overflow at ${sample.label}; refusing to truncate evidence`,
      );
    }
  }
}

export function assertCaptionMidpointOcr(
  samples: readonly NarratedVerificationSample[],
  texts: readonly string[],
  cues: readonly NarratedCaptionCue[],
) {
  for (const cue of cues) {
    const label = `caption-${cue.id}-mid`;
    const index = samples.findIndex((sample) => sample.label === label);
    if (index === -1) {
      throw new Error(`Caption OCR sample plan is missing ${label}`);
    }
    try {
      assertRequiredOcrText(texts[index] ?? '', [cue.text]);
    } catch {
      throw new Error(
        `Caption OCR sample ${label} did not recognize: ${cue.text}`,
      );
    }
  }
}

export function isGeneratedNarratedSnapshotName(fileName: string) {
  return narratedSnapshotPattern.test(fileName);
}
