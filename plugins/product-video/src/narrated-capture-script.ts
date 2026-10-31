import {
  type NarratedScenario,
  getNarratedCaptureLayout,
} from './narrated-contracts';
import { buildMotionHelperSource } from './narrated-motion';
import type { NarratedRunPaths } from './narrated-files';

type CaptureScriptOptions = {
  scenario: NarratedScenario;
  paths: NarratedRunPaths;
};

/**
 * How long the alignment clapperboard is painted into the recording. The
 * deliverable window starts after it: the marker exists to prove the video and
 * telemetry share an origin, not to be watched. Measured, not assumed — the
 * chapter fades out, so it is still legible past its declared 500ms duration.
 */
export const captureMarkerVisibleMs = 1_000;

export function buildNarratedCaptureScript({
  scenario,
  paths,
}: CaptureScriptOptions) {
  const serializedScenario = JSON.stringify(scenario);
  const serializedLayout = JSON.stringify(
    getNarratedCaptureLayout(scenario.project),
  );
  const motionHelpers = buildMotionHelperSource();
  const serializedOutput = JSON.stringify({
    videoPath: paths.captureVideoPath,
    telemetryPath: paths.telemetryPath,
    captureBundlePath: paths.captureBundlePath,
  });

  return `async (page) => {
  ${motionHelpers}
  const scenario = ${serializedScenario};
  const layout = ${serializedLayout};
  const output = ${serializedOutput};
  const context = page.context();
  const startedAt = Date.now();
  let cdpSession = null;
  let metricsOverridden = false;
  let originalWindowBounds = null;
  let windowResized = false;
  let captureStartedAt = null;
  let cursorX = Math.round(layout.width / 2);
  let cursorY = Math.round(layout.height * 0.6);
  const telemetryBinding = ${JSON.stringify(`__narratedTelemetry_${paths.runId}_V1`)};
  const maxBytes = 5 * 1024 * 1024;
  const events = [];
  let captureStarted = false;
  let failure = null;
  let lastEventAt = -1;
  let navigationGuard = null;
  let onFrameNavigated = null;
  let onPopup = null;
  let onDownload = null;
  let onPageClose = null;
  let markerTimeMs = 0;
  const prohibitedTargetPattern = /password|passcode|credential|secret|token|api[-_ ]?key|one[-_ ]?time|otp|mfa|two[-_ ]?factor|login|log[-_ ]?in|sign[-_ ]?in|recover|recovery|forgot|e-?mail|user[-_ ]?name|consent|captcha|cookie|microphone|\\bmic\\b|voice[-_ ]?clone|text[-_ ]?to[-_ ]?speech|\\btts\\b|upload|publish|send|share|download|install|profile|create[-_ ]?(?:an?[-_ ]?)?account/i;

  const fail = (message) => {
    if (!failure) failure = new Error(message);
  };
  const remainingMs = () => {
    const remaining = scenario.maxDurationMs - (Date.now() - startedAt);
    if (remaining <= 0) {
      throw new Error('Narrated capture exceeded its duration cap');
    }
    return remaining;
  };
  const throwIfFailed = () => {
    if (failure) throw failure;
    if (page.isClosed()) {
      throw new Error('Narrated capture disconnected from the selected tab');
    }
    remainingMs();
  };
  const runBounded = async (operation) => {
    const timeoutMs = remainingMs();
    let timeout;
    try {
      return await Promise.race([
        operation(),
        new Promise((_, reject) => {
          timeout = setTimeout(
            () => reject(new Error('Narrated capture action timed out')),
            timeoutMs,
          );
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  };
  const waitBounded = (durationMs) => {
    if (!Number.isInteger(durationMs) || durationMs < 0 || durationMs > remainingMs()) {
      throw new Error('Narrated capture wait exceeds its duration cap');
    }
    return runBounded(() => page.waitForTimeout(durationMs));
  };
  const isNormalized = (value) =>
    typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1;
  const isAllowedUrl = (value) => {
    let target;
    try {
      target = new URL(value, scenario.baseUrl);
    } catch {
      return false;
    }
    return (target.protocol === 'http:' || target.protocol === 'https:') &&
      !target.username &&
      !target.password &&
      !target.search &&
      !target.hash &&
      scenario.allowedHosts.includes(target.hostname) &&
      scenario.routes.some((route) => {
        const declared = new URL(route.path, scenario.baseUrl);
        return declared.origin === target.origin && declared.pathname === target.pathname;
      });
  };
  const assertCurrentUrl = () => {
    if (!isAllowedUrl(page.url())) {
      throw new Error('Narrated capture refused an unsafe top-frame runtime target');
    }
  };
  const assertAllFrameUrls = () => {
    const unsafeFrame = page.frames().find((frame) => !isAllowedUrl(frame.url()));
    if (unsafeFrame) {
      throw new Error('Narrated capture refused an unsafe child-frame runtime target');
    }
  };
  const telemetryByteLength = (candidateEvents) =>
    Buffer.byteLength(JSON.stringify({
      schemaVersion: 1,
      runId: ${JSON.stringify(paths.runId)},
      durationMs: scenario.maxDurationMs,
      channels: ['cursor', 'click', 'element', 'scroll', 'route'],
      events: candidateEvents,
    }), 'utf8');
  const assertSafeClickTarget = async (selector) => {
    const locator = page.locator(selector);
    const count = await runBounded(() => locator.count());
    if (count !== 1) {
      throw new Error('Narrated capture refused an ambiguous runtime click target');
    }
    const identity = await runBounded(() => locator.evaluate((element) => {
      const attributes = [
        'type', 'name', 'id', 'autocomplete', 'aria-label', 'role', 'href',
        'formaction', 'action', 'data-test', 'data-testid',
      ];
      return attributes
        .map((attribute) => element.getAttribute(attribute) ?? '')
        .join(' ')
        .slice(0, 1024);
    }));
    if (prohibitedTargetPattern.test(identity)) {
      throw new Error('Narrated capture refused a prohibited runtime click target');
    }
    return locator;
  };
  // 16ms keeps at least one real sample per 30fps frame; the previous 40ms
  // sampled below the frame rate and the overlay had to invent the gaps.
  const pointerStepMs = 16;
  const glideTo = async (locator, durationMs) => {
    const box = await runBounded(() => locator.boundingBox());
    if (!box || !(box.width > 0) || !(box.height > 0)) {
      throw new Error('Narrated capture could not resolve a pointer target box');
    }
    const seed = box.x + box.y * 1.7 + box.width * 0.3;
    const aim = planPointerTarget({
      x: box.x,
      y: box.y,
      width: box.width,
      height: box.height,
    });
    const steps = Math.max(1, Math.floor(durationMs / pointerStepMs));
    const path = planGlidePath({
      fromX: cursorX,
      fromY: cursorY,
      toX: aim.x,
      toY: aim.y,
      steps,
      seed,
    });
    for (const point of path) {
      await runBounded(() => page.mouse.move(point.x, point.y));
      await waitBounded(pointerStepMs);
    }
    cursorX = aim.x;
    cursorY = aim.y;
  };
  // A resting hand still drifts. Without this the pointer freezes for seconds,
  // which is the strongest tell that the cursor is not real.
  const dwell = async (durationMs) => {
    if (durationMs <= 0) return;
    const steps = Math.floor(durationMs / pointerStepMs);
    if (steps < 2) {
      await waitBounded(durationMs);
      return;
    }
    const path = planDriftPath({
      x: cursorX,
      y: cursorY,
      steps,
      seed: cursorX * 0.11 + cursorY * 0.07,
    });
    for (const point of path) {
      await runBounded(() => page.mouse.move(point.x, point.y));
      await waitBounded(pointerStepMs);
    }
  };
  const append = (event) => {
    const tMs = Math.max(0, Date.now() - (captureStartedAt ?? startedAt));
    if (tMs < lastEventAt || tMs >= scenario.maxDurationMs) {
      fail('Narrated telemetry timestamp exceeded a bounded capture window');
      return;
    }
    let safe;
    if (event && (event.channel === 'cursor' || event.channel === 'click' || event.channel === 'scroll')) {
      if (!isNormalized(event.x) || !isNormalized(event.y)) {
        fail('Narrated telemetry rejected unsafe normalized geometry');
        return;
      }
      safe = {channel: event.channel, x: event.x, y: event.y};
    } else if (event && event.channel === 'element') {
      const rect = event.rect;
      if (!rect || !isNormalized(rect.x) || !isNormalized(rect.y) || !isNormalized(rect.width) || !isNormalized(rect.height) || rect.width === 0 || rect.height === 0 || rect.x + rect.width > 1 || rect.y + rect.height > 1) {
        fail('Narrated telemetry rejected unsafe element geometry');
        return;
      }
      safe = {channel: 'element', rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}};
    } else if (event && event.channel === 'route') {
      if (typeof event.routeId !== 'string' || !scenario.routes.some((route) => route.id === event.routeId)) {
        fail('Narrated telemetry rejected an undeclared route ID');
        return;
      }
      safe = {channel: 'route', routeId: event.routeId};
    } else {
      fail('Narrated telemetry rejected an unknown channel');
      return;
    }
    if (events.length >= scenario.maxEvents) {
      fail('Narrated telemetry exceeded its event cap');
      return;
    }
    const next = {...safe, seq: events.length, tMs};
    if (telemetryByteLength([...events, next]) > maxBytes) {
      fail('Narrated telemetry exceeded its byte cap');
      return;
    }
    events.push(next);
    lastEventAt = tMs;
  };
  const installListeners = async () => {
    await page.evaluate(({binding, routes}) => {
      const root = window;
      root.__narratedTelemetryCleanupV1 && root.__narratedTelemetryCleanupV1();
      const pendingDeliveries = new Set();
      const send = (event) => {
        const delivery = Promise.resolve(root[binding](event));
        pendingDeliveries.add(delivery);
        void delivery.then(
          () => pendingDeliveries.delete(delivery),
          () => pendingDeliveries.delete(delivery),
        );
      };
      root.__narratedTelemetryDrainV1 = () =>
        Promise.all([...pendingDeliveries]).then(() => undefined);
      const clamp = (value) => Math.max(0, Math.min(1, value));
      const point = (event) => ({
        x: clamp(event.clientX / Math.max(1, innerWidth)),
        y: clamp(event.clientY / Math.max(1, innerHeight)),
      });
      const rect = (element) => {
        if (!(element instanceof Element)) return null;
        const box = element.getBoundingClientRect();
        const x = clamp(box.left / Math.max(1, innerWidth));
        const y = clamp(box.top / Math.max(1, innerHeight));
        const width = clamp(box.width / Math.max(1, innerWidth));
        const height = clamp(box.height / Math.max(1, innerHeight));
        if (width === 0 || height === 0 || x + width > 1 || y + height > 1) return null;
        return {x, y, width, height};
      };
      const routeId = () => {
        const route = routes.find((candidate) => candidate.path === location.pathname);
        return route ? route.id : null;
      };
      let lastPointerAt = -Infinity;
      let lastScrollAt = -Infinity;
      const onPointer = (event) => {
        const now = performance.now();
        if (now - lastPointerAt < 15) return;
        lastPointerAt = now;
        send({channel: 'cursor', ...point(event)});
      };
      const onClick = (event) => {
        send({channel: 'click', ...point(event)});
        const targetRect = rect(event.target);
        if (targetRect) send({channel: 'element', rect: targetRect});
      };
      const onScroll = (event) => {
        const now = performance.now();
        if (now - lastScrollAt < 120) return;
        lastScrollAt = now;
        const target = event && event.target;
        const node =
          target instanceof Element
            ? target
            : document.scrollingElement || document.documentElement;
        if (!(node instanceof Element)) return;
        send({
          channel: 'scroll',
          x: clamp(node.scrollLeft / Math.max(1, node.scrollWidth - node.clientWidth)),
          y: clamp(node.scrollTop / Math.max(1, node.scrollHeight - node.clientHeight)),
        });
      };
      const emitRoute = () => {
        const id = routeId();
        if (!id) {
          send({channel: 'invalid-route'});
          return;
        }
        send({channel: 'route', routeId: id});
      };
      const originalPushState = history.pushState;
      const originalReplaceState = history.replaceState;
      history.pushState = function (...args) {
        const result = originalPushState.apply(this, args);
        emitRoute();
        return result;
      };
      history.replaceState = function (...args) {
        const result = originalReplaceState.apply(this, args);
        emitRoute();
        return result;
      };
      document.addEventListener('pointermove', onPointer, {passive: true});
      document.addEventListener('click', onClick, {capture: true, passive: true});
      addEventListener('scroll', onScroll, {capture: true, passive: true});
      addEventListener('popstate', emitRoute);
      root.__narratedTelemetryCleanupV1 = () => {
        document.removeEventListener('pointermove', onPointer);
        document.removeEventListener('click', onClick, true);
        removeEventListener('scroll', onScroll, true);
        removeEventListener('popstate', emitRoute);
        history.pushState = originalPushState;
        history.replaceState = originalReplaceState;
        delete root.__narratedTelemetryDrainV1;
        delete root.__narratedTelemetryCleanupV1;
      };
      emitRoute();
    }, {binding: telemetryBinding, routes: scenario.routes});
  };
  const drainTelemetry = () =>
    runBounded(() => page.evaluate(() =>
      window.__narratedTelemetryDrainV1
        ? window.__narratedTelemetryDrainV1()
        : undefined,
    ));
  const writeJson = async (targetPath, value) => {
    const {chmod, link, open, unlink} = await import('node:fs/promises');
    const {basename, dirname, join} = await import('node:path');
    const temporaryPath = join(dirname(targetPath), '.' + basename(targetPath) + '.' + process.pid + '.tmp');
    const handle = await open(temporaryPath, 'wx', 0o600);
    try {
      await handle.writeFile(JSON.stringify(value, null, 2) + '\\n', 'utf8');
      await handle.sync();
    } finally {
      await handle.close();
    }
    try {
      await link(temporaryPath, targetPath);
    } finally {
      await unlink(temporaryPath).catch(() => undefined);
    }
    await chmod(targetPath, 0o600);
  };

  try {
    await page.exposeBinding(telemetryBinding, (_source, event) => append(event));
    navigationGuard = async (route) => {
      const request = route.request();
      if (request.isNavigationRequest() && !isAllowedUrl(request.url())) {
        fail('Narrated capture blocked an unsafe frame navigation');
        await route.abort();
        return;
      }
      await route.continue();
    };
    onFrameNavigated = (frame) => {
      if (!isAllowedUrl(frame.url())) {
        fail('Narrated capture observed an unsafe frame navigation');
      }
    };
    onPopup = (popup) => {
      fail('Narrated capture refused a popup');
      void popup.close().catch(() => undefined);
    };
    onDownload = () => fail('Narrated capture refused a download');
    onPageClose = () => fail('Narrated capture disconnected from the selected tab');
    await context.route('**/*', navigationGuard);
    page.on('framenavigated', onFrameNavigated);
    page.on('popup', onPopup);
    page.on('download', onDownload);
    page.on('close', onPageClose);
    assertCurrentUrl();
    assertAllFrameUrls();

    cdpSession = await runBounded(() => context.newCDPSession(page));

    // Chrome cannot composite more device pixels than the window surface
    // provides, so a window too small for the requested frame silently yields a
    // letterboxed capture that still reports the declared dimensions. Measure
    // the REAL backing scale first: once the emulation override is applied the
    // page reports the emulated devicePixelRatio, which makes any check
    // downstream of it tautological.
    const nativeSurface = await runBounded(() =>
      page.evaluate(() => ({
        dpr: window.devicePixelRatio,
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        outerWidth: window.outerWidth,
        outerHeight: window.outerHeight,
      })),
    );
    const neededCssWidth = Math.ceil(scenario.project.viewport.width / nativeSurface.dpr);
    const neededCssHeight = Math.ceil(scenario.project.viewport.height / nativeSurface.dpr);

    if (
      nativeSurface.innerWidth < neededCssWidth ||
      nativeSurface.innerHeight < neededCssHeight
    ) {
      try {
        const {windowId, bounds} = await runBounded(() =>
          cdpSession.send('Browser.getWindowForTarget'),
        );
        originalWindowBounds = {windowId, bounds};
        const chromeWidth = Math.max(0, bounds.width - nativeSurface.innerWidth);
        const chromeHeight = Math.max(0, bounds.height - nativeSurface.innerHeight);
        await runBounded(() =>
          cdpSession.send('Browser.setWindowBounds', {
            windowId,
            bounds: {
              windowState: 'normal',
              width: neededCssWidth + chromeWidth,
              height: neededCssHeight + chromeHeight,
            },
          }),
        );
        windowResized = true;
        await waitBounded(800);
      } catch {
        // Sizing is best effort; the assertion below is the gate.
      }
    }

    const resized = await runBounded(() =>
      page.evaluate(() => ({
        dpr: window.devicePixelRatio,
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
      })),
    );
    if (
      resized.innerWidth * resized.dpr < scenario.project.viewport.width ||
      resized.innerHeight * resized.dpr < scenario.project.viewport.height
    ) {
      throw new Error(
        'Narrated capture cannot fill the requested frame. The window backs ' +
          Math.round(resized.innerWidth * resized.dpr) + 'x' +
          Math.round(resized.innerHeight * resized.dpr) +
          ' device pixels at devicePixelRatio ' + resized.dpr +
          ', but project.viewport asks for ' +
          scenario.project.viewport.width + 'x' + scenario.project.viewport.height +
          '. Move the browser to a larger or higher-density display, or lower project.viewport.',
      );
    }

    // captureScale cannot exceed what the display natively backs. Asking for 1.5x
    // on a devicePixelRatio-1 screen does not upscale the captured surface: the
    // frame still reports the declared size while the app fills only a corner of
    // it, and every mechanical check passes. Clamp to the real ratio and widen
    // the CSS layout to compensate.
    const effectiveScale = Math.min(
      scenario.project.captureScale,
      resized.dpr || 1,
    );
    const effectiveLayout = {
      width: Math.round(scenario.project.viewport.width / effectiveScale),
      height: Math.round(scenario.project.viewport.height / effectiveScale),
    };
    await runBounded(() =>
      cdpSession.send('Emulation.setDeviceMetricsOverride', {
        deviceScaleFactor: effectiveScale,
        height: effectiveLayout.height,
        mobile: false,
        width: effectiveLayout.width,
      }),
    );
    metricsOverridden = true;
    await waitBounded(1_200);

    // Prove the surface can actually back the requested frame. Without this the
    // capture degrades silently: the file still reports the declared dimensions
    // while the app occupies a corner of it, and every mechanical check passes.
    const surface = await runBounded(() =>
      page.evaluate(() => ({
        width: Math.round(window.innerWidth * window.devicePixelRatio),
        height: Math.round(window.innerHeight * window.devicePixelRatio),
      })),
    );
    if (
      surface.width < scenario.project.viewport.width ||
      surface.height < scenario.project.viewport.height
    ) {
      throw new Error(
        'Narrated capture cannot fill the requested frame: the browser window backs ' +
          surface.width + 'x' + surface.height + ' device pixels but the capture needs ' +
          scenario.project.viewport.width + 'x' + scenario.project.viewport.height +
          '. Enlarge or maximize the browser window, or lower project.viewport.',
      );
    }
    assertCurrentUrl();
    assertAllFrameUrls();

    await runBounded(() => page.screencast.start({
      path: output.videoPath,
      size: {
        width: scenario.project.viewport.width,
        height: scenario.project.viewport.height,
      },
    }));
    captureStarted = true;
    // Telemetry shares the recorded video's clock, so viewport reflow before
    // recording can never offset an overlay from the frame it annotates.
    captureStartedAt = Date.now();
    markerTimeMs = 0;
    await installListeners();
    await runBounded(() => page.mouse.move(cursorX, cursorY));

    for (const step of scenario.steps) {
      throwIfFailed();
      if (step.type === 'chapter') {
        await runBounded(() => page.screencast.showChapter(step.title, {
          description: step.description,
          duration: step.durationMs,
        }));
      } else if (step.type === 'goto') {
        const route = scenario.routes.find((candidate) => candidate.id === step.routeId);
        if (!route) throw new Error('Narrated capture encountered an undeclared route');
        const target = new URL(route.path, scenario.baseUrl);
        if (!isAllowedUrl(target.href)) throw new Error('Narrated capture refused an unsafe scenario route');
        await runBounded(() => page.goto(target.href, {
          timeout: remainingMs(),
          waitUntil: step.waitFor,
        }));
        assertCurrentUrl();
        assertAllFrameUrls();
        await installListeners();
      } else if (step.type === 'click') {
        const locator = await assertSafeClickTarget(step.selector);
        await glideTo(locator, step.approachMs);
        await runBounded(() => locator.click({
          timeout: remainingMs(),
        }));
        await dwell(step.pauseAfterMs);
        assertCurrentUrl();
        assertAllFrameUrls();
        await installListeners();
      } else if (step.type === 'move') {
        const locator = await assertSafeClickTarget(step.selector);
        await glideTo(locator, step.durationMs);
        await dwell(step.pauseAfterMs);
        assertCurrentUrl();
        assertAllFrameUrls();
      } else if (step.type === 'scroll') {
        await runBounded(() => page.mouse.wheel(0, step.deltaY));
        await dwell(step.pauseAfterMs);
        assertCurrentUrl();
        assertAllFrameUrls();
      } else {
        await dwell(step.durationMs);
      }
      await drainTelemetry();
      throwIfFailed();
    }

    await drainTelemetry();
    // Measured before stop() so flushing the container is not counted as
    // recorded timeline; stop() latency would otherwise declare a duration
    // the video does not contain.
    const durationMs = Math.max(500, Date.now() - (captureStartedAt ?? startedAt));
    await runBounded(() => page.screencast.stop());
    captureStarted = false;
    throwIfFailed();
    if (durationMs > scenario.maxDurationMs) {
      throw new Error('Narrated capture exceeded its duration cap');
    }
    const {chmod, readFile} = await import('node:fs/promises');
    const {createHash} = await import('node:crypto');
    const digestFile = async (filePath) => createHash('sha256')
      .update(await readFile(filePath))
      .digest('hex');
    await chmod(output.videoPath, 0o600);
    const telemetry = {
      schemaVersion: 1,
      runId: ${JSON.stringify(paths.runId)},
      durationMs,
      channels: ['cursor', 'click', 'element', 'scroll', 'route'],
      events,
    };
    await writeJson(output.telemetryPath, telemetry);
    const [videoSha256, telemetrySha256] = await Promise.all([
      digestFile(output.videoPath),
      digestFile(output.telemetryPath),
    ]);
    await writeJson(output.captureBundlePath, {
      schemaVersion: 1,
      kind: 'narrated-capture-bundle',
      status: 'complete',
      renderable: true,
      runId: ${JSON.stringify(paths.runId)},
      scenarioId: scenario.id,
      project: scenario.project,
      routeIds: scenario.routes.map((route) => route.id),
      viewport: scenario.project.viewport,
      fps: scenario.project.fps,
      durationMs,
      marker: {type: 'clapperboard', tMs: markerTimeMs},
      assets: {
        video: ${JSON.stringify(`${paths.publicPrefix}/capture.webm`)},
        telemetry: ${JSON.stringify(`${paths.publicPrefix}/telemetry.v1.json`)},
      },
      digests: {videoSha256, telemetrySha256},
    });
  } finally {
    await page.evaluate(() => {
      window.__narratedTelemetryCleanupV1 && window.__narratedTelemetryCleanupV1();
    }).catch(() => undefined);
    if (navigationGuard) await context.unroute('**/*', navigationGuard).catch(() => undefined);
    if (onFrameNavigated) page.off('framenavigated', onFrameNavigated);
    if (onPopup) page.off('popup', onPopup);
    if (onDownload) page.off('download', onDownload);
    if (onPageClose) page.off('close', onPageClose);
    if (captureStarted) await page.screencast.stop().catch(() => undefined);
    if (cdpSession) {
      if (metricsOverridden) {
        await cdpSession
          .send('Emulation.clearDeviceMetricsOverride')
          .catch(() => undefined);
      }
      if (windowResized && originalWindowBounds) {
        await cdpSession
          .send('Browser.setWindowBounds', {
            windowId: originalWindowBounds.windowId,
            bounds: {
              width: originalWindowBounds.bounds.width,
              height: originalWindowBounds.bounds.height,
            },
          })
          .catch(() => undefined);
      }
      await cdpSession.detach().catch(() => undefined);
    }
  }
}`;
}
