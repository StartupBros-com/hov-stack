import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { type Browser, type Page, chromium } from 'playwright-capture-runtime';

export type CaptureProgram = (page: Page) => Promise<void>;

type PageCandidate = Pick<Page, 'isClosed' | 'url'>;

export function selectDeclaredCapturePage<T extends PageCandidate>(
  pages: readonly T[],
  isAllowed: (url: string) => boolean,
) {
  const candidates = pages.filter(
    (page) => !page.isClosed() && isAllowed(page.url()),
  );
  if (candidates.length !== 1) {
    throw new Error(
      'Capture requires exactly one open browser tab at a declared route',
    );
  }
  return candidates[0]!;
}

export async function loadCaptureProgram({
  directory,
  name,
  source,
}: {
  directory: string;
  name: string;
  source: string;
}) {
  const modulePath = path.join(directory, `${name}-${randomUUID()}.mjs`);
  await writeFile(modulePath, `export default ${source}\n`, {
    encoding: 'utf8',
    mode: 0o600,
  });
  const loaded = (await import(pathToFileURL(modulePath).href)) as {
    default?: unknown;
  };
  if (typeof loaded.default !== 'function') {
    throw new Error('Capture program did not export a function');
  }
  return loaded.default as CaptureProgram;
}

export async function connectToCapturePage(
  cdp: string,
  isAllowed: (url: string) => boolean,
): Promise<{ browser: Browser; page: Page }> {
  const browser = await chromium.connectOverCDP(cdp, { timeout: 30_000 });
  try {
    const pages = browser.contexts().flatMap((context) => context.pages());
    return {
      browser,
      page: selectDeclaredCapturePage(pages, isAllowed),
    };
  } catch (error) {
    await browser.close().catch(() => undefined);
    throw error;
  }
}
