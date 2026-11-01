import { lstat, realpath, stat } from 'node:fs/promises';
import path from 'node:path';

async function canonicalPotentialPath(filePath: string): Promise<string> {
  const absolutePath = path.resolve(filePath);
  try {
    return await realpath(absolutePath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      throw error;
    }
  }

  const parent = path.dirname(absolutePath);
  if (parent === absolutePath) {
    return absolutePath;
  }

  return path.join(
    await canonicalPotentialPath(parent),
    path.basename(absolutePath),
  );
}

export function assertFileExtension(filePath: string, extension: string) {
  if (path.extname(filePath).toLowerCase() !== extension.toLowerCase()) {
    throw new Error(`Output must use the ${extension} extension: ${filePath}`);
  }
}

export async function assertOutputPathsAvailable(
  outputPaths: string[],
  force: boolean,
) {
  for (const outputPath of outputPaths) {
    let outputStat;
    try {
      outputStat = await lstat(outputPath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        continue;
      }
      throw error;
    }

    if (outputStat.isSymbolicLink()) {
      throw new Error(`Output path cannot be a symbolic link: ${outputPath}`);
    }
    if (!force) {
      throw new Error(
        `Output already exists: ${outputPath}. Pass --force to replace tool-owned output.`,
      );
    }
  }
}

export async function assertOutputsDoNotAliasInputs(
  outputPaths: string[],
  inputPaths: string[],
) {
  const canonicalInputs = await Promise.all(
    inputPaths.map((input) => realpath(input)),
  );
  const protectedInputs = new Set(canonicalInputs);
  const inputStats = await Promise.all(inputPaths.map((input) => stat(input)));

  for (const output of outputPaths) {
    const canonicalOutput = await canonicalPotentialPath(output);
    if (protectedInputs.has(canonicalOutput)) {
      throw new Error(`Output cannot overwrite an input file: ${output}`);
    }

    try {
      const outputStat = await stat(output);
      if (
        inputStats.some(
          (inputStat) =>
            inputStat.dev === outputStat.dev &&
            inputStat.ino === outputStat.ino,
        )
      ) {
        throw new Error(`Output cannot overwrite an input file: ${output}`);
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        continue;
      }
      throw error;
    }
  }
}
