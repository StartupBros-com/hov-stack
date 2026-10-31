import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import type { Browser } from 'playwright-capture-runtime';

import { parseCdpEndpoint } from '../capture-script';
import { readJsonFile } from '../files';
import { buildNarratedCapabilityProbe } from '../narrated-capture-probe';
import { buildNarratedCaptureScript } from '../narrated-capture-script';
import {
  type NarratedScenario,
  assertRenderableNarratedCapture,
  parseNarratedCaptureBundle,
  parseNarratedScenario,
} from '../narrated-contracts';
import {
  assertSingleLinkRegularFile,
  createNarratedCaptureRun,
  getNarratedRunPaths,
  writeNarratedJsonAtomically,
} from '../narrated-files';
import {
  connectToCapturePage,
  loadCaptureProgram,
} from '../playwright-capture-runtime';

const HELP = `Record a bounded NarratedBrowserTour v1 capture from an already-authenticated browser.

Usage:
  pnpm --filter @kit/product-video narrated:capture \\
    --scenario <narrated-scenario.json> \\
    --run-id <kebab-run-id> \\
    [--cdp http://127.0.0.1:9223] [--dry-run]

--dry-run prints the deterministic capture program and writes nothing.
Real capture proves the pinned Playwright runtime capabilities before it creates an exclusive run.
The command never logs in, enters credentials, creates a profile, installs a browser, or publishes.
`;

function parseNarratedCdpEndpoint(value: string) {
  const endpoint = new URL(parseCdpEndpoint(value));
  if (endpoint.pathname !== '/' || endpoint.search || endpoint.hash) {
    throw new Error(
      '--cdp must be a loopback origin with no path, query, or hash',
    );
  }
  return endpoint.href;
}

function connectToScenarioPage(cdp: string, scenario: NarratedScenario) {
  const declaredUrls = new Set(
    scenario.routes.map((route) => new URL(route.path, scenario.baseUrl).href),
  );
  return connectToCapturePage(cdp, (url) => declaredUrls.has(url));
}

async function proveNarratedCaptureCapability(
  cdp: string,
  scenario: NarratedScenario,
) {
  const probeDirectory = await mkdtemp(
    path.join(tmpdir(), 'narrated-capture-probe-'),
  );
  const probeVideoPath = path.join(probeDirectory, 'capability-probe.webm');
  let browser: Browser | undefined;
  try {
    const probe = await loadCaptureProgram({
      directory: probeDirectory,
      name: 'capability-probe',
      source: buildNarratedCapabilityProbe(probeVideoPath, scenario),
    });
    const connected = await connectToScenarioPage(cdp, scenario);
    browser = connected.browser;
    await probe(connected.page);
    const probeVideo = await assertSingleLinkRegularFile(probeVideoPath);
    if (probeVideo.size === 0) {
      throw new Error('Playwright produced an empty capture probe');
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(
      `Narrated live capture prerequisite unavailable or unsafe: ${detail}`,
      { cause: error },
    );
  } finally {
    await browser?.close().catch(() => undefined);
    await rm(probeDirectory, { force: true, recursive: true });
  }
}

export function createNarratedCaptureDryRun(
  scenario: NarratedScenario,
  runId: string,
  cdp: string,
) {
  const paths = getNarratedRunPaths(runId);
  return {
    cdp,
    runId: paths.runId,
    paths: {
      captureBundlePath: paths.captureBundlePath,
      captureVideoPath: paths.captureVideoPath,
      telemetryPath: paths.telemetryPath,
    },
    script: buildNarratedCaptureScript({ paths, scenario }),
  };
}

async function main() {
  const { values } = parseArgs({
    options: {
      cdp: { type: 'string', default: 'http://127.0.0.1:9223' },
      'dry-run': { type: 'boolean', default: false },
      help: { type: 'boolean', default: false, short: 'h' },
      'run-id': { type: 'string' },
      scenario: { type: 'string' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (!values.scenario || !values['run-id']) {
    throw new Error('Both --scenario and --run-id are required');
  }

  const cdp = parseNarratedCdpEndpoint(values.cdp);
  const scenarioPath = path.resolve(values.scenario);
  await assertSingleLinkRegularFile(scenarioPath);
  const scenario = parseNarratedScenario(await readJsonFile(scenarioPath));
  if (values['dry-run']) {
    process.stdout.write(
      `${JSON.stringify(
        createNarratedCaptureDryRun(scenario, values['run-id'], cdp),
        null,
        2,
      )}\n`,
    );
    return;
  }

  await proveNarratedCaptureCapability(cdp, scenario);
  const paths = await createNarratedCaptureRun(values['run-id']);
  const scriptDirectory = await mkdtemp(
    path.join(tmpdir(), 'narrated-capture-script-'),
  );
  let browser: Browser | undefined;
  let captureFinalized = false;
  try {
    const capture = await loadCaptureProgram({
      directory: scriptDirectory,
      name: 'capture',
      source: buildNarratedCaptureScript({ paths, scenario }),
    });
    const connected = await connectToScenarioPage(cdp, scenario);
    browser = connected.browser;
    await capture(connected.page);
    assertRenderableNarratedCapture(
      parseNarratedCaptureBundle(await readJsonFile(paths.captureBundlePath)),
    );
    captureFinalized = true;
  } catch (error) {
    if (captureFinalized) {
      throw error;
    }
    await writeNarratedJsonAtomically(paths.captureBundlePath, {
      schemaVersion: 1,
      kind: 'narrated-capture-bundle',
      status: 'aborted',
      renderable: false,
      runId: paths.runId,
      scenarioId: scenario.id,
      project: scenario.project,
      routeIds: scenario.routes.map((route) => route.id),
      viewport: scenario.project.viewport,
      fps: scenario.project.fps,
    });
    throw error;
  } finally {
    await browser?.close().catch(() => undefined);
    await rm(scriptDirectory, { force: true, recursive: true });
  }

  process.stdout.write(
    `${JSON.stringify({
      captureBundlePath: paths.captureBundlePath,
      runId: paths.runId,
      telemetryPath: paths.telemetryPath,
      videoPath: paths.captureVideoPath,
    })}\n`,
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
