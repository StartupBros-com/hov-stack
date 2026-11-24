import { availableParallelism } from 'node:os';

/**
 * Memory bounds for a RecordedTour render.
 *
 * Remotion's defaults open one browser tab per two cores (up to 8) and size the
 * compositor's frame cache from free memory. A recorded cut decodes every source
 * clip in every tab, so on a many-core machine those defaults outgrow the box:
 * a 69 s cut of two ~1080p sources was killed at a 10 GiB memory limit.
 */
export const RECORDED_DEFAULT_MAX_CONCURRENCY = 4;
export const RECORDED_FRAME_CACHE_BYTES = 512 * 1024 * 1024;

export interface RecordedRenderLimits {
  concurrency: number;
  offthreadVideoCacheSizeInBytes: number;
}

export function resolveRecordedRenderLimits(
  concurrencyFlag: string | undefined,
  cpus: number = availableParallelism(),
): RecordedRenderLimits {
  return {
    concurrency:
      concurrencyFlag === undefined
        ? Math.max(
            1,
            Math.min(RECORDED_DEFAULT_MAX_CONCURRENCY, Math.floor(cpus / 2)),
          )
        : parseConcurrency(concurrencyFlag, cpus),
    offthreadVideoCacheSizeInBytes: RECORDED_FRAME_CACHE_BYTES,
  };
}

function parseConcurrency(flag: string, cpus: number): number {
  if (!/^[1-9]\d*$/.test(flag)) {
    throw new Error(
      `--concurrency must be a whole number of at least 1, got "${flag}"`,
    );
  }
  const value = Number(flag);
  if (value > cpus) {
    throw new Error(
      `--concurrency ${value} exceeds this machine's ${cpus} cores`,
    );
  }
  return value;
}
