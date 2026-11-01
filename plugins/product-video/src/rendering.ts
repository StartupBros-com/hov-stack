import { access } from 'node:fs/promises';

export async function firstAvailableBrowser(explicit: string | undefined) {
  const candidates = [
    explicit,
    process.env.REMOTION_BROWSER_EXECUTABLE,
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/snap/bin/chromium',
  ].filter((candidate): candidate is string => Boolean(candidate));

  for (const candidate of candidates) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      continue;
    }
  }

  throw new Error(
    'No Chrome-compatible browser found; pass --browser-executable explicitly',
  );
}
