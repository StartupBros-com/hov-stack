import type { NarratedScenario } from './narrated-contracts';

export function buildNarratedCapabilityProbe(
  outputPath: string,
  scenario: NarratedScenario,
) {
  const serializedOutputPath = JSON.stringify(outputPath);
  const serializedScenario = JSON.stringify(scenario);
  return `async (page) => {
  const scenario = ${serializedScenario};
  const context = page.context();
  const htmlLocator = typeof page.locator === 'function' ? page.locator('html') : undefined;
  const required = [
    ['screencast.start', page.screencast && page.screencast.start],
    ['screencast.stop', page.screencast && page.screencast.stop],
    ['screencast.showChapter', page.screencast && page.screencast.showChapter],
    ['context.newCDPSession', context && context.newCDPSession],
    ['context.route', context && context.route],
    ['context.unroute', context && context.unroute],
    ['locator.boundingBox', htmlLocator && htmlLocator.boundingBox],
    ['locator.count', htmlLocator && htmlLocator.count],
    ['locator.evaluate', htmlLocator && htmlLocator.evaluate],
    ['page.exposeBinding', page.exposeBinding],
    ['page.evaluate', page.evaluate],
    ['page.goto', page.goto],
    ['page.isClosed', page.isClosed],
    ['page.frames', page.frames],
    ['page.locator', page.locator],
    ['page.mainFrame', page.mainFrame],
    ['page.mouse.move', page.mouse && page.mouse.move],
    ['page.mouse.wheel', page.mouse && page.mouse.wheel],
    ['page.off', page.off],
    ['page.on', page.on],
    ['page.url', page.url],
    ['page.waitForTimeout', page.waitForTimeout],
  ];
  for (const [name, capability] of required) {
    if (typeof capability !== 'function') {
      throw new Error('Narrated capture prerequisite unavailable: ' + name);
    }
  }
  await page.evaluate(() => Boolean(document.documentElement));
  if (await htmlLocator.count() !== 1) {
    throw new Error('Narrated capture prerequisite unavailable: selected tab has no unique document root');
  }
  await htmlLocator.evaluate((element) => Boolean(element));
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
  if (page.frames().some((frame) => !isAllowedUrl(frame.url()))) {
    throw new Error('Narrated capture prerequisite refused an unsafe frame before probe recording');
  }
  await page.screencast.start({
    path: ${serializedOutputPath},
    size: {width: 320, height: 320},
  });
  try {
    await page.screencast.showChapter('CAPTURE CAPABILITY PROBE', {
      description: 'Temporary local probe; deleted before capture',
      duration: 300,
    });
  } finally {
    await page.screencast.stop();
  }
}`;
}
