import assert from 'node:assert/strict';
import { test } from 'node:test';

import { selectDeclaredCapturePage } from './playwright-capture-runtime';

function page(url: string, closed = false) {
  return {
    isClosed: () => closed,
    url: () => url,
  };
}

test('capture page selection requires one open declared tab', () => {
  const declared = 'https://example.test/home';
  const selected = page(declared);
  assert.equal(
    selectDeclaredCapturePage(
      [page('about:blank'), selected, page(declared, true)],
      (url) => url === declared,
    ),
    selected,
  );
  assert.throws(
    () => selectDeclaredCapturePage([page('about:blank')], () => false),
    /exactly one open browser tab/i,
  );
  assert.throws(
    () =>
      selectDeclaredCapturePage(
        [page(declared), page(declared)],
        (url) => url === declared,
      ),
    /exactly one open browser tab/i,
  );
});
