import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { isCommandAvailable } from '../command-availability';
import { packageRoot } from '../files';
import {
  assertSyntheticRecordedFixturePrerequisites,
  createSyntheticRecordedFixture,
} from '../recorded-fixture';
import { getRecordedRenderPaths } from '../recorded-files';
import { prepareRecordedPlan } from '../recorded-prepare';
import { firstAvailableBrowser } from '../rendering';

const HELP = `Run the local RecordedTour synthetic smoke path.

Usage:
  pnpm recorded:smoke [--run-id <kebab-run-id>] [--silent]

The smoke generates ignored neutral media (a numbered test pattern at 30 fps, a bars pattern at
25 fps, and a short tone unless --silent), prepares a plan that uses every layout, renders
RecordedTour, and verifies it with required OCR and the frame-match check. Missing FFmpeg,
FFprobe, Tesseract, or a Chrome-compatible browser is a non-pass. It never logs in, calls a
provider, uploads, or publishes.
`;

function runLocalCli(scriptName: string, arguments_: string[]) {
  const result = spawnSync(
    path.join(packageRoot, 'node_modules', '.bin', 'tsx'),
    [path.join(packageRoot, 'src', 'cli', scriptName), ...arguments_],
    {
      cwd: packageRoot,
      stdio: 'inherit',
      timeout: 20 * 60 * 1_000,
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
      silent: { type: 'boolean', default: false },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }

  assertSyntheticRecordedFixturePrerequisites();
  if (!isCommandAvailable('tesseract', ['--version'])) {
    throw new Error(
      'Recorded synthetic smoke prerequisite unavailable: tesseract (non-pass)',
    );
  }
  const browserExecutable = await firstAvailableBrowser(undefined);
  const runId =
    values['run-id'] ?? `synthetic-recorded-smoke-${randomUUID().slice(0, 8)}`;
  const fixture = await createSyntheticRecordedFixture(runId, {
    silent: values.silent,
  });
  const prepared = await prepareRecordedPlan(fixture.planPath);
  const renderPaths = getRecordedRenderPaths(runId);

  runLocalCli('recorded-render.ts', [
    '--manifest',
    prepared.manifestPath,
    '--browser-executable',
    browserExecutable,
  ]);
  runLocalCli('recorded-verify.ts', [
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
        audio: values.silent ? 'silent' : 'tone',
        outputPath: renderPaths.outputPath,
        reportPath: renderPaths.reportPath,
        runId,
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
