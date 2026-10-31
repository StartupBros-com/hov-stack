import path from 'node:path';
import { parseArgs } from 'node:util';

import { assertCaptureWindow, prepareNarratedCapture } from '../narrated-media';

const HELP = `Prepare a complete NarratedBrowserTour v1 capture with operator-supplied narration and SRT captions.

Usage:
  pnpm --filter @kit/product-video narrated:prepare \\
    --capture <public/generated/narrated/<run-id>/capture.v1.json> \\
    --audio <operator.wav|mp3|m4a> \\
    --captions <operator.srt> \\
    [--start-ms 0] [--end-ms <capture-duration-ms>]

The command normalizes narration locally to 48kHz PCM WAV and writes one resolved manifest.
It never contacts TTS providers, opens a microphone, redacts automatically, uploads, or publishes.
`;

function parseMillisecondOption(value: string | undefined, option: string) {
  if (value === undefined) {
    return undefined;
  }
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(
      `${option} must be a non-negative integer millisecond value`,
    );
  }
  return parsed;
}

async function main() {
  const { values } = parseArgs({
    options: {
      audio: { type: 'string' },
      captions: { type: 'string' },
      capture: { type: 'string' },
      'end-ms': { type: 'string' },
      help: { type: 'boolean', default: false, short: 'h' },
      'start-ms': { type: 'string' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (!values.capture || !values.audio || !values.captions) {
    throw new Error('--capture, --audio, and --captions are required');
  }

  const startMs = parseMillisecondOption(values['start-ms'], '--start-ms');
  const endMs = parseMillisecondOption(values['end-ms'], '--end-ms');
  if ((startMs === undefined) !== (endMs === undefined)) {
    throw new Error('--start-ms and --end-ms must be supplied together');
  }
  const window =
    startMs === undefined || endMs === undefined
      ? undefined
      : { startMs, endMs };
  if (window) {
    assertCaptureWindow(window);
  }

  const prepared = await prepareNarratedCapture({
    captureBundlePath: path.resolve(values.capture),
    captionsPath: path.resolve(values.captions),
    narrationPath: path.resolve(values.audio),
    window,
  });
  process.stdout.write(
    `${JSON.stringify(
      {
        manifestPath: prepared.manifestPath,
        narrationPath: prepared.narrationPath,
        runId: prepared.manifest.runId,
      },
      null,
      2,
    )}\n`,
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
