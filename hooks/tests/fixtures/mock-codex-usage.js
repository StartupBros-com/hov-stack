'use strict';
// Preload (NODE_OPTIONS=--require) for the codex-quota-guard golden corpus: answers the chatgpt.com
// endpoints the guard queries without touching the network, so an EXHAUSTED window can be driven end
// to end through the registered command. MOCK_CODEX_USAGE picks the usage body:
//   exhausted  explicit allowed:false, no catalog (the guard denies)
//   healthy    allowed:true (the guard passes the command through)
//   unknown    an unfamiliar shape (uncertain: fails open)
//   spark      the field-faithful fixture where the main window is out and Spark is open, with the
//              fixture catalog (the guard REWRITES the command to `-m <slug>`)
//   all-out    the fixture where every account window is out (the guard denies with a receipt)
const fs = require('node:fs');
const path = require('node:path');
const https = require('node:https');
const { EventEmitter } = require('node:events');

const FIX = path.join(__dirname, 'codex');
const fixture = (name) => JSON.parse(fs.readFileSync(path.join(FIX, name), 'utf8'));
const BODIES = {
  exhausted: () => ({ rate_limit: { allowed: false, limit_reached: true } }),
  healthy: () => ({ rate_limit: { allowed: true, limit_reached: false } }),
  unknown: () => ({ plan_type: 'plus' }),
  spark: () => fixture('usage-exhausted-spark-open.json'),
  'all-out': () => fixture('usage-exhausted-all.json'),
};

https.request = (options, callback) => {
  const req = new EventEmitter();
  req.destroy = () => {};
  req.end = () => {
    const res = new EventEmitter();
    const p = String(options.path);
    const isUsage = /\/(?:wham|codex)\/usage/.test(p);
    const isCatalog = /\/codex\/models/.test(p);
    const mode = process.env.MOCK_CODEX_USAGE || 'exhausted';
    const withCatalog = mode === 'spark' || mode === 'all-out';
    res.statusCode = isUsage || (isCatalog && withCatalog) ? 200 : 404;
    setImmediate(() => {
      callback(res);
      if (isUsage) res.emit('data', JSON.stringify(BODIES[mode]()));
      else if (isCatalog && withCatalog) res.emit('data', JSON.stringify(fixture('catalog.json')));
      res.emit('end');
    });
  };
  return req;
};
