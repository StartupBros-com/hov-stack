import { randomUUID } from 'node:crypto';
import { parseArgs } from 'node:util';

import {
  assertSyntheticNarratedFixturePrerequisites,
  createSyntheticNarratedFixture,
} from '../narrated-fixture';

const HELP = `Create a local-only synthetic NarratedBrowserTour fixture.

Usage:
  pnpm --filter @kit/product-video narrated:fixture [--run-id <kebab-run-id>]

The fixture uses a neutral generated viewport and 440Hz tone only. It writes ignored local media,
never captures a browser, uses customer data, calls TTS, uploads, or publishes.
`;

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
  const fixture = await createSyntheticNarratedFixture(
    values['run-id'] ?? `synthetic-narrated-${randomUUID()}`,
  );
  process.stdout.write(
    `${JSON.stringify(
      {
        captureBundlePath: fixture.captureBundlePath,
        captionsPath: fixture.captionsPath,
        narrationPath: fixture.narrationPath,
        runId: fixture.runId,
      },
      null,
      2,
    )}\n`,
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
