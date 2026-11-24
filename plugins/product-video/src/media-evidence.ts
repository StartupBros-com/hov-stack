import path from 'node:path';

import { isCommandAvailable } from './command-availability';
import { runNarratedCommand as run } from './narrated-command';
import { secureNarratedGeneratedFile } from './narrated-files';
import type { NarratedProbeResult } from './narrated-verification';

export type OcrMode = 'auto' | 'off' | 'required';

export type OcrResult = {
  status: 'off' | 'ran' | 'unavailable';
  reason: string;
  texts: string[];
};

/** A crop region as fractions of the frame's width and height. */
export type FrameBand = {
  x: number;
  y: number;
  width: number;
  height: number;
};

export type LabeledSample = {
  label: string;
  milliseconds: number;
};

export function probeMediaStreams(
  filePath: string,
  countFrames: boolean,
): NarratedProbeResult {
  const arguments_ = [
    '-v',
    'error',
    ...(countFrames ? ['-count_frames'] : []),
    '-show_entries',
    'stream=codec_type,codec_name,width,height,pix_fmt,nb_read_frames,sample_rate',
    '-show_entries',
    'format=duration,size',
    '-of',
    'json',
    filePath,
  ];
  return JSON.parse(run('ffprobe', arguments_)) as NarratedProbeResult;
}

export function labeledSnapshotPath(
  outputDirectory: string,
  filePrefix: string,
  label: string,
  index: number,
) {
  return path.join(
    outputDirectory,
    `${filePrefix}-${String(index).padStart(3, '0')}-${label}.png`,
  );
}

export function contactSheetPath(outputDirectory: string, filePrefix: string) {
  return path.join(outputDirectory, `${filePrefix}-contact-sheet.png`);
}

/** Extract one labeled 640px still per sample, then tile them into a contact sheet. */
export async function extractLabeledSamples({
  filePrefix,
  inputPath,
  outputDirectory,
  samples,
}: {
  filePrefix: string;
  inputPath: string;
  outputDirectory: string;
  samples: readonly LabeledSample[];
}) {
  const images = samples.map((sample, index) => {
    const outputPath = labeledSnapshotPath(
      outputDirectory,
      filePrefix,
      sample.label,
      index,
    );
    run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-n',
      '-ss',
      String(sample.milliseconds / 1_000),
      '-i',
      inputPath,
      '-frames:v',
      '1',
      '-vf',
      `scale=640:-2,drawbox=x=0:y=0:w=iw:h=42:color=black@0.75:t=fill,drawtext=font='DejaVu Sans':text='${sample.label}':fontcolor=white:fontsize=22:x=12:y=9`,
      outputPath,
    ]);
    return outputPath;
  });
  const contactSheet = contactSheetPath(outputDirectory, filePrefix);
  run('ffmpeg', [
    '-hide_banner',
    '-loglevel',
    'error',
    '-n',
    '-pattern_type',
    'glob',
    '-i',
    path.join(outputDirectory, `${filePrefix}-[0-9][0-9][0-9]-*.png`),
    '-vf',
    `tile=3x${Math.ceil(images.length / 3)}:padding=8:margin=8:color=#07111f`,
    '-frames:v',
    '1',
    contactSheet,
  ]);
  await Promise.all(
    [...images, contactSheet].map((filePath) =>
      secureNarratedGeneratedFile(filePath),
    ),
  );
  return { contactSheet, images };
}

/**
 * Crop a still to a known text band and upscale it 2x: Tesseract misreads
 * caption text at its native size ("together in" came back as "togethe!"), and
 * UI either side of the band would otherwise land on the text's OCR line.
 */
export function cropImageToBand(image: string, band: FrameBand) {
  const output = image.replace(/\.png$/, '.caption-band.png');
  try {
    run('ffmpeg', [
      '-v',
      'error',
      '-i',
      image,
      '-vf',
      `crop=iw*${band.width}:ih*${band.height}:iw*${band.x}:ih*${band.y},scale=iw*2:ih*2:flags=lanczos`,
      '-y',
      output,
    ]);
    return output;
  } catch {
    return image;
  }
}

/**
 * One OpenMP thread per Tesseract call. On a busy host its default thread pool
 * spins against other work: one evidence still ran past the 5-minute command
 * timeout with two renders running, and passed in seconds with one thread.
 */
export const tesseractEnvironment = { OMP_THREAD_LIMIT: '1' } as const;

/**
 * Tesseract reads a frame line by line, so text beside a caption lands on the
 * caption's own line and breaks a contiguous match. `bandFor` names the region
 * each image's text is drawn in; images without a band are read whole.
 */
export function runOcr(
  images: readonly string[],
  mode: OcrMode,
  bandFor: (image: string, index: number) => FrameBand | undefined,
): OcrResult {
  if (mode === 'off') {
    return { reason: 'OCR disabled by --ocr off', status: 'off', texts: [] };
  }
  if (!isCommandAvailable('tesseract', ['--version'])) {
    if (mode === 'required') {
      throw new Error('OCR is required but tesseract is not available');
    }
    return {
      reason: 'Tesseract is not available on this host',
      status: 'unavailable',
      texts: [],
    };
  }
  const texts = images.map((image, index) => {
    const band = bandFor(image, index);
    const target = band ? cropImageToBand(image, band) : image;
    return run('tesseract', [target, 'stdout'], tesseractEnvironment).trim();
  });
  return {
    reason: 'Tesseract ran on the labeled evidence samples',
    status: 'ran',
    texts,
  };
}

export function escapeMarkdownCell(value: string) {
  return value.replaceAll('|', '\\|').replaceAll('\n', '<br>');
}
