import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const packageRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
);
export const repositoryRoot = path.resolve(packageRoot, '..', '..');
export const publicDirectory = path.join(packageRoot, 'public');
export const fixtureManifestPath = path.join(
  packageRoot,
  'fixtures',
  'prbot-product-tour.json',
);

export async function readJsonFile(filePath: string) {
  return JSON.parse(await readFile(filePath, 'utf8')) as unknown;
}

export async function writeTextFile(filePath: string, content: string) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, content);
}

export async function requireFiles(filePaths: string[]) {
  await Promise.all(
    filePaths.map(async (filePath) => {
      try {
        await access(filePath);
      } catch {
        throw new Error(`Required file does not exist: ${filePath}`);
      }
    }),
  );
}
