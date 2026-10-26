Experiment 20 result (2026-09-19): MECHANISM PASS, ADAPT is now justified for create-verification-skill.

Protocol: pstack's `create-verification-skill` procedure applied by hand (the generator text is 44 portable lines, no Cursor calls) to a scratch clone, headless Playwright as the driving harness, every claim required to leave an artifact.

- A private site project: ENVIRONMENT BLOCKED, not a mechanism failure. Its dev stack needs production access, which the run rule forbade. Fell back per the /measure framing.
- better-ccflare (`/tmp/hv-pstack/exp20/better-ccflare`): generated `.claude/skills/verify-better-ccflare/` with a feature map of three features (dashboard-overview, theme-toggle, accounts-add-cancel), each with the four fixed sections. Live pass: all three features PASS with screenshots, DOM dumps, per-step `result.json`, and exit-0 run logs under `/tmp/hv-pstack/exp20/evidence/` (30 files, intact after server shutdown, cleanup did not eat the proof).
- The loop corrected itself from evidence: the first feature file asserted a fresh context has no stored theme; the live state file showed `storedTheme=system`; the feature file and the driver assertion were corrected to the observed behavior.
- Friction, all environmental: gitignored build stubs missing from a fresh clone, dashboard assets needing `bun run build:dashboard`, a Playwright viewport too short for a fixed sidebar (fixed at 1280x1100), and several harness guards (Write outside the worktree, shape guard on multi-line sed, dcg on `rm -rf` under $HOME).
- Cost: about 22 minutes wall clock from install to the last run; tokens not instrumented.
- Independent spot-check by the orchestrating session: `theme-toggle/result.json` shows four passing steps with observed `htmlClass` and `storedTheme` values; `01-before.state.txt` and `04-after-reload.state.txt` show `system` then `dark` persisted; the generated SKILL.md is 121 lines.

Next: port `create-verification-skill` and `maintain-verification-skill` into `skills-local/` as user-invocable skills with an `UPSTREAM.md` pin (cursor/plugins `1f84288b`, pstack 0.15.2), Playwright and wsl-cdp named as the harnesses, its own PR with an inward vet. The generated better-ccflare skill and the report are attached to the pstack fixture directory in PR #1210 as the reference example.
