import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  parseRecordedPlan,
  parseRecordedResolvedManifest,
} from './recorded-contracts';
import { sampleManifestJson, samplePlanJson } from './recorded-test-support';

type Json = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

function plan(change: (value: Json) => void) {
  const value = samplePlanJson() as Json;
  change(value);
  return value;
}

function rejects(value: unknown, pattern: RegExp) {
  assert.throws(() => parseRecordedPlan(value), pattern);
}

test('the smoke plan is accepted and defaults are filled in', () => {
  const parsed = parseRecordedPlan(samplePlanJson());
  assert.equal(parsed.scenes.length, 5);

  const minimal = parseRecordedPlan(
    plan((value) => {
      delete value.audio;
      delete value.captions;
      value.scenes = [
        {
          kind: 'clip',
          id: 'only',
          layout: 'full',
          durationMs: 500,
          primary: { source: 'alpha', startMs: 0 },
        },
      ];
    }),
  );
  assert.deepEqual(minimal.audio, []);
  assert.deepEqual(minimal.captions, []);
  const scene = minimal.scenes[0];
  assert.equal(scene?.kind === 'clip' && scene.primary.playbackRate, 1);
});

test('plan: ids, canvas and theme are bounded', () => {
  rejects(
    plan((v) => (v.runId = 'Upper_Case')),
    /plan\.runId/,
  );
  rejects(
    plan((v) => (v.runId = 'a'.repeat(81))),
    /plan\.runId/,
  );
  rejects(
    plan((v) => (v.canvas.width = 639)),
    /plan\.canvas\.width/,
  );
  rejects(
    plan((v) => (v.canvas.width = 3_842)),
    /plan\.canvas\.width/,
  );
  rejects(
    plan((v) => (v.canvas.height = 359)),
    /plan\.canvas\.height/,
  );
  rejects(
    plan((v) => (v.canvas.width = 1_281)),
    /even/,
  );
  rejects(
    plan((v) => (v.canvas.fps = 23)),
    /plan\.canvas\.fps/,
  );
  rejects(
    plan((v) => (v.canvas.fps = 61)),
    /plan\.canvas\.fps/,
  );
  rejects(
    plan((v) => (v.canvas.fps = 29.97)),
    /plan\.canvas\.fps/,
  );
  rejects(
    plan((v) => (v.theme.accent = 'blue')),
    /plan\.theme\.accent/,
  );
  rejects(
    plan((v) => (v.theme.muted = '#abc')),
    /plan\.theme\.muted/,
  );
  rejects(
    plan((v) => (v.extra = true)),
    /extra|Unrecognized/i,
  );
  rejects(
    plan((v) => (v.kind = 'other')),
    /plan\.kind/,
  );
  rejects(
    plan((v) => (v.schemaVersion = 2)),
    /plan\.schemaVersion/,
  );
});

test('plan: sources are bounded, unique and use known extensions', () => {
  rejects(
    plan((v) => (v.sources = [])),
    /plan\.sources/,
  );
  rejects(
    plan((v) => {
      v.sources = Array.from({ length: 9 }, (_, index) => ({
        id: `s${index}`,
        path: `s${index}.mp4`,
      }));
    }),
    /plan\.sources/,
  );
  rejects(
    plan((v) => (v.sources[1].id = v.sources[0].id)),
    /Source identifiers must be unique/,
  );
  rejects(
    plan((v) => (v.sources[0].path = 'clip.avi')),
    /sources\.0\.path/,
  );
  rejects(
    plan((v) => (v.sources[0].path = 'clip')),
    /sources\.0\.path/,
  );
  for (const extension of ['.mp4', '.MOV', '.webm', '.mkv']) {
    assert.doesNotThrow(() =>
      parseRecordedPlan(
        plan((v) => (v.sources[0].path = `a/clip${extension}`)),
      ),
    );
  }
  rejects(
    plan((v) => (v.sources[0].label = 'x'.repeat(61))),
    /sources\.0\.label/,
  );
});

test('plan: audio is bounded and uses known extensions', () => {
  rejects(
    plan((v) => {
      v.audio = Array.from({ length: 17 }, (_, index) => ({
        id: `a${index}`,
        path: `a${index}.wav`,
        atMs: 0,
      }));
    }),
    /plan\.audio/,
  );
  rejects(
    plan((v) => (v.audio[0].path = 'tone.ogg')),
    /audio\.0\.path/,
  );
  rejects(
    plan((v) => (v.audio[0].atMs = -1)),
    /audio\.0\.atMs/,
  );
  rejects(
    plan((v) => (v.audio[0].volume = 2.5)),
    /audio\.0\.volume/,
  );
  rejects(
    plan((v) => (v.audio[0].volume = -0.1)),
    /audio\.0\.volume/,
  );
  const parsed = parseRecordedPlan(plan((v) => delete v.audio[0].volume));
  assert.equal(parsed.audio[0]?.volume, 1);
});

test('plan: scene counts, durations and ids', () => {
  rejects(
    plan((v) => (v.scenes = [])),
    /plan\.scenes/,
  );
  rejects(
    plan((v) => {
      v.scenes = Array.from({ length: 61 }, (_, index) => ({
        kind: 'card',
        id: `c${index}`,
        durationMs: 1_000,
        title: 'T',
      }));
      v.captions = [];
    }),
    /plan\.scenes/,
  );
  rejects(
    plan((v) => (v.scenes[1].id = v.scenes[0].id)),
    /Scene identifiers must be unique/,
  );
  rejects(
    plan((v) => (v.scenes[0].durationMs = 999)),
    /scenes\.0\.durationMs/,
  );
  rejects(
    plan((v) => (v.scenes[1].durationMs = 499)),
    /scenes\.1\.durationMs/,
  );
  rejects(
    plan((v) => (v.scenes[1].durationMs = 500.5)),
    /scenes\.1\.durationMs/,
  );
  rejects(
    plan((v) => {
      v.scenes = Array.from({ length: 11 }, (_, index) => ({
        kind: 'card',
        id: `c${index}`,
        durationMs: 60_000,
        title: 'T',
      }));
      v.captions = [];
    }),
    /exceeds/,
  );
  rejects(
    plan((v) => (v.scenes[0].kind = 'banner')),
    /plan\.scenes\.0/,
  );
});

test('plan: layouts decide whether a secondary reference exists', () => {
  rejects(
    plan((v) => delete v.scenes[3].secondary),
    /scenes\.3\.secondary.*requires/,
  );
  rejects(
    plan((v) => {
      v.scenes[1].secondary = { source: 'beta', startMs: 0 };
    }),
    /scenes\.1\.secondary.*Only the split/,
  );
  rejects(
    plan((v) => (v.scenes[1].layout = 'picture-in-picture')),
    /layout/,
  );
  rejects(
    plan((v) => (v.scenes[1].primary.source = 'nope')),
    /scenes\.1\.primary\.source.*Unknown source/,
  );
  rejects(
    plan((v) => (v.scenes[3].secondary.source = 'nope')),
    /scenes\.3\.secondary\.source/,
  );
});

test('plan: playbackRate is an integer from 1 to 8', () => {
  for (const rate of [0, 9, 1.5, -1]) {
    rejects(
      plan((v) => (v.scenes[1].primary.playbackRate = rate)),
      /playbackRate/,
    );
  }
  for (const rate of [1, 4, 8]) {
    assert.doesNotThrow(() =>
      parseRecordedPlan(plan((v) => (v.scenes[1].primary.playbackRate = rate))),
    );
  }
});

test('plan: text is plain, bounded, and may contain emoji', () => {
  rejects(
    plan((v) => (v.scenes[0].title = 'x'.repeat(81))),
    /scenes\.0\.title/,
  );
  rejects(
    plan((v) => (v.scenes[0].eyebrow = 'x'.repeat(61))),
    /scenes\.0\.eyebrow/,
  );
  rejects(
    plan((v) => (v.scenes[1].heading = 'x'.repeat(81))),
    /scenes\.1\.heading/,
  );
  rejects(
    plan((v) => (v.scenes[0].lines = ['x'.repeat(141)])),
    /scenes\.0\.lines\.0/,
  );
  rejects(
    plan((v) => (v.scenes[0].lines = Array.from({ length: 7 }, () => 'line'))),
    /scenes\.0\.lines/,
  );
  rejects(
    plan((v) => (v.captions[0].text = 'x'.repeat(201))),
    /captions\.0\.text/,
  );
  rejects(
    plan((v) => (v.captions[0].text = 'a <b>bold</b> claim')),
    /plain text/,
  );
  rejects(
    plan((v) => (v.scenes[0].title = 'bell\u0007')),
    /plain text/,
  );
  rejects(
    plan((v) => (v.scenes[0].title = '   ')),
    /scenes\.0\.title/,
  );
  assert.doesNotThrow(() =>
    parseRecordedPlan(
      plan((v) => (v.scenes[0].title = 'Launch day \u{1F680}')),
    ),
  );
});

test('plan: captions use the primary source clock inside the clip window', () => {
  // scene "framed": device, durationMs 3000, primary start 0, rate 1 -> window 0..3000
  rejects(
    plan((v) => (v.captions[0].scene = 'title')),
    /captions\.0\.scene.*clip scenes/,
  );
  rejects(
    plan((v) => (v.captions[0].scene = 'ghost')),
    /Unknown scene/,
  );
  rejects(
    plan((v) => {
      v.captions[0].startMs = 900;
      v.captions[0].endMs = 900;
    }),
    /startMs < endMs/,
  );
  rejects(
    plan((v) => (v.captions[0].endMs = 3_001)),
    /primary source window/,
  );
  // scene "wide": primary start 2000, rate 4, 2000 ms -> source window 2000..10000
  rejects(
    plan((v) => (v.captions[1].startMs = 1_999)),
    /primary source window/,
  );
  rejects(
    plan((v) => (v.captions[1].endMs = 10_001)),
    /primary source window/,
  );
  assert.doesNotThrow(() =>
    parseRecordedPlan(
      plan((v) => {
        v.captions[1].startMs = 2_000;
        v.captions[1].endMs = 10_000;
      }),
    ),
  );
});

test('plan: captions in one scene are ordered and do not overlap', () => {
  rejects(
    plan((v) => {
      v.captions.push({
        id: 'overlap',
        scene: 'framed',
        startMs: 2_000,
        endMs: 2_900,
        text: 'overlaps the first',
      });
    }),
    /ordered and non-overlapping/,
  );
  rejects(
    plan((v) => {
      v.captions.push({
        id: 'before',
        scene: 'framed',
        startMs: 0,
        endMs: 100,
        text: 'listed after a later caption',
      });
    }),
    /ordered and non-overlapping/,
  );
  rejects(
    plan((v) => {
      v.captions.push({ ...v.captions[0] });
    }),
    /Caption identifiers must be unique/,
  );
  assert.doesNotThrow(() =>
    parseRecordedPlan(
      plan((v) => {
        v.captions[0].endMs = 1_000;
        v.captions.push({
          id: 'second',
          scene: 'framed',
          startMs: 1_000,
          endMs: 2_000,
          text: 'touching is fine',
        });
      }),
    ),
  );
});

function manifest(change: (value: Json) => void) {
  const value = sampleManifestJson() as Json;
  change(value);
  return value;
}

function manifestRejects(value: unknown, pattern: RegExp) {
  assert.throws(() => parseRecordedResolvedManifest(value), pattern);
}

test('resolved manifest: the resolved smoke plan parses strictly', () => {
  const parsed = parseRecordedResolvedManifest(sampleManifestJson());
  assert.equal(parsed.durationFrames, 360);
  assert.equal(parsed.durationMs, 12_000);
  manifestRejects(
    manifest((v) => (v.surprise = 1)),
    /Unrecognized|surprise/i,
  );
  manifestRejects(
    manifest((v) => (v.scenes[1].surprise = 1)),
    /Unrecognized|surprise/i,
  );
});

test('resolved manifest: scenes are contiguous from zero and sum to the duration', () => {
  manifestRejects(
    manifest((v) => (v.scenes[1].fromFrame = 61)),
    /contiguous.*60/,
  );
  manifestRejects(
    manifest((v) => (v.scenes[0].fromFrame = 1)),
    /contiguous.*0/,
  );
  manifestRejects(
    manifest((v) => (v.durationFrames = 361)),
    /sum to 360/,
  );
  manifestRejects(
    manifest((v) => (v.durationMs = 11_000)),
    /durationMs must equal/,
  );
});

test('resolved manifest: assets stay in the run and match their ids', () => {
  manifestRejects(
    manifest(
      (v) =>
        (v.sources[0].asset = 'generated/recorded/other-run/source-alpha.mp4'),
    ),
    /Source asset must be/,
  );
  manifestRejects(
    manifest((v) => (v.sources[0].asset = '../escape.mp4')),
    /sources\.0\.asset/,
  );
  manifestRejects(
    manifest(
      (v) => (v.audio[0].asset = 'generated/recorded/unit-run/elsewhere.wav'),
    ),
    /Audio asset must be/,
  );
  manifestRejects(
    manifest((v) => (v.sources[0].sha256 = 'xyz')),
    /sources\.0\.sha256/,
  );
});

test('resolved manifest: clip references and source windows', () => {
  manifestRejects(
    manifest((v) => (v.scenes[1].primary.source = 'ghost')),
    /Unknown source "ghost"/,
  );
  manifestRejects(
    manifest((v) => delete v.scenes[3].secondary),
    /requires a secondary/,
  );
  manifestRejects(
    manifest(
      (v) =>
        (v.scenes[1].secondary = {
          source: 'beta',
          startFrame: 0,
          playbackRate: 1,
        }),
    ),
    /Only the split/,
  );
  // scene "wide" has 60 frames at rate 4: it reads startFrame + 59 * 4 = startFrame + 236,
  // and the source has 360 frames, so startFrame 123 is the last one that fits.
  manifestRejects(
    manifest((v) => (v.scenes[2].primary.startFrame = 124)),
    /source frame 360/,
  );
  manifestRejects(
    manifest((v) => (v.scenes[2].primary.startFrame = 125)),
    /has 360 frames/,
  );
  assert.doesNotThrow(() =>
    parseRecordedResolvedManifest(
      manifest((v) => (v.scenes[2].primary.startFrame = 123)),
    ),
  );
  manifestRejects(
    manifest((v) => (v.scenes[2].primary.playbackRate = 9)),
    /playbackRate/,
  );
});

test('resolved manifest: captions are inside their clip, ordered, and unique', () => {
  manifestRejects(
    manifest((v) => (v.captions[0].scene = 'title')),
    /clip scene/,
  );
  manifestRejects(
    manifest((v) => (v.captions[0].scene = 'ghost')),
    /clip scene/,
  );
  // "framed" covers frames 60..149 = 2000..5000 ms.
  manifestRejects(
    manifest((v) => (v.captions[0].startMs = 1_900)),
    /output range 2000-5000ms/,
  );
  manifestRejects(
    manifest((v) => (v.captions[0].endMs = 5_001)),
    /output range/,
  );
  manifestRejects(
    manifest((v) => {
      v.captions[0].startMs = 2_000;
      v.captions[0].endMs = 2_020;
    }),
    /at least one frame/,
  );
  manifestRejects(
    manifest((v) => {
      v.captions[1].startMs = 4_000;
      v.captions[1].endMs = 4_500;
    }),
    /output range/,
  );
  manifestRejects(
    manifest((v) => {
      const first = v.captions[0];
      v.captions.splice(1, 0, { ...first, id: 'dup-times' });
    }),
    /non-overlapping/,
  );
  manifestRejects(
    manifest((v) => (v.captions[1].id = v.captions[0].id)),
    /Caption identifiers must be unique/,
  );
  manifestRejects(
    manifest((v) => (v.sources[1].id = v.sources[0].id)),
    /Source identifiers must be unique/,
  );
});

test('resolved manifest: audio must fit inside the video', () => {
  manifestRejects(
    manifest((v) => (v.audio[0].atFrame = 340)),
    /runs past the end/,
  );
  assert.doesNotThrow(() =>
    parseRecordedResolvedManifest(manifest((v) => (v.audio[0].atFrame = 314))),
  );
});
