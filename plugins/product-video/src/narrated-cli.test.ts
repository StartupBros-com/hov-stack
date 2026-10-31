import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';

import { packageRoot } from './files';
import { getNarratedRunPaths } from './narrated-files';

function runNarratedCli(scriptName: string, arguments_: string[]) {
  const result = spawnSync(
    process.execPath,
    [
      path.join(packageRoot, 'node_modules', 'tsx', 'dist', 'cli.mjs'),
      path.join(packageRoot, 'src', 'cli', scriptName),
      ...arguments_,
    ],
    {
      cwd: packageRoot,
      encoding: 'utf8',
    },
  );
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  return result.stdout;
}

test('narrated capture dry-run emits inspectable code and creates no run', () => {
  const runId = `narrated-cli-dry-run-${randomUUID()}`;
  const output = runNarratedCli('narrated-capture.ts', [
    '--scenario',
    path.join(packageRoot, 'fixtures', 'narrated-scenario.example.json'),
    '--run-id',
    runId,
    '--dry-run',
  ]);
  const parsed = JSON.parse(output) as {
    runId: string;
    script: string;
  };

  assert.equal(parsed.runId, runId);
  // The alignment clapperboard is no longer painted: telemetry and video
  // share an origin by construction, and the overlay leaked into deliverables.
  assert.doesNotMatch(parsed.script, /CAPTURE ALIGNMENT MARKER/);
  assert.match(parsed.script, /markerTimeMs = 0;/);
  assert.equal(existsSync(getNarratedRunPaths(runId).runDirectory), false);
});

test('narrated CLIs advertise their separate bounded contracts', () => {
  assert.match(
    runNarratedCli('narrated-prepare.ts', ['--help']),
    /48kHz PCM WAV/,
  );
  assert.match(
    runNarratedCli('narrated-studio.ts', ['--help']),
    /does not render/i,
  );
  assert.match(runNarratedCli('narrated-render.ts', ['--help']), /H264 output/);
  assert.match(
    runNarratedCli('narrated-verify.ts', ['--help']),
    /--ocr auto\|required\|off/,
  );
  assert.match(runNarratedCli('narrated-smoke.ts', ['--help']), /non-pass/i);
});
