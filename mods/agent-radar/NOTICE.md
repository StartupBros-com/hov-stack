# NOTICE

Agent Radar is third-party code, vendored for personal use with local fixes.

- Source: https://github.com/hamzafer/claude-code-mods, plugin subtree `agent-radar`
- Pinned commit: `0ca6b2abed24b9a1df89bab93595e5eebdc4366d` (first vendored at
  `543abfa670c2242779c9f93cf2ee414a4709a300`; re-pinned 2026-10-03, when upstream's
  only changes to this plugin were its manifest version, author and description
  and the `/radar` command's description)
- Upstream version: 0.1.2 (plugin.json)
- License: MIT (upstream root `LICENSE`, added 2026-10-03 in upstream commit
  `6f7dfa47`; at the first pin no license was present). `LICENSE` beside this
  file is that upstream licence at the pinned commit, byte-for-byte (Git blob
  `eb4c21f9c11134646c3baf6aeccc048f1cba0d73`), so the copy carries its notice
  wherever this repository goes.
- Files unchanged from upstream (Git blob IDs at the pinned commit):
  - `.claude-plugin/plugin.json` `3d1c39a726a991edb943dc08199daa8eff38861d`
  - `hooks/hooks.json` `5a63f649593a5d89af8775a8e3d12db0f0940b12`
  - `tests/agent-radar.test.tsx` `9624e5a76397b0598d4c6997e679a3451a9ad20b`
- Files patched locally (upstream blob IDs for reference; `git diff` against them shows the patch):
  - `hooks/register.tsx` (upstream `d6156486b2ec0c3d7abe08bc6ec805a1cf963615`)
  - `types/index.d.ts` (upstream `a38fe1dab4ce7992723735b9636c15c79bb6140f`)
- Local additions: `hooks/delegates.ts`, `tests/adopt.test.tsx`, `tests/delegates.test.tsx`,
  this file.

## Local fixes

All were found by the terminal review of the enabling PR (dotfiles #1530). The
upstream tests still pass unmodified; `tests/adopt.test.tsx` covers every fix.

### Adopted agents' durations

Upstream `adopt()` gives every agent taken from the engine's list
`startedAt: Date.now()` and no `endedAt`. For an agent that had already
completed or failed, `elapsed()` then falls back to the live clock and the
`/radar` pane shows a duration that grows for as long as the session runs; for
one still running, the pane shows the seconds since adoption as if they were its
runtime. The patch adds an optional `adopted` flag to `RadarAgent`, sets it in
`adopt()`, and routes every displayed duration through `duration()`: an adopted
agent that had already finished reads `duration unknown`; one that is running,
or that finished under the radar's watch, reads `elapsed()` with a trailing `+`,
a lower bound, since its clock started at adoption. Spawned agents are
unaffected. Band membership (`isShown`) is untouched: adopted finished agents
never appeared in the band and still do not.

### `Clear finished` undone by the next `/radar`

Upstream `adopt()` imports every engine agent whose id is not in the displayed
list, so clearing the finished entries (or the 30-entry cap evicting one) made
the next `/radar` import the same completed agents again. The patch adds a
host-held `seen` list of every id the radar has taken in, spawned or adopted;
`adopt()` skips those, so each id is imported once per session. The contract in
`types/index.d.ts` declares the new value.

### Running agents evicted by the cap, and a spawn landing mid-adoption

Two consequences of `seen`, found by the next review round. Upstream capped the
list at 30 entries by position, which could drop an agent that was still
running; with `seen` that agent could never come back, and its later tool calls
and completion would go unrecorded. `keep()` now keeps every running agent and
the 30 newest finished ones. Upstream `adopt()` also deduplicated against a
snapshot taken before the awaited `$.agent.list()`, so a spawn landing during
that call could give one agent two rows; the dedupe now runs inside the `seen`
and `agents` updates, against each value as it is then.

## Local additions

### Delegated work outside the session

Upstream sees only the subagents the engine spawns. Much of the work a session
starts runs as plain processes instead: `codex exec` and `codex review`, a
`/codex:rescue` job, CE's cross-model peer, a Pro review or gate loop, a
headless `claude -p`. `hooks/delegates.ts` and `look()` in `hooks/register.tsx`
give each of those a row in the band and the pane, and a toast when its process
ends.

- **What counts as this session's.** A process the session starts carries its
  id in `CLAUDE_CODE_SESSION_ID`, and so does every process that one starts,
  detached or not; subagents' shells carry the same id (both checked live
  2026-10-07). One look runs `ps x` (this user's processes, command lines cut at
  300 columns), picks the known kinds of work by the program each runs (the first
  word, or the script an interpreter runs), and asks `grep -HcszxF -f -` how
  many of the session's ids each of those environments holds. The ids reach
  grep on its input, one per line, so they are not on its command line. The
  environments never enter the mod: grep prints a file name and a count for
  each, nothing else (`-H` names the file even when grep reads only one: GNU
  grep 3.11 here prints a bare count for a lone file, which went unread, so a
  process judged alone was never listed). Each process is judged once, keyed by pid and start time, so a
  reused pid is judged again. One grep could not read (gone, or not readable)
  gets no verdict and is asked about again at the next look, as is every one
  when grep fails. Those judgments are the module's and start over when it
  reloads; the rows are the host's, and a process found again is matched to its
  row by pid and start (to within 5 s), so a reload neither ends a running row
  nor adds a second one.
  Every id the conversation has had in this process is kept, the ending one
  recorded as `/clear` ends it (`session.end`), so work started before a
  `/clear` stays in view. The ids are kept twice: by the host (`sessions` in
  `types/index.d.ts`), which a reload keeps, and by the module, which keeps them
  whatever a `/clear` does to the host's values (not checked). A resume puts
  another conversation in the session's place, in the same process and with no
  `session.start`: the radar then starts over, dropping the ids, the
  judgments and the delegated rows (no toast; subagent rows stay), so the work
  of the conversation left is no longer listed and the resumed one's is judged
  again under its own id. It starts over again at the first look that sees the
  new id, as a look in flight at the resume, or one made before the new id
  lands, takes the old conversation's work back.
- **What a row shows.** A label from the program and a PR number where the
  command gives one (`Pro review #1660`, `Codex exec`), the elapsed time, and
  the last part of the directory it runs in. Never any of its command text: a
  prompt or a path in an argument stays out of the band. One row per chain: a
  Pro review's own Codex run is not listed again under it.
- **When it looks.** Every 5 s while something draws the session
  (`$.session.surfaces()` non-empty; a read that fails counts as drawn), and
  whenever `/radar` opens the pane. One look runs at a time: a `/radar` during
  one waits for it and shows the rows as that look left them (as they were, if
  it failed), and looks itself only when that one stopped short because nothing
  draws the session, or when a resume landed during it and no look has seen the
  resumed conversation's id yet. A look is one `ps` (40 to 60 KB, and 40 to 150 ms
  measured on this host's 300 to 380 processes) plus one `grep` only when a new
  process of a known kind has appeared or one grep could not read still runs; a
  process younger than 3 s is left for the next look, so a quick status call
  never flashes a row.
- **How a row ends.** When its process is gone, the row reads `ended` (■) with a
  toast. Gone means no process with its pid and start is listed; a process
  still listed keeps its row even with no verdict (after a reload, or when its
  environment turns unreadable). That is all the radar knows: whether the work
  succeeded is in its own output. A look that fails (`ps` or grep errors or is
  cut short, `ps` takes over 4 s, too long to read starts by, or either is still
  running at 4 s, when the host kills it) ends nothing, so `/radar` waits on a
  look about 8 s at most, plus the surfaces read of a timer's look it arrives
  during, which has no timeout of its own. Work that ends while nothing draws
  the session is marked at the next look, with the time it was last seen.
- **Limits.** Linux only: it relies on procps `ps` (`etimes`, `--cols`) and
  `/proc/<pid>/environ`; elsewhere the look fails and no delegated work shows.
  Work started outside the session's environment, such as a PR owner's loop run
  through `systemd-run`, carries no session id and is not listed. Past column
  300 of a command line, a `--pr` number is lost (the label has no number) and
  so is a `-p` (that headless Claude is not listed). Whether a background
  session reports a surface while a client is
  attached to it was not checked; when it does not, only `/radar` looks there.
  The upstream manifest's description, kept unchanged above, still names only
  subagents.

Not vendored: upstream's `tsconfig.json` (blob `8681ec01da419175c87f8c968c6a5af2d2b4e5ae`),
which only extends the engine-generated `.claude-plugin/types/tsconfig.json`.
This repository ignores every mod's `tsconfig.json` (`mods/.gitignore`),
and the generated `.claude-plugin/types/` directory is written by the engine on
first load, so neither is tracked here. To update, re-pin to a specific upstream
commit, re-verify the unchanged blobs above, re-apply or drop each local fix as
upstream fixes it, re-run `claude plugin validate` and `claude plugin test`,
and record the new commit here.
