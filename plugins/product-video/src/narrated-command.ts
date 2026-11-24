import { runCommand } from './command';

export function runNarratedCommand(
  command: string,
  arguments_: string[],
  extraEnvironment: Readonly<Record<string, string>> = {},
) {
  return runCommand(command, arguments_, 5 * 60 * 1_000, extraEnvironment);
}
