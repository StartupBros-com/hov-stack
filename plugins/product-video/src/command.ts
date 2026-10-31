import { spawnSync } from 'node:child_process';

export function runCommand(
  command: string,
  arguments_: string[],
  timeoutMs: number,
) {
  const result = spawnSync(command, arguments_, {
    encoding: 'utf8',
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
