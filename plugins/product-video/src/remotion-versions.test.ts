import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

type PackageManifest = {
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
};

// Remotion refuses to render a bundle made by a different @remotion/bundler
// version than the renderer's. Dependency updates have moved some of these
// packages and not others, which stopped narrated:smoke at render.
test('every Remotion package is pinned to one exact version', () => {
  const manifest = JSON.parse(
    readFileSync(new URL('../package.json', import.meta.url), 'utf8'),
  ) as PackageManifest;
  const remotionPackages = Object.entries({
    ...manifest.dependencies,
    ...manifest.devDependencies,
  }).filter(([name]) => name === 'remotion' || name.startsWith('@remotion/'));
  const names = remotionPackages.map(([name]) => name);

  for (const required of [
    'remotion',
    '@remotion/bundler',
    '@remotion/renderer',
  ]) {
    assert.ok(names.includes(required), `${required} is missing`);
  }
  for (const [name, version] of remotionPackages) {
    assert.match(
      version,
      /^\d+\.\d+\.\d+$/,
      `${name} must be pinned to an exact version, not ${version}`,
    );
  }
  assert.equal(
    new Set(remotionPackages.map(([, version]) => version)).size,
    1,
    `Remotion packages must share one version: ${remotionPackages
      .map(([name, version]) => `${name}@${version}`)
      .join(', ')}`,
  );
});
