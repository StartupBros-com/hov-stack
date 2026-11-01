import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import type { Browser } from 'playwright-capture-runtime';

import {
  buildHeroScript,
  parseCaptureDimensions,
  parseCdpEndpoint,
} from '../capture-script';
import { captureScenarioSchema } from '../contracts';
import { readJsonFile } from '../files';
import {
  assertOutputPathsAvailable,
  assertOutputsDoNotAliasInputs,
} from '../output-safety';
import {
  connectToCapturePage,
  loadCaptureProgram,
} from '../playwright-capture-runtime';

const HELP = `Record a bounded product flow from an already-authenticated CDP browser.

Usage:
  pnpm --filter @kit/product-video capture \\
    --scenario <scenario.json> \\
    --output <capture.webm> \\
    [--cdp http://127.0.0.1:9223] \\
    [--width 1280] [--height 720] [--dry-run] [--force]

The command never installs Playwright, logs in, enters credentials, or publishes.
Use --dry-run first to inspect the generated hero script.
`;

async function main() {
  const { values } = parseArgs({
    options: {
      cdp: { type: 'string', default: 'http://127.0.0.1:9223' },
      'dry-run': { type: 'boolean', default: false },
      force: { type: 'boolean', default: false },
      height: { type: 'string', default: '720' },
      help: { type: 'boolean', default: false, short: 'h' },
      output: { type: 'string' },
      scenario: { type: 'string' },
      width: { type: 'string', default: '1280' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (!values.scenario || !values.output) {
    throw new Error('Both --scenario and --output are required');
  }
  if (!values.output.endsWith('.webm')) {
    throw new Error('Capture output must use the .webm extension');
  }

  const { width, height } = parseCaptureDimensions(values.width, values.height);
  const cdp = parseCdpEndpoint(values.cdp);
  const scenarioPath = path.resolve(values.scenario);
  const scenario = captureScenarioSchema.parse(
    await readJsonFile(scenarioPath),
  );
  const outputPath = path.resolve(values.output);
  const scriptPath = `${outputPath}.hero.mjs`;
  await assertOutputsDoNotAliasInputs([outputPath, scriptPath], [scenarioPath]);
  await assertOutputPathsAvailable([outputPath, scriptPath], values.force);

  const script = buildHeroScript({ scenario, outputPath, width, height });
  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(scriptPath, `${script}\n`);

  if (values['dry-run']) {
    process.stdout.write(
      `${JSON.stringify({ cdp, outputPath, scriptPath }, null, 2)}\n`,
    );
    return;
  }

  const runtimeDirectory = await mkdtemp(
    path.join(tmpdir(), 'product-video-capture-'),
  );
  const allowedHosts = new Set(scenario.allowedHosts);
  let browser: Browser | undefined;
  try {
    const capture = await loadCaptureProgram({
      directory: runtimeDirectory,
      name: 'capture',
      source: script,
    });
    const connected = await connectToCapturePage(cdp, (url) => {
      try {
        return allowedHosts.has(new URL(url).hostname);
      } catch {
        return false;
      }
    });
    browser = connected.browser;
    await capture(connected.page);
  } finally {
    await browser?.close().catch(() => undefined);
    await rm(runtimeDirectory, { force: true, recursive: true });
  }

  process.stdout.write(`${JSON.stringify({ outputPath, scriptPath })}\n`);
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
