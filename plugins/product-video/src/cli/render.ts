import { bundle } from '@remotion/bundler';
import { renderMedia, selectComposition } from '@remotion/renderer';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { parseTourManifest } from '../contracts';
import {
  fixtureManifestPath,
  packageRoot,
  publicDirectory,
  readJsonFile,
  requireFiles,
} from '../files';
import { prepareFixtureAssets } from '../fixture';
import {
  assertFileExtension,
  assertOutputPathsAvailable,
  assertOutputsDoNotAliasInputs,
} from '../output-safety';
import { firstAvailableBrowser } from '../rendering';

const HELP = `Render a validated product-tour manifest to a local H264 MP4.

Usage:
  pnpm --filter @kit/product-video render \\
    [--fixture | --manifest <manifest.json>] \\
    --output <video.mp4> \\
    [--browser-executable <path>] [--force]

The renderer uses local assets only and never publishes the artifact.
`;

async function main() {
  const { values } = parseArgs({
    options: {
      'browser-executable': { type: 'string' },
      fixture: { type: 'boolean', default: false },
      force: { type: 'boolean', default: false },
      help: { type: 'boolean', default: false, short: 'h' },
      manifest: { type: 'string' },
      output: { type: 'string' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (!values.output) {
    throw new Error('--output is required');
  }
  if (values.fixture && values.manifest) {
    throw new Error('Choose either --fixture or --manifest, not both');
  }

  if (values.fixture || !values.manifest) {
    await prepareFixtureAssets();
  }
  const manifestPath = values.manifest
    ? path.resolve(values.manifest)
    : fixtureManifestPath;
  const manifest = parseTourManifest(await readJsonFile(manifestPath));
  const assetPaths = [
    manifest.brand.logo,
    ...manifest.scenes.map((scene) => scene.image),
  ].map((asset) => path.join(publicDirectory, asset));
  await requireFiles(assetPaths);

  const outputLocation = path.resolve(values.output);
  assertFileExtension(outputLocation, '.mp4');
  await assertOutputsDoNotAliasInputs(
    [outputLocation],
    [manifestPath, ...assetPaths],
  );
  await assertOutputPathsAvailable([outputLocation], values.force);
  await mkdir(path.dirname(outputLocation), { recursive: true });
  const browserExecutable = await firstAvailableBrowser(
    values['browser-executable'],
  );
  const serveUrl = await bundle({
    entryPoint: path.join(packageRoot, 'src', 'index.ts'),
  });
  const inputProps = { manifest };
  const composition = await selectComposition({
    id: manifest.compositionId,
    inputProps,
    serveUrl,
    browserExecutable,
  });

  await renderMedia({
    browserExecutable,
    chromiumOptions: { enableMultiProcessOnLinux: true },
    codec: 'h264',
    composition,
    crf: 20,
    imageFormat: 'png',
    inputProps,
    logLevel: 'warn',
    outputLocation,
    overwrite: true,
    pixelFormat: 'yuv420p',
    serveUrl,
  });

  process.stdout.write(
    `${JSON.stringify({ browserExecutable, manifestPath, outputLocation })}\n`,
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
