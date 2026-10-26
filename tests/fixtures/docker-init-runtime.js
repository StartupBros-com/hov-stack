'use strict';

const fs = require('fs');
const http = require('http');
const { spawn } = require('child_process');

const [fixtureClass, mode, cyclesText, delayText, probe] = process.argv.slice(1);
const classes = {
  studio: {
    port: 3000,
    path: '/api/platform/profile',
  },
  pg_meta: {
    port: 8080,
    path: '/health',
  },
};
const fixture = classes[fixtureClass];
const cycles = Number(cyclesText);
const responseDelayMs = Number(delayText);

if (fixtureClass === 'process_snapshot') {
  const rows = processRows();
  const byPid = new Map(rows.map((row) => [row.pid, row]));
  const zombies = rows.filter((row) => row.state === 'Z');
  const nestedLive = zombies.filter((row) => {
    const parent = byPid.get(row.ppid);
    return row.ppid !== 1 && parent && parent.state !== 'Z';
  });
  const pidOne = byPid.get(1);
  process.stdout.write(
    [
      pidOne ? pidOne.comm : 'MISSING',
      zombies.length,
      zombies.filter((row) => row.ppid === 1).length,
      nestedLive.length,
    ].join('\t') + '\n',
  );
  process.exit(0);
}

if (!fixture || !['orphans', 'direct'].includes(mode)) {
  throw new Error('expected a known fixture class and mode');
}
if (!probe || probe.includes('\n')) {
  throw new Error('expected one healthcheck probe command');
}
if (!Number.isInteger(cycles) || cycles < 1 || cycles > 100) {
  throw new Error('cycles must be an integer from 1 through 100');
}
if (!Number.isInteger(responseDelayMs) || responseDelayMs < 100 || responseDelayMs > 1000) {
  throw new Error('response delay must be an integer from 100 through 1000 milliseconds');
}

const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitFor(predicate, timeoutMs, description) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await pause(25);
  }
  throw new Error(`timed out waiting for ${description}`);
}

function waitForExit(child) {
  return new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (code === 0 && signal === null) resolve();
      else reject(new Error(`intermediate shell exited code=${code} signal=${signal}`));
    });
  });
}

function processRows() {
  const rows = [];
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      const match = stat.match(/^(\d+) \((.*)\) ([A-Z]) (\d+) /);
      if (match) {
        rows.push({
          pid: Number(match[1]),
          comm: match[2],
          state: match[3],
          ppid: Number(match[4]),
        });
      }
    } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'ESRCH') throw error;
    }
  }
  return rows;
}

let completedRequests = 0;
const server = http.createServer((request, response) => {
  if (request.method !== 'GET' || request.url !== fixture.path) {
    response.writeHead(404).end();
    return;
  }
  setTimeout(() => {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end('{"ok":true}');
    completedRequests += 1;
  }, responseDelayMs);
});

async function exerciseOrphans() {
  for (let cycle = 1; cycle <= cycles; cycle += 1) {
    // The shell is the deliberately short-lived intermediate parent. Its exact
    // image healthcheck probe continues in the background, is adopted by PID 1,
    // and exits only after the local delayed response arrives.
    const shell = spawn('/bin/sh', ['-c', `${probe} >/dev/null 2>&1 & exit 0`], {
      stdio: 'ignore',
    });
    await waitForExit(shell);
    await waitFor(
      () => completedRequests >= cycle,
      10000,
      `healthcheck probe response ${cycle}/${cycles}`,
    );
  }
  process.stdout.write(
    `DOCKER_INIT_RUNTIME_COMPLETE class=${fixtureClass} mode=orphans attempted=${cycles} completed=${completedRequests}\n`,
  );
}

async function exerciseDirectChildCounterexample() {
  // The shell forks an exiting Node child and then execs a living Node process.
  // That living process did not create the child and does not wait for it, so
  // the zombie remains its direct child and is outside PID 1's reaping power.
  const command =
    'node --eval="setTimeout(() => process.exit(0), 1000)" & ' +
    'exec node --eval="setInterval(() => {}, 1000)"';
  const parent = spawn('/bin/sh', ['-c', command], { stdio: 'ignore' });
  parent.once('error', (error) => {
    throw error;
  });
  await waitFor(() => {
    const rows = processRows();
    return rows.some((row) => row.state === 'Z' && row.ppid === parent.pid);
  }, 10000, 'direct-child zombie counterexample');
  process.stdout.write(
    `DOCKER_INIT_RUNTIME_COMPLETE class=${fixtureClass} mode=direct parent_pid=${parent.pid}\n`,
  );
}

server.once('error', (error) => {
  process.stderr.write(`DOCKER_INIT_RUNTIME_ERROR ${error.stack || error.message}\n`);
  process.exit(1);
});

server.listen(fixture.port, '127.0.0.1', () => {
  process.stdout.write(
    `DOCKER_INIT_RUNTIME_READY class=${fixtureClass} mode=${mode} port=${fixture.port}\n`,
  );
  const work = mode === 'orphans' ? exerciseOrphans() : exerciseDirectChildCounterexample();
  work.catch((error) => {
    process.stderr.write(`DOCKER_INIT_RUNTIME_ERROR ${error.stack || error.message}\n`);
    process.exit(1);
  });
});
