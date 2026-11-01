import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { link, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { test } from 'node:test';

import fixture from '../fixtures/narrated-browser-tour.json';
import {
  createNarratedCaptureRun,
  getNarratedFileSha256,
} from './narrated-files';
import {
  buildSyntheticNarratedCaptureBundle,
  buildSyntheticNarratedTelemetry,
} from './narrated-fixture';
import { loadValidatedNarratedManifest } from './narrated-manifest';
import { parseNarratedResolvedManifest } from './narrated-resolved-contracts';

async function createInputs() {
  const runId = `manifest-test-${randomUUID()}`;
  const paths = await createNarratedCaptureRun(runId);
  const telemetry = buildSyntheticNarratedTelemetry(runId);
  // These are inert bytes for digest tests, never decoded or rendered media.
  await writeFile(paths.captureVideoPath, 'synthetic video bytes');
  await writeFile(paths.narrationPath, 'synthetic narration bytes');
  await writeFile(paths.telemetryPath, JSON.stringify(telemetry));
  const capture = buildSyntheticNarratedCaptureBundle(runId, {
    videoSha256: await getNarratedFileSha256(paths.captureVideoPath),
    telemetrySha256: await getNarratedFileSha256(paths.telemetryPath),
  });
  assert.equal(capture.status, 'complete');
  const manifest = {
    ...structuredClone(fixture),
    runId,
    project: capture.project,
    telemetry,
    source: {
      ...fixture.source,
      video: `${paths.publicPrefix}/capture.webm`,
      videoSha256: await getNarratedFileSha256(paths.captureVideoPath),
      telemetry: `${paths.publicPrefix}/telemetry.v1.json`,
      telemetrySha256: await getNarratedFileSha256(paths.telemetryPath),
    },
    narration: {
      ...fixture.narration,
      audio: `${paths.publicPrefix}/narration.v1.wav`,
      audioSha256: await getNarratedFileSha256(paths.narrationPath),
    },
  };
  const save = async () => {
    await writeFile(paths.captureBundlePath, JSON.stringify(capture));
    await writeFile(paths.resolvedManifestPath, JSON.stringify(manifest));
  };
  await save();
  return { paths, capture, manifest, telemetry, save };
}

type Inputs = Awaited<ReturnType<typeof createInputs>>;
const cases: Array<{
  name: string;
  mutate: (inputs: Inputs) => Promise<void>;
  error: RegExp;
}> = [
  {
    name: 'missing manifest',
    mutate: async ({ paths }) => {
      await rm(paths.resolvedManifestPath);
    },
    error: /ENOENT/,
  },
  {
    name: 'malformed manifest JSON',
    mutate: async ({ paths }) => {
      await writeFile(paths.resolvedManifestPath, '{');
    },
    error: /JSON/,
  },
  {
    name: 'invalid manifest schema',
    mutate: async ({ paths }) => {
      await writeFile(paths.resolvedManifestPath, '{}');
    },
    error: /schemaVersion/,
  },
  {
    name: 'manifest symlink',
    mutate: async ({ paths }) => {
      const copy = path.join(paths.runDirectory, 'copy.json');
      await writeFile(copy, await readFile(paths.resolvedManifestPath));
      await rm(paths.resolvedManifestPath);
      await symlink(copy, paths.resolvedManifestPath);
    },
    error: /symbolic link/,
  },
  {
    name: 'manifest hard link',
    mutate: async ({ paths }) => {
      await link(
        paths.resolvedManifestPath,
        path.join(paths.runDirectory, 'alias.json'),
      );
    },
    error: /hard-link/,
  },
  {
    name: 'missing capture bundle',
    mutate: async ({ paths }) => {
      await rm(paths.captureBundlePath);
    },
    error: /ENOENT/,
  },
  {
    name: 'invalid capture JSON',
    mutate: async ({ paths }) => {
      await writeFile(paths.captureBundlePath, '{');
    },
    error: /JSON/,
  },
  {
    name: 'asset outside its declared run',
    mutate: async (inputs) => {
      inputs.manifest.source.video =
        'generated/narrated/another-run/capture.webm';
      await inputs.save();
    },
    error: /only local assets in their run/,
  },
  {
    name: 'missing video asset',
    mutate: async ({ paths }) => {
      await rm(paths.captureVideoPath);
    },
    error: /ENOENT/,
  },
  {
    name: 'tampered video bytes',
    mutate: async ({ paths }) => {
      await writeFile(paths.captureVideoPath, 'changed');
    },
    error: /digest mismatch/,
  },
  {
    name: 'tampered narration bytes',
    mutate: async ({ paths }) => {
      await writeFile(paths.narrationPath, 'changed');
    },
    error: /digest mismatch/,
  },
  {
    name: 'telemetry bytes changed without semantic change',
    mutate: async ({ paths }) => {
      await writeFile(
        paths.telemetryPath,
        `${await readFile(paths.telemetryPath, 'utf8')}\n`,
      );
    },
    error: /digest mismatch/,
  },
  {
    name: 'telemetry route absent from capture',
    mutate: async (inputs) => {
      inputs.capture.routeIds = ['home'];
      await inputs.save();
    },
    error: /undeclared route ID: reports/,
  },
  {
    name: 'different manifest project',
    mutate: async (inputs) => {
      inputs.manifest.project = {
        ...inputs.manifest.project,
        id: 'different-project',
      };
      await inputs.save();
    },
    error: /project does not match/,
  },
  {
    name: 'different embedded telemetry after valid digest checks',
    mutate: async (inputs) => {
      const event = inputs.manifest.telemetry.events[0]!;
      assert.equal(event.channel, 'cursor');
      if (event.channel === 'cursor') event.x = 0.4;
      await inputs.save();
    },
    error: /telemetry does not match the finalized telemetry file/,
  },
];

test('validated narrated manifest returns the parsed manifest from inert local inputs', async () => {
  const inputs = await createInputs();
  try {
    assert.deepEqual(
      await loadValidatedNarratedManifest(inputs.paths.resolvedManifestPath),
      parseNarratedResolvedManifest(inputs.manifest),
    );
    // Loading leaves the capture bytes unchanged.
    assert.equal(
      await readFile(inputs.paths.captureVideoPath, 'utf8'),
      'synthetic video bytes',
    );
  } finally {
    await rm(inputs.paths.runDirectory, { recursive: true, force: true });
  }
});

for (const entry of cases) {
  test(`validated narrated manifest rejects ${entry.name}`, async () => {
    const inputs = await createInputs();
    try {
      await entry.mutate(inputs);
      await assert.rejects(
        () => loadValidatedNarratedManifest(inputs.paths.resolvedManifestPath),
        entry.error,
      );
    } finally {
      await rm(inputs.paths.runDirectory, { recursive: true, force: true });
    }
  });
}

test('validated narrated manifest rejects an alternate manifest filename', async () => {
  const inputs = await createInputs();
  try {
    const alternate = path.join(inputs.paths.runDirectory, 'alternate.json');
    await writeFile(alternate, JSON.stringify(inputs.manifest));
    await assert.rejects(
      () => loadValidatedNarratedManifest(alternate),
      /Expected the run's resolved.v1.json file/,
    );
  } finally {
    await rm(inputs.paths.runDirectory, { recursive: true, force: true });
  }
});
