import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';

import {
  assertCueAudioFits,
  assertNarrationFitsTimeline,
  buildNarrationMixArgs,
  narrationSampleRate,
  planNarrationCues,
  runCommand,
} from '../narrated-voice';

const HELP = `Synthesize narration for a NarratedBrowserTour caption track.

Usage:
  pnpm narrated:voice \\
    --captions <operator.srt> \\
    --duration-ms <window-duration-ms> \\
    [--start-ms <window-start-ms>] \\
    --voice <elevenlabs-voice-id> \\
    --out <narration.wav>

Each caption cue is synthesized separately and placed at its own start time, so
the voice cannot drift from the words on screen.

Captions are authored in capture time, the same as the SRT handed to prepare.
When the deliverable trims a head (prepare does this to drop the alignment
marker), pass that trim as --start-ms so the narration lands on the same frames
the captions do. Requires ELEVENLABS_API_KEY.
The command writes one local WAV. It never uploads, publishes, or sends.
`;

const TTS_BASE = 'https://api.elevenlabs.io/v1/text-to-speech';

function loadApiKey() {
  const key = process.env.ELEVENLABS_API_KEY?.trim();
  if (!key) {
    throw new Error(
      'ELEVENLABS_API_KEY is required to synthesize narration; export it before running',
    );
  }
  return key;
}

async function probeDurationMs(filePath: string) {
  const { spawnSync } = await import('node:child_process');
  const probe = spawnSync(
    'ffprobe',
    [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'default=nw=1:nk=1',
      filePath,
    ],
    { encoding: 'utf8' },
  );
  const seconds = Number(probe.stdout.trim());
  if (!Number.isFinite(seconds) || seconds <= 0) {
    throw new Error(`Could not probe narration segment duration: ${filePath}`);
  }
  return Math.round(seconds * 1_000);
}

async function synthesizeCue({
  apiKey,
  text,
  voiceId,
  outputPath,
}: {
  apiKey: string;
  text: string;
  voiceId: string;
  outputPath: string;
}) {
  const response = await fetch(`${TTS_BASE}/${voiceId}`, {
    method: 'POST',
    headers: {
      'xi-api-key': apiKey,
      'content-type': 'application/json',
      accept: 'audio/mpeg',
    },
    body: JSON.stringify({
      text,
      model_id: 'eleven_multilingual_v2',
      voice_settings: { stability: 0.5, similarity_boost: 0.75 },
    }),
  });
  if (!response.ok) {
    throw new Error(
      `Narration provider returned ${response.status}: ${(
        await response.text()
      ).slice(0, 300)}`,
    );
  }
  await writeFile(outputPath, Buffer.from(await response.arrayBuffer()), {
    mode: 0o600,
  });
}

async function main() {
  const { values } = parseArgs({
    options: {
      captions: { type: 'string' },
      'duration-ms': { type: 'string' },
      'start-ms': { type: 'string' },
      help: { type: 'boolean', default: false, short: 'h' },
      out: { type: 'string' },
      voice: { type: 'string' },
    },
    strict: true,
  });

  if (values.help) {
    process.stdout.write(HELP);
    return;
  }
  if (
    !values.captions ||
    !values['duration-ms'] ||
    !values.voice ||
    !values.out
  ) {
    throw new Error(
      '--captions, --duration-ms, --voice, and --out are required',
    );
  }
  const durationMs = Number(values['duration-ms']);
  if (!Number.isInteger(durationMs) || durationMs <= 0) {
    throw new Error('--duration-ms must be a positive integer');
  }

  const apiKey = loadApiKey();
  const startMs = Number(values['start-ms'] ?? 0);
  if (!Number.isInteger(startMs) || startMs < 0) {
    throw new Error('--start-ms must be a non-negative integer');
  }
  // Shift capture-time cues into the delivered window, exactly as prepare does.
  const cues = planNarrationCues(
    await readFile(path.resolve(values.captions), 'utf8'),
  ).map((cue) => ({
    ...cue,
    startMs: cue.startMs - startMs,
    endMs: cue.endMs - startMs,
  }));
  assertNarrationFitsTimeline(cues, durationMs);

  const workDirectory = await mkdtemp(path.join(tmpdir(), 'narrated-voice-'));
  try {
    const segmentPaths: string[] = [];
    for (const cue of cues) {
      const mp3Path = path.join(workDirectory, `${cue.id}.mp3`);
      const wavPath = path.join(workDirectory, `${cue.id}.wav`);
      await synthesizeCue({
        apiKey,
        text: cue.text,
        voiceId: values.voice,
        outputPath: mp3Path,
      });
      await runCommand('ffmpeg', [
        '-v',
        'error',
        '-i',
        mp3Path,
        '-ar',
        String(narrationSampleRate),
        '-ac',
        '2',
        '-c:a',
        'pcm_s16le',
        '-y',
        wavPath,
      ]);
      assertCueAudioFits(cue, await probeDurationMs(wavPath));
      segmentPaths.push(wavPath);
    }

    const outputPath = path.resolve(values.out);
    await runCommand(
      'ffmpeg',
      buildNarrationMixArgs({ cues, durationMs, segmentPaths, outputPath }),
    );
    process.stdout.write(
      `${JSON.stringify({
        cues: cues.length,
        durationMs,
        outputPath,
        voice: values.voice,
      })}\n`,
    );
  } finally {
    await rm(workDirectory, { force: true, recursive: true });
  }
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
