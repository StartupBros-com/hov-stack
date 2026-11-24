import { readJsonFile } from './files';
import { assertSingleLinkRegularFile } from './narrated-files';
import { parseRecordedResolvedManifest } from './recorded-contracts';
import {
  assertRecordedFileSha256,
  assertRecordedPublicAsset,
  assertRecordedRunFile,
} from './recorded-files';

/** Apply the same provenance checks before rendering or verifying a tour. */
export async function loadValidatedRecordedManifest(manifestPath: string) {
  await assertSingleLinkRegularFile(manifestPath);
  const manifest = parseRecordedResolvedManifest(
    await readJsonFile(manifestPath),
  );
  await assertRecordedRunFile(manifest.runId, manifestPath, 'resolved.v1.json');
  const assets = [
    ...manifest.sources.map((source) => ({
      asset: source.asset,
      sha256: source.sha256,
    })),
    ...manifest.audio.map((track) => ({
      asset: track.asset,
      sha256: track.sha256,
    })),
  ];
  for (const { asset, sha256 } of assets) {
    const absolutePath = await assertRecordedPublicAsset(manifest.runId, asset);
    await assertRecordedFileSha256(absolutePath, sha256);
  }
  return manifest;
}
