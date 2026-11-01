/**
 * Shared value objects for the narrated capture contracts: identifiers,
 * geometry, local asset paths, and the route/target safety patterns every
 * narrated schema is screened against.
 */
import { z } from 'zod';

export const narratedCompositionId = 'NarratedBrowserTour' as const;
export const narratedSchemaVersion = 1 as const;
export const maxNarratedDurationMs = 10 * 60 * 1_000;
export const maxNarratedEvents = 10_000;
export const maxNarratedCues = 300;
export const maxNarratedEvidenceSamples = 180;

export const kebabIdSchema = z
  .string()
  .min(1)
  .max(80)
  .regex(/^[a-z0-9][a-z0-9-]*$/, 'Use a lowercase kebab-case identifier');

export const hexColorSchema = z
  .string()
  .regex(/^#[0-9a-f]{6}$/i, 'Use a six-digit hex color');

export const normalizedNumberSchema = z
  .number()
  .finite()
  .min(0, 'Geometry must be normalized between 0 and 1')
  .max(1, 'Geometry must be normalized between 0 and 1');

export const positiveNormalizedNumberSchema = normalizedNumberSchema.refine(
  (value) => value > 0,
  'Geometry must be greater than zero',
);

export const publicAssetPathSchema = z
  .string()
  .trim()
  .min(1)
  .max(240)
  .refine((value) => {
    if (
      value.startsWith('/') ||
      value.includes('\\') ||
      /^[a-z][a-z0-9+.-]*:/i.test(value)
    ) {
      return false;
    }
    const segments = value.split('/');
    return (
      segments.every(
        (segment) => segment.length > 0 && segment !== '.' && segment !== '..',
      ) && /^[a-z0-9][a-z0-9._/-]*$/i.test(value)
    );
  }, 'Use a local public asset path without URL schemes or dot segments');

function hasNonPrintableCharacter(value: string) {
  return [...value].some((character) => {
    const codePoint = character.codePointAt(0);
    return codePoint !== undefined && (codePoint <= 31 || codePoint === 127);
  });
}

export const prohibitedRoutePattern =
  /(?:^|\/)(?:auth|login|log-in|signin|sign-in|mfa|otp|two-factor|2fa|recover|recovery|forgot-password|reset-password)(?:\/|$)/i;

function isSafeRoutePath(value: string) {
  if (
    !value.startsWith('/') ||
    value.startsWith('//') ||
    value.includes('?') ||
    value.includes('#') ||
    value.includes('\\') ||
    hasNonPrintableCharacter(value)
  ) {
    return false;
  }

  try {
    const decoded = decodeURIComponent(value);
    return (
      decoded === value &&
      !decoded.startsWith('//') &&
      !decoded.includes('\\') &&
      !decoded.includes('?') &&
      !decoded.includes('#') &&
      !prohibitedRoutePattern.test(decoded) &&
      !hasNonPrintableCharacter(decoded) &&
      /^\/[a-z0-9._~/-]*$/i.test(decoded) &&
      !decoded.split('/').some((segment) => segment === '.' || segment === '..')
    );
  } catch {
    return false;
  }
}

export const routePathSchema = z
  .string()
  .min(1)
  .max(200)
  .refine(
    isSafeRoutePath,
    'Use an absolute route path without query, hash, URL schemes, or dot segments',
  );

export const hostSchema = z
  .string()
  .trim()
  .min(1)
  .max(253)
  .regex(
    /^(?:localhost|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9][a-z0-9-]{0,61}[a-z0-9]|(?:\d{1,3}\.){3}\d{1,3})$/i,
    'Use a hostname without a protocol or path',
  );

export const captureDurationSchema = z
  .number()
  .int()
  .min(500)
  .max(maxNarratedDurationMs);

export const prohibitedTargetPattern =
  /password|passcode|credential|secret|token|api[-_ ]?key|one[-_ ]?time|otp|mfa|two[-_ ]?factor|login|log[-_ ]?in|sign[-_ ]?in|recover|recovery|forgot|e-?mail|user[-_ ]?name|consent|captcha|cookie|microphone|\bmic\b|voice[-_ ]?clone|text[-_ ]?to[-_ ]?speech|\btts\b|upload|publish|send|share|download|install|profile|create[-_ ]?(?:an?[-_ ]?)?account/i;

function isSafeBaseUrl(value: string) {
  try {
    const url = new URL(value);
    return (
      (url.protocol === 'http:' || url.protocol === 'https:') &&
      !url.username &&
      !url.password &&
      !url.search &&
      !url.hash &&
      !prohibitedRoutePattern.test(url.pathname)
    );
  } catch {
    return false;
  }
}

export const baseUrlSchema = z
  .string()
  .url()
  .refine(
    isSafeBaseUrl,
    'Use an HTTP(S) base URL without credentials, query, or hash',
  );
