# Hook test harness

Fixture-driven regression tests for the Claude Code hooks in `~/.claude/hooks/`.
Zero dependencies — uses Node's built-in `node:test` runner (Node ≥ 18; this repo
runs v24). Exists because the hooks previously had **no tests**, and a dangling
`require()` silently killed auto-format's fallback for weeks before anyone noticed
(see PR #17). This suite makes hook regressions fail loudly at commit time.

## Run

```bash
bash hooks/tests/run.sh          # from the repo root
# or directly:
node --test hooks/tests/*.test.js
```

Exits non-zero if any test fails. CI runs this exact suite through
`.github/workflows/ci.yml` → "Hook tests" → `bash hooks/tests/run.sh`.

## How it works

- **Black-box** where it counts: `spawn('node', <hook>)`, feed a JSON payload on
  stdin, assert on `{exit code, stdout, stderr}` — exactly how Claude Code invokes
  hooks. Helpers live in `lib/harness.js`; throwaway hooks the dispatcher loads
  live in `fixtures/*.hook.js` (named `.hook.js` so the runner never treats them
  as tests).
- **Hermetic**: every behavior-changing env var (`HOOK_PROFILE`, `HOOK_DISABLED`,
  `CLAUDE_LOOP_GUARD`, `ALLOW_*`, `CLAUDE_PLUGIN_ROOT`, …) is neutralized per spawn.
  Hooks that read `$HOME` (loop-guard state, active Codex auth, package-manager
  global config) are redirected to a temp `$HOME` (`os.homedir()` honors it).
- Pure-logic libs (`hook-flags`, `resolve-formatter`, `package-manager`) are
  `require()`d in-process for speed.

## Coverage

| Hook / module | Tested |
|---|---|
| `run-with-flags.js` (dispatcher) | **async run() is awaited** ⭐, sync run(), throwing run() → catch+passthrough, profile/`HOOK_DISABLED` gating, missing script, path-traversal rejection, no-args passthrough |
| `PreToolUse/git-guard.js` | blocks `git add .`/`-A`/`-- .`/`./` (env-stripped, `-C`-aware) but allows a specific `./path`; `push --force`/`-fu`, `reset --hard`, `clean -f`, `branch -D`, `stash drop`; allows specific `add` + `--force-with-lease`; env-prefix + `git -C` smuggle blocked; commit-on-main blocked / feature-branch allowed; `ALLOW_DESTRUCTIVE_GIT` escape; malformed-input passthrough |
| `PreToolUse/grep-cost-guard.js` | linear, non-executing detection of high-cost paired repeated single-character spans across grep-family commands; exact/bounded/open-ended ERE/BRE forms, `-e`/`--regexp`, opaque `-f` denial, pipelines, explicit wrapper/command positions, shell `-c`, `find -exec`, and path basenames; fixed-string, below-threshold, one-span, `ast-grep`, similarly named, malformed/non-Bash pass-through |
| `PreToolUse/loop-guard.js` | no-op unless opted in; blocks on call-count fence; blocks on wall-clock budget |
| `PreToolUse/codex-quota-guard.js` | non-spend/recovery commands bypass the query; explicit `allowed:false` / `limit_reached:true` deny; auth/network/schema uncertainty fails open; **lone 604800s primary at 100% with `allowed:true` allows** (incident planted negative); malformed passthrough; **#991 rewrite-instead-of-deny**: exhausted account + separately metered model open → `updatedInput` carries `-m` (other `tool_input` fields survive), everything out → deny with the banked-reset line iff `available_count > 0`, healthy → byte-identical and no catalog fetch, `-m` for an open model untouched, `xhigh` clamped to `high` on a capped fallback, `bash -c` payload rewritten, unrewritable wrapper denies naming the open lane, API key never echoed, blocked verdict without a usage body denies as before |
| `lib/codex-model-resolver.js` | explicit-only rate-limit state; per-model meter (separately metered vs account); candidates drop `visibility:hide`, follow `upgrade`, sort by `priority`; **PLANTED NEGATIVE: an unknown top slug beats a known slug that upgrades to it**; effort clamp/default; selection on exhausted/healthy/requested/unknown; every `-m`/`--model=`/`-c model=`/`--config=…` spelling parsed and rewritten in place; heredoc bodies never scanned; opaque `$…` flags and unsafe payloads refuse; account prefix + API config; `resolve()` rungs (active → verified caam profile → API key → exhausted), uncertain/exhausted profiles skipped and listed, hook-budget cap reported, uncertainty never acted on; catalog cache freshness with Codex's file never written; caam isolated profiles listed, vault backups not |
| `lib/codex-model-resolver.js` ccflare pool rung (`codex-ccflare-pool.test.js`) | pools ranked by live catalog priority via the `codex-pool-<tier>` suffix, unknown tiers dropped, only codex accounts count; settings-derived ccflare config never invents a key; unconfigured/unreachable/throwing pool lookups skip the rung; exhausted account + open pool → `-m <pool profile> -c model_provider=better_ccflare` ahead of Spark, effort clamped to the pool model, an existing provider flag replaced; pool closed → Spark, pool closed + Spark out → exhausted with pool state in the receipt; a requested open model and a healthy account beat the pool; `usesCustomProvider` via per-call flag, wrapped flag, or top-level config key (a provider table alone is not a selection); guard passes a custom-provider run through with no quota query and rewrites to the pool on exhaustion; codex-pick fixture parity |
| `bin/codex-pick` (black-box spawn) | `--version`/`--help` resolve nothing; `--json` receipt equals the guard's on the same fixtures (Spark-open, everything-out, healthy, requested-available, clamped effort, planted negative); `--exec` runs the rewritten argv against a fake `codex` and propagates its exit code, exits 3 without running when exhausted, runs unchanged when healthy; non-codex command after `--` exits 2 |
| `statusline-stack/local-statusline.mjs` | requested model stays visible, and a differing main-chain reply renders as `last reply <model>` with its age; unavailable/malformed localhost provenance is silent; short cache is reused across renderer processes; the prompt-cache segment covers warm countdown, cold re-cache cost, stale frames and miss causes; quota `reset due` and weekday clocks; private mode; control and bidi stripping; every line fits 108 columns; linked-worktree naming |
| `Stop/verify-on-stop.js` | **`stop_hook_active` short-circuit (loop safety)** ⭐; untrusted-dir `.claude/verify.sh` NOT executed (F3); env opt-in + failing verify → block; trusted-root + passing verify → allow; malformed passthrough; **v2 change gating**: docs-only session skips, old-mtime parked dirt skips, fresh code change verifies with `CI=1`, failing typecheck blocks, missing node_modules → environmental block (verify never runs), session commit on clean tree verifies, no-transcript conservative fallback verifies, explicit `CLAUDE_VERIFY_ON_STOP=1` bypasses gating |
| `PostToolUse/auto-format.js` | non-JS passthrough; malformed-JSON passthrough; JS-with-no-formatter passthrough |
| `lib/resolve-formatter.js` + `lib/package-manager.js` | **package-manager loads (no missing-module throw)** ⭐, **fallback resolves without throwing** ⭐, biome/prettier detection, local-bin preference, PM detection (default/lockfile/env) |
| `lib/hook-flags.js` | profile allow/deny, `HOOK_DISABLED` override, empty-id, invalid-profile fallback, `parseProfiles` |
| `lib/workspace-trust.js` | the home directory (realpath key; an existing entry keeps its fields, a missing one gets the default shape; a home missing on disk adds no key) and every `.git`-holding child of `~/SITES` missing trust are seeded (realpath keys, existing fields kept, new entries in Claude Code's default shape) while a plain directory, a hidden repository, a file and an outside entry are not; a linked worktree (real `git worktree add`) is keyed by its main repository, a `.git` file that is not one by itself; on-disk format and mode match Claude Code's write, no temp or lock left; nothing missing takes no lock and rewrites nothing; a held lock defers the write and survives, a released one is taken; a save landing under the lock is built on, not overwritten; a lock lost before the rename aborts it, target and no temp left; the lock is ours only while the same directory and under half the stale age; a `.git` or `commondir` FIFO never blocks the scan; no config is never created; unreadable config is never rewritten; a symlinked config is written through; config-path resolution; SessionStart runs it silently |
| `SessionStart/launchpad-advisory.js` | non-git silent; healthy checkout silent; **v2 heal**: parked-with-pushed-tip self-heals to default, detached-with-pushed-tip self-heals, recent-unpushed declines + advisory, tracked-dirt declines + advisory, worktree never healed (rebase phrasing only); up-to-date worktree silent; malformed input silent exit 0 |

⭐ = the two regressions from PR #17. Both were verified by negative control
(re-introduce the bug → the marked test fails; restore → green), so they are not
vacuous.

## Not covered yet (deliberately — no silent caps)

- `plugin-auto-update.js` (network / SessionStart) — resists black-box testing
  without a live session.

## Adding a test

1. Drop a payload-driven assertion in `<hook>.test.js`:
   ```js
   const { runHook, decisionOf, assertQuietPassThrough } = require('./lib/harness');
   test('blocks X', async () => {
     assert.strictEqual(decisionOf(await runHook('PreToolUse/x.js', { tool_input: { command: 'x' } })), 'block');
   });
   ```
2. For **allow / pass-through** cases spawned as a subprocess use
   `assertQuietPassThrough(res)` — NOT `decisionOf(res) === null`. A crashed hook
   also emits no `decision`, so the `=== null` check would pass green on a broken
   hook; `assertQuietPassThrough` asserts exit 0 **and** empty stdout (every
   standalone entry now routes through `writeHookOutput`, which writes nothing on
   a no-op — issue #1339), so a crash (non-empty stderr echo, wrong exit code)
   still fails loudly. Reserve `decisionOf(...) === 'block'` for block cases (a
   crash yields `null ≠ 'block'`). `assertPassThrough(res, payload)` (stdout ===
   raw input) still exists for asserting that `run()` itself — called in-process,
   not through the spawned entry point — returns its input unchanged.
3. For dispatcher behavior use `runViaFlags(hookId, relScript, profilesCsv, payload)`.
4. For `$HOME`-touching hooks pass `{ env: { HOME: mkTmp(), USERPROFILE: <same> } }`
   (spawned hooks), or wrap in-process calls in a temp-`$HOME` save/restore.

## Related follow-ups (backlog)

- **Fail-loud logging** — a shared `unhandledRejection` guard + JSONL breadcrumb so
  a *silently* broken hook (crash, missing dep) is as visible as a bad decision.
  This suite catches it at commit time; logging catches it in production.
- **Iteration-cap** loop-safety for `verify-on-stop` beyond `stop_hook_active` (now
  asserted): the flag alone cannot cover an unsatisfiable async-wait; pair a hard
  cap with loop-guard as defense-in-depth.
