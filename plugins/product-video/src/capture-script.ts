import type { CaptureScenario } from './contracts';

type HeroScriptOptions = {
  scenario: CaptureScenario;
  outputPath: string;
  width: number;
  height: number;
};

export function parseCdpEndpoint(value: string) {
  const endpoint = new URL(value);
  if (!['http:', 'https:'].includes(endpoint.protocol)) {
    throw new Error('--cdp must use http or https');
  }
  if (endpoint.username || endpoint.password) {
    throw new Error('--cdp cannot contain embedded credentials');
  }
  if (!['127.0.0.1', '::1', '[::1]', 'localhost'].includes(endpoint.hostname)) {
    throw new Error('--cdp must target a loopback browser endpoint');
  }
  if (!endpoint.port) {
    throw new Error('--cdp must include the browser debug port');
  }

  return endpoint.href;
}

export function parseCaptureDimensions(
  widthValue: string,
  heightValue: string,
) {
  const width = Number(widthValue);
  const height = Number(heightValue);
  if (
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width < 320 ||
    width > 7680 ||
    height < 320 ||
    height > 7680
  ) {
    throw new Error(
      '--width and --height must be integers between 320 and 7680',
    );
  }

  return { width, height };
}

export function buildHeroScript({
  scenario,
  outputPath,
  width,
  height,
}: HeroScriptOptions) {
  const serializedScenario = JSON.stringify(scenario);
  const serializedOutput = JSON.stringify(outputPath);

  return `async page => {
  const scenario = ${serializedScenario};
  const allowedHosts = scenario.allowedHosts;
  const credentialPattern = /password|passcode|secret|token|api[-_ ]?key|one[-_ ]?time|otp|mfa/i;
  const assertAllowed = (value) => {
    const target = new URL(value, scenario.baseUrl);
    if (!allowedHosts.includes(target.hostname)) {
      throw new Error(\`Capture navigation refused host: \${target.hostname}\`);
    }
    return target.href;
  };

  await page.screencast.start({
    path: ${serializedOutput},
    size: {width: ${width}, height: ${height}},
  });

  try {
    for (const step of scenario.steps) {
      if (step.type === 'chapter') {
        await page.screencast.showChapter(step.title, {
          description: step.description,
          duration: step.durationMs,
        });
        continue;
      }
      if (step.type === 'goto') {
        await page.goto(assertAllowed(step.path), {waitUntil: step.waitFor});
        assertAllowed(page.url());
        continue;
      }
      if (step.type === 'click') {
        await page.locator(step.selector).click();
        await page.waitForTimeout(step.pauseAfterMs);
        assertAllowed(page.url());
        continue;
      }
      if (step.type === 'fill') {
        const field = page.locator(step.selector);
        const fieldIdentity = await field.evaluate((element) =>
          ['type', 'name', 'id', 'autocomplete', 'aria-label']
            .map((attribute) => element.getAttribute(attribute) ?? '')
            .join(' '),
        );
        if (credentialPattern.test(fieldIdentity)) {
          throw new Error('Capture refused a credential-entry field at runtime');
        }
        await field.fill('');
        await field.pressSequentially(step.value, {delay: 45});
        await page.waitForTimeout(step.pauseAfterMs);
        assertAllowed(page.url());
        continue;
      }
      await page.waitForTimeout(step.durationMs);
      assertAllowed(page.url());
    }
  } finally {
    await page.screencast.stop();
  }
}`;
}
