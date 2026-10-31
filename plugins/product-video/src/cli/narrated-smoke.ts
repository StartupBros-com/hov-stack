import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { isCommandAvailable } from '../command-availability';
import { packageRoot } from '../files';
import { getNarratedRenderPaths } from '../narrated-files';
import {
  assertSyntheticNarratedFixturePrerequisites,
  createSyntheticNarratedFixture,
} from '../narrated-fixture';
import { prepareNarratedCapture } from '../narrated-media';
import { firstAvailableBrowser } from '../rendering';

const HELP = `Run the local NarratedBrowserTour synthetic smoke path.

Usage:
  pnpm --filter @kit/product-video narrated:smoke [--run-id <kebab-run-id>]

The smoke creates ignored neutral media, prepares it, renders NarratedBrowserTour, and verifies it
with required OCR. Missing FFmpeg, FFprobe, Tesseract, or a Chrome-compatible browser is a non-pass.
It never attaches to CDP, captures customer data, logs in, calls TTS, uploads, or publishes.
`;

function runLocalCli(scriptName: string, arguments_: string[]) {
  const result = spawnSync(
    path.join(packageRoot, 'node_modules', '.bin', 'tsx'),
    [path.join(packageRoot, 'src', 'cli', scriptName), ...arguments_],
    {
      cwd: packageRoot,
      stdio: 'inherit',
      timeout: 15 * 60 * 1_000,
    },
  );
  if (result.status !== 0) {
    throw new Error(`${scriptName} exited unsuccessfully`);
  }
}

async function main() {
  const { values } = parseArgs({
    options: {
      help: { type: 'boolean', default: false, short: 'h' },
      'run-id': { type: 'string' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }

  assertSyntheticNarratedFixturePrerequisites();
  if (!isCommandAvailable('tesseract', ['--version'])) {
    throw new Error(
      'Narrated synthetic smoke prerequisite unavailable: tesseract (non-pass)',
    );
  }
  const browserExecutable = await firstAvailableBrowser(undefined);
  const fixture = await createSyntheticNarratedFixture(
    values['run-id'] ?? `synthetic-narrated-smoke-${randomUUID()}`,
  );
  const prepared = await prepareNarratedCapture({
    captureBundlePath: fixture.captureBundlePath,
    captionsPath: fixture.captionsPath,
    narrationPath: fixture.narrationPath,
  });
  const renderPaths = getNarratedRenderPaths(fixture.runId);

  runLocalCli('narrated-render.ts', [
    '--manifest',
    prepared.manifestPath,
    '--browser-executable',
    browserExecutable,
  ]);
  runLocalCli('narrated-verify.ts', [
    '--manifest',
    prepared.manifestPath,
    '--input',
    renderPaths.outputPath,
    '--ocr',
    'required',
  ]);

  process.stdout.write(
    `${JSON.stringify(
      {
        outputPath: renderPaths.outputPath,
        reportPath: renderPaths.reportPath,
        runId: fixture.runId,
        status: 'passed',
      },
      null,
      2,
    )}\n`,
  );
}

main().catch((error: unknown) => {
  const reason = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${reason}\n`);
  process.stdout.write(
    `${JSON.stringify({ reason, status: 'non-pass' }, null, 2)}\n`,
  );
  process.exitCode = 1;
});
