import { spawnSync } from 'node:child_process';

export function runCommand(
  command: string,
  arguments_: string[],
  timeoutMs: number,
  extraEnvironment: Readonly<Record<string, string>> = {},
) {
  const result = spawnSync(command, arguments_, {
    encoding: 'utf8',
    ...(Object.keys(extraEnvironment).length > 0
      ? { env: { ...process.env, ...extraEnvironment } }
      : {}),
    maxBuffer: 20 * 1024 * 1024,
    timeout: timeoutMs,
  });
  if (result.status !== 0) {
    const detail =
      result.error?.message || result.stderr.trim() || result.stdout.trim();
    throw new Error(`${command} failed${detail ? `: ${detail}` : ''}`);
  }
  return result.stdout;
}
