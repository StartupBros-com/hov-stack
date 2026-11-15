# NOTICE

idle-compact is third-party code, vendored unchanged.

- Source: https://github.com/davidar/claude-idle-compact (the repository root is
  the plugin)
- Pinned commit: `35ec925345acfce26bc0ba260c1f611dceab1148` (vendored 2026-11-15)
- Upstream version: 0.5.0 (plugin.json)
- License: MIT (upstream root `LICENSE`). `LICENSE` beside this file is that
  upstream licence at the pinned commit, byte-for-byte (Git blob
  `0d02c92a6e3630826c2ffac0b2df01dcdc4fbecc`), so the copy carries its notice
  wherever this repository goes.
- Files unchanged from upstream (Git blob IDs at the pinned commit):
  - `.claude-plugin/plugin.json` `60b5a669a0cb499a575e7c55225d44b4c2f545ba`
  - `README.md` `e90a10bc418dce9a4331f564511c9dbbff35b4fc`
  - `hooks/hooks.json` `8c96bf0572ba6d399458f7729d1b79a2ef513101`
  - `hooks/register.ts` `96e802e5796c6656a6c501403c4c497f0f58f5f2`
  - `tests/register.test.ts` `12c67b3103e4cfd1e63b2f27ffb9139f906c44be`
  - `types/index.d.ts` `118882e1a30eb33904af8623c3eefd56b6f61393`
- Files patched locally: none.
- Local additions: this file.

`README.md` is upstream's own and is the place for what the mod does, its
options and its limits. Its install steps (a marketplace install, a
`--plugin-dir` load) are not how this repository loads it; see below.

## How this repository loads it

Through `CLAUDE_CODE_PLUGIN_DIRS` in the tracked `settings.json`, like the
house mods, with one option set under `pluginConfigs`:

- `minTokens` is 100000, against upstream's default of 40000. A conversation
  under the floor is left alone. Compaction swaps the transcript for a summary,
  and below 100,000 tokens the cold re-read it saves is small next to what the
  summary drops.
- `idleMinutes` is left at upstream's default of 50. The tracked settings set
  the main loop's prompt cache to one hour (`promptCacheTtl`), which is the
  lifetime the mod assumes.

What idle means here, from `hooks/register.ts`: the timer starts when a turn of
the main loop ends and is cancelled when the next one starts. A session whose
main loop has finished its turn and is waiting on a subagent, a background
shell or a scheduled wake-up counts as idle and is compacted like any other.
A timer that fires more than ten minutes late (the machine slept) compacts
nothing.

The mod's compaction reaches `hooks/PreCompact/compact-preserve.js` as a manual
compaction with custom instructions, the same shape as a user's
`/compact <focus>`. That hook tells the two apart by the opening words of the
mod's instructions and adds its preserve list to the mod's compaction only.
`hooks/tests/compact-preserve.test.js` reads those words out of
`hooks/register.ts`, so a re-vendor that rewords them fails there.

## How it was checked

Per `harness/third-party-skill-vetting.md`:

- Every file at the pinned commit was read, the five not vendored included.
- `claude plugin validate` on this copy reports hooks `turn.start`,
  `turn.complete`, `session.end` and `session.start`, and calls to `$.clock`,
  `$.session.compact`, `$.session.id`, `$.session.usage`, `$.state` and `$.ui`
  only. It registers none of the events the built-in guard holds back from a
  user's mod (`mods/README.md`, "Before building one"), and makes no file,
  process or network call of its own.
- `claude plugin test` runs upstream's 34 tests against mocks: 34 pass.
- It was loaded in throwaway sessions with no MCP servers. One, with the floor
  lowered, compacted after a minute idle. Another, with the floor lowered and
  `hooks/PreCompact/compact-preserve.js` as changed for this mod wired in,
  started a background shell and ended its turn. The mod compacted it a minute
  later while the shell was still running, the hook added the preserve list to
  that compaction, and the shell's completion started the session's next turn
  afterwards. Upstream's `tests/live.sh` was read, not run.

Not checked: a compaction at the real 50-minute mark, and a compaction while a
subagent is still running (upstream's `tests/live.sh` covers that case; it was
not run here).

## Not vendored

- `.claude-plugin/icon.png` (blob `945ac00a8e69f526273701e2c864c1ad8fffbca8`)
  and `.claude-plugin/marketplace.json`
  (`d040af4488a753025dfa77de0493d0fce5f867c6`): the marketplace listing, unused
  by a folder load. `claude plugin validate` warns that the icon is missing.
- `tests/live.sh` (`393c1cf58030c4e98e227dbb0f4ab28abb64cee3`): starts real
  sessions in tmux; nothing here runs it.
- `.gitignore` (`53d1e9b8fb5f9c3e71b6ad553d898ed0baf21550`) and
  `tsconfig.json` (`8681ec01da419175c87f8c968c6a5af2d2b4e5ae`):
  `mods/.gitignore` already ignores every mod's `tsconfig.json` and the
  engine-generated `.claude-plugin/types/` directory.

To update, re-pin to a specific upstream commit, re-verify the unchanged blobs
above, re-read every changed file, re-run `claude plugin validate`,
`claude plugin test` and `hooks/tests/compact-preserve.test.js`, and record the
new commit here.
