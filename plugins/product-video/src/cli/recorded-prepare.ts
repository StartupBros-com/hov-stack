import path from 'node:path';
import { parseArgs } from 'node:util';

import { prepareRecordedPlan } from '../recorded-prepare';

const HELP = `Prepare a RecordedTour v1 run from an authored plan.

Usage:
  pnpm recorded:prepare --plan <plan.json>

Run from the plugin root (plugins/product-video). Relative paths inside the plan resolve
against the plan file's directory. Every source is re-encoded to a constant-frame-rate
H264 file and every audio track to 48kHz stereo WAV under
public/generated/recorded/<run-id>/, and one resolved.v1.json is written there.
The run id must be new. The command never uploads, publishes, or contacts a service.
`;

async function main() {
  const { values } = parseArgs({
    options: {
      help: { type: 'boolean', default: false, short: 'h' },
      plan: { type: 'string' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (!values.plan) {
    throw new Error('--plan is required');
  }

  const prepared = await prepareRecordedPlan(path.resolve(values.plan));
  process.stdout.write(
    `${JSON.stringify(
      {
        durationFrames: prepared.manifest.durationFrames,
        durationMs: prepared.manifest.durationMs,
        manifestPath: prepared.manifestPath,
        runId: prepared.runId,
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
