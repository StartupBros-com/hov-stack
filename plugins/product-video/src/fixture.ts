import { copyFile, mkdir } from 'node:fs/promises';
import path from 'node:path';

import { publicDirectory, repositoryRoot } from './files';

const fixtureAssets = [
  {
    source: 'apps/blog-writer/public/images/dashboard.webp',
    destination: 'dashboard.webp',
  },
  {
    source: 'apps/blog-writer/public/images/dashboard-header.webp',
    destination: 'dashboard-header.webp',
  },
  {
    source: 'apps/blog-writer/public/images/billing.webp',
    destination: 'billing.webp',
  },
  {
    source: 'apps/blog-writer/public/images/logo/prbot-stacked-padded.png',
    destination: 'prbot-stacked-padded.png',
  },
] as const;

export async function prepareFixtureAssets() {
  const targetDirectory = path.join(publicDirectory, 'generated', 'prbot');
  await mkdir(targetDirectory, { recursive: true });

  await Promise.all(
    fixtureAssets.map(({ source, destination }) =>
      copyFile(
        path.join(repositoryRoot, source),
        path.join(targetDirectory, destination),
      ),
    ),
  );

  return fixtureAssets.map(({ destination }) =>
    path.join(targetDirectory, destination),
  );
}
