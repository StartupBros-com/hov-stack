import { readJsonFile } from './files';
import {
  assertRenderableNarratedCapture,
  parseNarratedCaptureBundle,
  parseNarratedTelemetry,
} from './narrated-contracts';
import {
  assertNarratedFileSha256,
  assertNarratedPublicAsset,
  assertNarratedRunFile,
  assertSingleLinkRegularFile,
  getNarratedRunPaths,
} from './narrated-files';
import { parseNarratedResolvedManifest } from './narrated-resolved-contracts';
import { assertTelemetryMatchesCapture } from './narrated-telemetry';
import { assertNarratedManifestMatchesCapture } from './narrated-verification';

/** Apply the same finalized-input checks before rendering or previewing a tour. */
export async function loadValidatedNarratedManifest(manifestPath: string) {
  await assertSingleLinkRegularFile(manifestPath);
  const manifest = parseNarratedResolvedManifest(
    await readJsonFile(manifestPath),
  );
  const runPaths = getNarratedRunPaths(manifest.runId);
  await assertNarratedRunFile(manifest.runId, manifestPath, 'resolved.v1.json');
  await assertNarratedRunFile(
    manifest.runId,
    runPaths.captureBundlePath,
    'capture.v1.json',
  );
  const [videoPath, telemetryPath, narrationPath] = await Promise.all([
    assertNarratedPublicAsset(manifest.runId, manifest.source.video),
    assertNarratedPublicAsset(manifest.runId, manifest.source.telemetry),
    assertNarratedPublicAsset(manifest.runId, manifest.narration.audio),
  ]);
  const capture = assertRenderableNarratedCapture(
    parseNarratedCaptureBundle(await readJsonFile(runPaths.captureBundlePath)),
  );
  const telemetry = parseNarratedTelemetry(await readJsonFile(telemetryPath));
  assertTelemetryMatchesCapture(telemetry, capture);
  assertNarratedManifestMatchesCapture(manifest, capture);
  await Promise.all([
    assertNarratedFileSha256(videoPath, manifest.source.videoSha256),
    assertNarratedFileSha256(telemetryPath, manifest.source.telemetrySha256),
    assertNarratedFileSha256(narrationPath, manifest.narration.audioSha256),
  ]);
  if (JSON.stringify(telemetry) !== JSON.stringify(manifest.telemetry)) {
    throw new Error(
      'Resolved manifest telemetry does not match the finalized telemetry file',
    );
  }
  return manifest;
}
