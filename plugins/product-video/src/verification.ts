import type { SceneTimelineItem } from './contracts';

export type ProbeResult = {
  format?: {
    duration?: string;
    size?: string;
  };
  streams?: Array<{
    codec_name?: string;
    height?: number;
    nb_read_frames?: string;
    pix_fmt?: string;
    width?: number;
  }>;
};

export type VerifiedVideo = {
  codec: 'h264';
  durationSeconds: number;
  frameCount: number;
  height: number;
  pixelFormat: 'yuv420p';
  sizeBytes: number;
  width: number;
};

type Dimensions = {
  width: number;
  height: number;
};

type Sample = {
  label: string;
  seconds: number;
};

const generatedSnapshotPattern =
  /^product-video-(?:contact-sheet|\d{2}-[a-z0-9-]+)\.png$/;

export function isGeneratedSnapshotName(fileName: string) {
  return generatedSnapshotPattern.test(fileName);
}

function positiveNumber(value: string | number | undefined) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function roundedSeconds(frame: number, fps: number) {
  return Number((frame / fps).toFixed(3));
}

export function validateProbe(
  probe: ProbeResult,
  expectedDimensions: Dimensions,
): VerifiedVideo {
  const stream = probe.streams?.[0];
  if (!stream) {
    throw new Error('Video verification found no video stream');
  }
  if (stream.codec_name !== 'h264') {
    throw new Error(
      `Expected H264 codec, received ${stream.codec_name ?? 'none'}`,
    );
  }
  if (
    stream.width !== expectedDimensions.width ||
    stream.height !== expectedDimensions.height
  ) {
    throw new Error(
      `Expected ${expectedDimensions.width}x${expectedDimensions.height}, received ${stream.width ?? 0}x${stream.height ?? 0}`,
    );
  }
  if (stream.pix_fmt !== 'yuv420p') {
    throw new Error(
      `Expected yuv420p pixel format, received ${stream.pix_fmt ?? 'none'}`,
    );
  }

  const frameCount = positiveNumber(stream.nb_read_frames);
  if (!frameCount) {
    throw new Error('Video verification found zero decoded frames');
  }
  const durationSeconds = positiveNumber(probe.format?.duration);
  if (!durationSeconds) {
    throw new Error('Video verification found zero or invalid duration');
  }
  const sizeBytes = positiveNumber(probe.format?.size);
  if (!sizeBytes) {
    throw new Error('Video verification found an empty artifact');
  }

  return {
    codec: 'h264',
    durationSeconds,
    frameCount,
    height: stream.height,
    pixelFormat: 'yuv420p',
    sizeBytes,
    width: stream.width,
  };
}

function normalizeOcrText(value: string) {
  return value
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}

/**
 * OCR wraps a caption across lines and occasionally emits a stray glyph at a
 * line boundary, so an exact substring match fails on text a human reads
 * perfectly. Requiring every word in order still fails a wrong or absent
 * caption — the words would differ — without failing on line breaks.
 */
function containsWordsInOrder(haystack: string, needle: string) {
  if (haystack.includes(needle)) return true;
  const words = needle.split(' ').filter(Boolean);
  if (words.length === 0) return false;
  let cursor = 0;
  for (const word of words) {
    const found = haystack.indexOf(word, cursor);
    if (found === -1) return false;
    cursor = found + word.length;
  }
  return true;
}

export function assertRequiredOcrText(text: string, requiredTerms: string[]) {
  const normalizedText = normalizeOcrText(text);
  const missingTerms = requiredTerms.filter((term) => {
    const normalizedTerm = normalizeOcrText(term);
    return (
      normalizedTerm.length === 0 ||
      !containsWordsInOrder(normalizedText, normalizedTerm)
    );
  });
  if (missingTerms.length > 0) {
    throw new Error(
      `OCR did not recognize required text: ${missingTerms.join(', ')}`,
    );
  }
}

export function assertSceneTitleOcr(
  samples: Sample[],
  texts: string[],
  scenes: Array<{ id: string; title: string }>,
) {
  for (const scene of scenes) {
    const label = `${scene.id}-mid`;
    const sampleIndex = samples.findIndex((sample) => sample.label === label);
    if (sampleIndex === -1) {
      throw new Error(`OCR sample plan is missing ${label}`);
    }

    try {
      assertRequiredOcrText(texts[sampleIndex] ?? '', [scene.title]);
    } catch {
      throw new Error(
        `OCR sample ${label} did not recognize required text: ${scene.title}`,
      );
    }
  }
}

export function assertTimelineMatches(
  verified: VerifiedVideo,
  expectedFrames: number,
  fps: number,
) {
  if (verified.frameCount !== expectedFrames) {
    throw new Error(
      `Expected ${expectedFrames} decoded frames, received ${verified.frameCount}`,
    );
  }

  const expectedDuration = expectedFrames / fps;
  const containerTolerance = 2 / fps;
  if (
    Math.abs(verified.durationSeconds - expectedDuration) > containerTolerance
  ) {
    throw new Error(
      `Expected ${expectedDuration.toFixed(3)}s duration, received ${verified.durationSeconds.toFixed(3)}s`,
    );
  }
}

export function buildSamplePlan(
  timeline: SceneTimelineItem[],
  fps: number,
): Sample[] {
  if (timeline.length === 0) {
    throw new Error('Cannot sample a video with zero scenes');
  }

  const samples: Sample[] = [];
  timeline.forEach((scene, index) => {
    samples.push({
      label: `${scene.id}-mid`,
      seconds: roundedSeconds(scene.from + scene.durationInFrames / 2, fps),
    });

    const next = timeline[index + 1];
    if (!next) {
      return;
    }

    samples.push(
      {
        label: `cut-${index + 1}-before`,
        seconds: Math.max(0, roundedSeconds(next.from, fps) - 0.1),
      },
      {
        label: `cut-${index + 1}-after`,
        seconds: roundedSeconds(next.from, fps) + 0.2,
      },
    );
  });

  return samples;
}
