import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { parseArgs } from 'node:util';

import { packageRoot } from '../files';
import { loadValidatedNarratedManifest } from '../narrated-manifest';
import type { NarratedResolvedManifest } from '../narrated-resolved-contracts';

const HELP = `Open Remotion Studio for a resolved NarratedBrowserTour v1 manifest without opening a browser window.

Usage:
  pnpm --filter @kit/product-video narrated:studio \\
    --manifest <public/generated/narrated/<run-id>/resolved.v1.json>

Studio previews the validated local composition only. It does not render, capture, upload, or publish.
`;

export function getNarratedStudioArguments(manifest: NarratedResolvedManifest) {
  return [
    'studio',
    path.join(packageRoot, 'src', 'index.ts'),
    '--no-open',
    '--props',
    JSON.stringify({ manifest }),
  ];
}

async function main() {
  const { values } = parseArgs({
    options: {
      help: { type: 'boolean', default: false, short: 'h' },
      manifest: { type: 'string' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (!values.manifest) {
    throw new Error('--manifest is required');
  }

  const manifestPath = path.resolve(values.manifest);
  const manifest = await loadValidatedNarratedManifest(manifestPath);

  const result = spawnSync('remotion', getNarratedStudioArguments(manifest), {
    stdio: 'inherit',
  });
  if (result.status !== 0) {
    const detail =
      result.error?.message ?? 'Remotion Studio exited unsuccessfully';
    throw new Error(detail);
  }
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
