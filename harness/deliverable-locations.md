# Deliverable locations

Where a skill puts a file the operator is meant to read (an HTML explainer, a report, a
prototype, a deck, a chart), and how the operator gets to see it. One rule for the whole
skill library, so nothing lands in `~`, in a repo root, or in a folder invented per skill.
Motivating defect (dotfiles #908, 2026-09-02): fourteen stray HTML files across `~`,
`~/discord-exports/`, `~/reports/`, and four untracked `docs/ideation/*.html` in live repos,
every one an agent defaulting to the working directory or `$HOME` because the skill named
no home; plus two skills that ended with `open <file>`, which under Claude Code exits 0 and
shows nothing (the session env carries `BROWSER=true`).

## The rule, as a skill states it

> Write the file under `.claude/deliverables/<skill>/<YYYY-MM-DD-HHMM>-<slug>.<ext>` in the
> repo you are working in, then run `open-deliverable <path>` and report the path.

That is the whole per-skill text. Everything below is the reasoning and the edge cases;
skills do not restate it.

## Tiers

| Tier | Path | Tracked | Deletion | Consumer |
|---|---|---|---|---|
| Ephemeral | `/tmp/<unique-dir>/`, or `$CLAUDE_JOB_DIR/tmp` in a background job | no | dies with the session or job | the agent itself |
| Reviewable | `<repo>/.claude/deliverables/<skill>/<date>-<slug>.<ext>` | no (`~/.gitignore_global`, beside `.claude/scratch/`) | dies with the worktree; in a main checkout, delete when read | the operator, this week |
| External workspace | `<project>__<skill>_workspace/` beside the repo; de-monolithize is the one current example (`<project>__demonolith_workspace/`), and a new skill that emits a sibling bundle uses the same shape | no, outside the repo | `wt-sweep.sh` warns past 14 days, same threshold as an abandoned worktree; the skill that made it says when it is done | the operator, until the bundle is consumed |
| Durable | `docs/<sub>/` (plans, solutions, reality-checks), `design/` (design-rails) | yes | normal repo governance | anyone reading the repo |

Ceremony Test answers for the one new tier, Reviewable: consumer = the operator in the
session that produced it; gate = the skill reports the path in the same turn and opens it;
defect = the fourteen strays above; deletion = the worktree sweep, or the operator deleting a
read file in a main checkout. `~/reports/` is retired as a target: nothing new goes there.

Outside any repo (a session started in `~`, or a skill like memory-dream that works on the
harness itself), the Reviewable tier is `~/.claude/deliverables/<skill>/`: the same shape, in
the config directory the harness already owns, never loose in `~`.

Choosing a tier: if the file exists so the operator can look at it once, it is Reviewable.
If it exists so a future reader of the repo finds it, it is Durable and goes through a PR.
If only the agent reads it, it is Ephemeral. A skill that emits a whole sibling directory
of many files is the External workspace case.

Under a worktree the Reviewable tier is per worktree, which is the point: two sessions never
write over each other, and `wt-sweep` removes the lot with the worktree. Background jobs
write there normally (verified 2026-09-03 from a background session: a Write to
`<worktree>/.claude/deliverables/...` was allowed). Subagents and workflow agents inherit the
same rule through this doc. Codex has filesystem access to the same path (no restriction
found in `~/.codex/config.toml` or `~/.codex/AGENTS.md`), but AGENTS.md does not carry this
rule, so a Codex session follows it only when told.

## Viewer

`open-deliverable <path-or-url>` (dotfiles `bin/`, linked into `~/.local/bin` by
`sync.sh`) opens the file in the operator's real browser on whatever host this is, and prints
what it did. `--print` resolves without launching. `DELIVERABLE_BROWSER=<exe or app>` forces
a browser.

| Host | Route | Verified |
|---|---|---|
| WSL2 | Brave's own executable under the Windows user's AppData (or Program Files), launched detached with `file://wsl.localhost/<distro>/<abs path>`; without Brave, `cmd.exe /c start` on the Windows path (the default browser, Edge on this host) | 2026-09-03: window titled with the test page in the operator's daily Brave |
| macOS | `open -a "Brave Browser"` when installed, else `open` | untested |
| Linux desktop | `brave-browser`, `brave`, `google-chrome`, `chromium`, `chromium-browser`, or `firefox` on PATH, else `xdg-open` with `BROWSER` unset | untested |
| Headless or SSH | prints the path and URL, exits 3; the skill reports the path | by design |

What not to do, and why: never bare `open` or `xdg-open` (no-ops under `BROWSER=true`); never
`cmd.exe start`, `explorer.exe` or PowerShell `Start-Process` on a file when Brave is wanted
(they go to the Windows default browser, Edge here); never lean on `wsl-cdp open` for
deliverables (it is attached to a separate agent instance of Brave, not the operator's, and
exists only on WSL); never the Claude Code Artifact tool for a local deliverable (it publishes
to a claude.ai URL owned by the CLI's `/login` account and stores nothing locally). The tool
was disabled here on 2026-07-09 (`CLAUDE_CODE_DISABLE_ARTIFACT=1`) and re-enabled on
2026-09-25 for Claude Design and Slides decks; `CLAUDE.md` limits it to artifacts the
operator asks for and decks, designs or docs meant for other people.

## Deliberately not built

No PreToolUse hook rewriting Write destinations. Hooks do already match the Write tool
(`settings-guard.js` guards settings files, `auto-format.js` formats after edits), so the
interception point exists; what does not exist is a way to tell a deliverable from
`playwright-report/index.html` or an `opengraph-image` output by path or extension, and a
wrong guess would corrupt real in-repo files. The prose rule is the honest lever until a
deliverable is distinguishable by something better than a guess. No promotion or
generator CLI. No sweep timer for the Reviewable tier (it is gitignored and dies with the
worktree). No mass edit of the fifty-odd skills that merely mention HTML: they inherit the
rule from the always-on sentence in CLAUDE.md and get fixed when they actually drift.

## Wired to the opener in the same PR

- `/eli5` and `/show-me`: landing path plus `open-deliverable`.
- memory-dream: keeps `preview.html` in its patch-set directory (`~/.claude/logs/memory-dream/passes/<ts>/`,
  a body-bearing file a `harness-weekly.sh` run prunes after 90 days; its timer retired 2026-10-17) and opens it with `open-deliverable`
  through the plugin's `preview_opener` key in `memory-dream.json`, never a Windows-home
  copy plus PowerShell `Start-Process`.
- design-rails' `decide.mjs --open`: `claude-env.sh` exports
  `DESIGN_RAILS_OPENER=open-deliverable` and Claude Code sources that file before each Bash
  call, so the plugin's engine tries the opener before its own launchers.
- browser-console-setup: hands a URL to `open-deliverable` instead of a hard-coded
  `/mnt/c/Users/user/...brave.exe` path.

## Known exceptions, named

- compound-engineering's `ce-ideate`/`ce-brainstorm` write `docs/ideation/<date>-<slug>.html`
  untracked; that text lives in plugin cache (fifteen copies, auto-updated), so it is not
  patched here; an upstream issue asks for the change.
- `ce-prototype` serves a route from `tmp/compound-engineering-<uid>/`; a served app, not a
  file, exempt.
- `design-rails` writes `design/DESIGN.md` by its own documented rule; exempt.
- `verify-review` writes `<artifact_dir>/verify-review.md` only when the user accepts; its
  own gate, compliant.
- Images (og-share-images, gh-og-share-images, wsl-cdp screenshots) render through the Read
  tool and need no viewer; they still land in the Reviewable tier when they are deliverables.

## The measurement

Rerun the 2026-09-02 scan in thirty days: `find ~ -maxdepth 3 -name '*.html' -mtime -30` plus
an untracked-file pass over `~/SITES/*` for HTML and report files outside
`.claude/deliverables/`, `docs/`, or a named external workspace. Baseline fourteen.
Success is zero net-new strays and no writes to `~/reports/` in eli5 or show-me transcripts.
