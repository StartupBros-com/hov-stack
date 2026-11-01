import { spawn } from 'node:child_process';

import { parseStrictSrt } from './narrated-media';

/**
 * Narration is synthesized per caption cue and placed at that cue's start, so
 * the voice cannot drift from the words on screen. A single long take would
 * need hand-tuned offsets and silently desynchronizes whenever a cue moves.
 */
export const narrationSampleRate = 48_000;
export const narrationChannels = 2;

export type VoiceCue = {
  id: string;
  startMs: number;
  endMs: number;
  text: string;
};

export function planNarrationCues(srt: string): VoiceCue[] {
  const cues = parseStrictSrt(srt);
  if (cues.length === 0) {
    throw new Error('Narration needs at least one caption cue');
  }
  return cues;
}

export function assertNarrationFitsTimeline(
  cues: readonly VoiceCue[],
  durationMs: number,
) {
  for (const cue of cues) {
    if (cue.startMs < 0 || cue.endMs > durationMs) {
      throw new Error(
        `Narration cue ${cue.id} falls outside the ${durationMs}ms timeline`,
      );
    }
  }
}

/**
 * Speech that overruns its cue would talk over the next one, so each request
 * asks the provider to fit the cue and we still verify the returned audio.
 */
export function assertCueAudioFits(
  cue: VoiceCue,
  audioDurationMs: number,
  toleranceMs = 400,
) {
  const budgetMs = cue.endMs - cue.startMs;
  if (audioDurationMs > budgetMs + toleranceMs) {
    throw new Error(
      `Narration for ${cue.id} runs ${audioDurationMs}ms but its cue allows ${budgetMs}ms`,
    );
  }
}

export function buildNarrationMixArgs({
  cues,
  durationMs,
  segmentPaths,
  outputPath,
}: {
  cues: readonly VoiceCue[];
  durationMs: number;
  segmentPaths: readonly string[];
  outputPath: string;
}) {
  if (cues.length !== segmentPaths.length) {
    throw new Error('Every narration cue needs exactly one rendered segment');
  }
  const args = [
    '-v',
    'error',
    '-f',
    'lavfi',
    '-i',
    `anullsrc=r=${narrationSampleRate}:cl=stereo`,
  ];
  for (const segment of segmentPaths) {
    args.push('-i', segment);
  }
  const delays = cues
    .map(
      (cue, index) =>
        `[${index + 1}:a]adelay=${cue.startMs}|${cue.startMs},aresample=${narrationSampleRate}[d${index}]`,
    )
    .join(';');
  const mixInputs = cues.map((_, index) => `[d${index}]`).join('');
  const filter = `${delays};[0:a]${mixInputs}amix=inputs=${cues.length + 1}:normalize=0:duration=first[out]`;
  args.push(
    '-filter_complex',
    filter,
    '-map',
    '[out]',
    '-t',
    (durationMs / 1_000).toFixed(3),
    '-ac',
    String(narrationChannels),
    '-ar',
    String(narrationSampleRate),
    '-c:a',
    'pcm_s16le',
    '-y',
    outputPath,
  );
  return args;
}

export function runCommand(command: string, args: readonly string[]) {
  return new Promise<void>((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    child.stderr?.on('data', (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(
        new Error(`${command} exited ${code}: ${stderr.trim().slice(0, 400)}`),
      );
    });
  });
}
