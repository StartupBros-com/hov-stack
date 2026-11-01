import { prepareFixtureAssets } from '../fixture';

const HELP = `Prepare committed PRBot assets for the credential-free product-video fixture.

Usage:
  pnpm --filter @kit/product-video prepare:fixture

Effects:
  Copies committed PRBot images into tooling/product-video/public/generated.
  Does not access the network, authenticate, or publish anything.
`;

async function main() {
  if (process.argv.includes('--help')) {
    process.stdout.write(HELP);
    return;
  }

  const files = await prepareFixtureAssets();
  process.stdout.write(`${JSON.stringify({ prepared: files }, null, 2)}\n`);
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
