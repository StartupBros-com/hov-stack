# Authenticated capture

Capture is a two-pass operation: reconnaissance, then one scripted hero take.

## Preconditions

- The operator has already authenticated the dedicated `wsl-cdp` browser profile.
- The scenario uses committed fixtures or the intended walkthrough recipient's own read-only account through the supported impersonation flow. The viewport contains no credentials, unrelated customer data, private communications, internal-only values, or secrets.
- The repository-pinned Playwright capture runtime has been separately vetted. This skill never installs or updates browser tooling at runtime, and it never loads the upstream CLI's bundled skill instructions.
- The destination host is explicitly allowlisted in the scenario.
- The CDP endpoint is a loopback origin only (`127.0.0.1`, `::1`, or `localhost`), with no path, query, or hash.

If a login, MFA, CAPTCHA, password, token, recovery, consent wall, popup, or download appears, stop and hand the browser to the operator. Do not record until the wall is gone.

## Pass 1: reconnaissance

Attach to the existing CDP endpoint and inspect the rendered flow without recording. Resolve stable roles, labels, and `data-test` selectors. Confirm every top-level and child frame stays on a declared route; embedded third-party, `about:blank`, or otherwise undeclared frames make V1 non-capturable. Remove transient banners and notifications only through ordinary product controls.

Do not persist the inspected URL, selector, DOM text/HTML, accessible name, cookie/storage data, request data, account data, or credentials in narrated telemetry.

## Pass 2: narrated hero take

Create a `NarratedScenarioV1` with deliberate pauses, human-readable chapter cards, fixed timing, and only the interactions needed to explain the flow. It supports only bounded `chapter`, `goto`, `click`, `move`, `scroll`, and `pause` actions. Camera overrides belong to the resolved render manifest, never the capture scenario. Do not type values, use selectors that target credential fields, add wildcards to the route allowlist, or use ambiguous route paths.

### Framing and pointer motion

`project.captureScale` decouples layout from resolution: the browser lays out at `viewport / captureScale` CSS pixels while the screencast records at `viewport` device pixels. The capture forces that geometry through `Emulation.setDeviceMetricsOverride` and clears it afterwards, so an operator window of any shape records full-bleed. Without it the screencast fits the real window into the requested box and pads the remainder — a 1440x2479 window recorded into 1280x720 yields 418x720 of content beside 862x720 of dead matte. `1920x1080` at `captureScale: 1.5` (a 1280x720 layout) is the default for a desktop walkthrough.

The pointer only exists in telemetry where the mouse actually moved. `click` glides over `approachMs` before pressing and `move` glides to a target it never clicks, each emitting real `pointermove` events along an eased path; a tour built only from `goto` and bare clicks records a handful of cursor samples and reads as a frozen pointer. Verify each glide selector resolves to exactly one element before recording — the capture fails closed on an ambiguous target.

Selector strings and runtime element attributes are both screened against the prohibited-target pattern, so links whose own path contains a word like `profile` cannot be clicked; reach those routes with `goto`.

Run `narrated:capture --help`, then use `--dry-run` to inspect the deterministic program before recording:

```bash
pnpm narrated:capture \
  --scenario fixtures/narrated-scenario.example.json \
  --run-id product-tour-v1 \
  --dry-run
```

Dry run writes nothing and never attaches to CDP. A real run first proves the exact V1 APIs through the pinned Playwright runtime. The proof connects directly to CDP without CLI session snapshots, records a short mode-`0600` screencast in a private temporary directory, invokes the chapter API, stops, verifies non-empty output, disconnects without closing the browser, and deletes the directory before capture. If a capability is absent, the command fails closed before creating run output; do not install another browser tool as a workaround.

```bash
pnpm narrated:capture \
  --scenario fixtures/narrated-scenario.example.json \
  --run-id product-tour-v1 \
  --cdp http://127.0.0.1:9223
```

The run directory is exclusive and local under `tooling/product-video/public/generated/narrated/<run-id>/`. A complete bundle binds `capture.webm`, `telemetry.v1.json`, and the capture alignment marker. An interrupted run writes a non-renderable aborted bundle.

The raw recording is source material. Compose it in `NarratedBrowserTour` for branded framing, bounded camera motion, cursor/click overlays, output-space captions, timing, and transitions; do not treat raw browser recording as the final artifact unless the user asked for raw proof.
