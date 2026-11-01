import { spawnSync } from 'node:child_process';

export function isCommandAvailable(
  command: string,
  arguments_: readonly string[],
  timeoutMs = 30_000,
) {
  const result = spawnSync(command, [...arguments_], {
    stdio: 'ignore',
    timeout: timeoutMs,
  });
  return !result.error && result.status === 0;
}
