import assert from 'node:assert/strict';
import { test } from 'node:test';

import fixture from '../fixtures/narrated-scenario.example.json';
import { narratedScenarioSchema } from './narrated-contracts';

const prohibitedMessage =
  'Capture scenarios cannot target credential, consent, microphone, publishing, or other prohibited controls';
const selectorPath = ['steps', 0, 'selector'];
const prohibitedIssue = {
  code: 'custom',
  message: prohibitedMessage,
  path: selectorPath,
};
const tooLongIssue = {
  origin: 'string',
  code: 'too_big',
  maximum: 300,
  inclusive: true,
  path: selectorPath,
  message: 'Too big: expected string to have <=300 characters',
};
const emptyIssue = {
  origin: 'string',
  code: 'too_small',
  minimum: 1,
  inclusive: true,
  path: selectorPath,
  message: 'Too small: expected string to have >=1 characters',
};

function parse(step: Record<string, unknown>) {
  return narratedScenarioSchema.safeParse({ ...fixture, steps: [step] });
}

function expectIssues(step: Record<string, unknown>, issues: unknown[]) {
  // Repeating the parse catches accidentally stateful regular expressions.
  for (let repeat = 0; repeat < 3; repeat++) {
    const result = parse(step);
    assert.equal(result.success, false);
    if (!result.success) assert.deepEqual(result.error.issues, issues);
  }
}

// Keep these independent of the production regex so a removed category fails.
const prohibitedSelectors = [
  'password',
  'passcode',
  'credential',
  'secret',
  'token',
  'api-key',
  'api_key',
  'api key',
  'apikey',
  'one-time',
  'one_time',
  'one time',
  'onetime',
  'otp',
  'mfa',
  'two-factor',
  'two_factor',
  'two factor',
  'twofactor',
  'login',
  'log-in',
  'log_in',
  'log in',
  'sign-in',
  'sign_in',
  'sign in',
  'signin',
  'recover',
  'recovery',
  'forgot',
  'email',
  'e-mail',
  'username',
  'user-name',
  'user_name',
  'user name',
  'consent',
  'captcha',
  'cookie',
  'microphone',
  'mic',
  'voice-clone',
  'voice_clone',
  'voice clone',
  'voiceclone',
  'text-to-speech',
  'text_to_speech',
  'text to speech',
  'texttospeech',
  'tts',
  'upload',
  'publish',
  'send',
  'share',
  'download',
  'install',
  'profile',
  'create-account',
  'create-an-account',
  'create-a-account',
  'create_an_account',
  'create an account',
  'createaccount',
];

for (const type of ['click', 'move'] as const) {
  const timing = type === 'click' ? 'approachMs' : 'durationMs';
  const minimum = type === 'click' ? 0 : 200;
  const defaults =
    type === 'click'
      ? { approachMs: 600, pauseAfterMs: 800 }
      : { durationMs: 700, pauseAfterMs: 400 };

  for (const target of prohibitedSelectors) {
    test(`${type} rejects prohibited ${target}, mixed case and padding`, () => {
      for (const selector of [
        target,
        target.toUpperCase(),
        ` \t${target}\n `,
      ]) {
        expectIssues({ type, selector }, [prohibitedIssue]);
      }
    });
  }

  test(`${type} preserves trimmed allowed selectors and defaults`, () => {
    for (const selector of [
      '[data-test="reports"]',
      '.dynamic',
      '.ttscape',
      'x'.repeat(300),
    ]) {
      const input = { type, selector: ` \t${selector}\n ` };
      for (let repeat = 0; repeat < 3; repeat++) {
        const result = parse(input);
        assert.equal(result.success, true);
        if (result.success) {
          assert.deepEqual(result.data, {
            ...fixture,
            project: { ...fixture.project, captureScale: 1 },
            steps: [{ type, selector, ...defaults }],
          });
        }
        assert.equal(input.selector, ` \t${selector}\n `);
      }
    }
  });

  test(`${type} preserves selector length and type issues`, () => {
    for (const selector of ['', ' \t\n '])
      expectIssues({ type, selector }, [emptyIssue]);
    expectIssues({ type, selector: 'x'.repeat(301) }, [tooLongIssue]);
    expectIssues({ type, selector: 'password' + 'x'.repeat(293) }, [
      tooLongIssue,
      prohibitedIssue,
    ]);
    for (const selector of [undefined, null, 12, false, [], {}]) {
      const received =
        selector === null
          ? 'null'
          : Array.isArray(selector)
            ? 'array'
            : typeof selector;
      const issue = {
        expected: 'string',
        code: 'invalid_type',
        path: selectorPath,
        message: `Invalid input: expected string, received ${received}`,
      };
      expectIssues({ type, selector }, [
        issue,
        ...(Array.isArray(selector)
          ? [
              {
                origin: 'array',
                code: 'too_small',
                minimum: 1,
                inclusive: true,
                path: selectorPath,
                message: 'Too small: expected array to have >=1 items',
              },
            ]
          : []),
      ]);
      if (selector === undefined) expectIssues({ type }, [issue]);
    }
  });

  test(`${type} preserves strict-object abort behavior`, () => {
    for (const selector of ['reports', 'password']) {
      expectIssues({ type, selector, unexpected: true }, [
        {
          code: 'unrecognized_keys',
          keys: ['unexpected'],
          path: ['steps', 0],
          message: 'Unrecognized key: "unexpected"',
        },
      ]);
    }
  });

  test(`${type} preserves ordered combined timing and selector issues`, () => {
    const timingIssue = {
      origin: 'number',
      code: 'too_small',
      minimum,
      inclusive: true,
      path: ['steps', 0, timing],
      message: `Too small: expected number to be >=${minimum}`,
    };
    const pauseIssue = {
      origin: 'number',
      code: 'too_big',
      maximum: 10000,
      inclusive: true,
      path: ['steps', 0, 'pauseAfterMs'],
      message: 'Too big: expected number to be <=10000',
    };
    expectIssues(
      {
        type,
        selector: 'password',
        [timing]: minimum - 1,
        pauseAfterMs: 10001,
      },
      [timingIssue, pauseIssue, prohibitedIssue],
    );
    expectIssues(
      {
        type,
        selector: 'password' + 'x'.repeat(293),
        [timing]: minimum - 1,
        pauseAfterMs: 10001,
      },
      [tooLongIssue, timingIssue, pauseIssue, prohibitedIssue],
    );
    expectIssues({ type, selector: 'password', [timing]: 'invalid' }, [
      {
        expected: 'number',
        code: 'invalid_type',
        path: ['steps', 0, timing],
        message: 'Invalid input: expected number, received string',
      },
    ]);
    expectIssues({ type, selector: 'password', [timing]: 0.5 }, [
      {
        expected: 'int',
        format: 'safeint',
        code: 'invalid_type',
        path: ['steps', 0, timing],
        message: 'Invalid input: expected int, received number',
      },
    ]);
  });
}
