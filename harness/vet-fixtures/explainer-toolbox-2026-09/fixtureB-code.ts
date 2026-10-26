// apps/console/src/features/upload/submit.ts
import { withRetries } from '@console/net' // internals live in another package; not shown here
import { fingerprint } from './fingerprint'
import { AssetStore } from './store'
import { ScanWorker } from '../scan/worker'
import { go } from '../router'
import { metrics } from '../metrics'

export interface UploadFlags {
  preview?: boolean
  classicRedirect?: boolean
}

export interface UploadForm {
  file: Blob
  label: string
}

export interface Asset {
  id: string
  label: string
  digest: string
}

export async function handleUpload(form: UploadForm, flags: UploadFlags = {}): Promise<void> {
  const label = normalizeLabel(form.label)
  const asset = await registerAsset(form.file, label, flags)
  if (!flags.preview) {
    queueScan(asset) // fire-and-forget: deliberately not awaited
  }
  showAsset(asset.id, flags)
}

function normalizeLabel(text: string): string {
  // "#draft Q3 deck" -> "draft: Q3 deck"
  return text.replace(/^#(\w[\w-]*)\s*/, (_m, tag: string) => `${tag}: `)
}

async function registerAsset(file: Blob, label: string, flags: UploadFlags): Promise<Asset> {
  const digest = await fingerprint(file)
  const existing = AssetStore.findByDigest(digest)
  if (existing && !flags.preview) {
    metrics.count('asset.dedup')
    return existing
  }
  const asset = AssetStore.insert({ label, digest })
  await storeBlob(asset, file)
  return asset
}

async function storeBlob(asset: Asset, file: Blob): Promise<void> {
  await withRetries(() => AssetStore.putBlob(asset.id, file), { attempts: 3 })
  metrics.count('asset.stored')
}

function queueScan(asset: Asset): void {
  const worker = new ScanWorker(asset)
  void worker.run().then(
    (verdict) => AssetStore.attachScan(asset.id, verdict),
    (err: unknown) => AssetStore.markScanFailed(asset.id, err),
  )
}

function showAsset(id: string, flags: UploadFlags): void {
  if (flags.classicRedirect) {
    window.location.assign(`/assets/${id}`) // full page reload
    return
  }
  go(`/assets/${id}`)
  watchProgress(id)
}

function watchProgress(id: string): void {
  const es = new EventSource(`/api/assets/${id}/progress`)
  es.onmessage = (ev) => AssetStore.applyProgress(id, JSON.parse(ev.data))
  es.onerror = () => es.close()
}
