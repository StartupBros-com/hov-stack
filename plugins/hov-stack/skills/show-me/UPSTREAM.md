# Upstream provenance

Frozen snapshot of https://github.com/humanlayer/skills `plugins/show-me/skills/show-me/SKILL.md`
(commit 3c2629142c5d437428269b1b722b08c0b87f574d, last change to this skill 2026-08-13, MIT —
LICENSE beside this file is the repo's root LICENSE verbatim), cherry-picked 2026-09-02 per the harness-vet evaluation
(memory note explainer-toolbox-vet-2026-09). Announced by Dex Horthy on 2026-08-12
(x.com/dexhorthy/status/2087569590268391897, hlyr.dev/blog/show-me-skill). Deliberately
NOT auto-tracked: five commits in five days, then silence; single author; version 1.0.1
in plugin.json is not a freshness signal. Re-pull manually and re-diff on purpose.

Only this one SKILL.md is vendored. The other four plugins in the same repo were swept
and skipped (two of them ship an unpinned `bunx @humanlayer/cli@latest` GitHub Actions
template with write permissions; see the memory note). The plugin/marketplace route was
not used: plugin-bundled skills cannot be demoted per skill.

Local posture: `disable-model-invocation: true` — invoke by name (`/show-me`), zero
always-on cost. Not in codex-skills.txt; add deliberately if Codex needs it.

Local addition: `adapt-from-upstream.py` applies the three replacements below and
checks that each upstream anchor occurs exactly once. It
regenerates SKILL.md from a fresh upstream copy and exits 1 if an anchor drifted:

1. Frontmatter: `disable-model-invocation: true` added.
2. Mermaid bullet: scoped to surfaces that render it (GitHub PR/issue bodies, Markdown
   viewers, written plans). This harness is a terminal and Mermaid arrives as raw source
   there (open upstream issues anthropics/claude-code#14375, #52517); in chat the text
   forms are preferred.
3. HTML bullet: "support desktop and mobile" dropped; the file is written with the Write
   tool to the path the user names, else `.claude/deliverables/show-me/<YYYY-MM-DD-HHMM>-<description>.html`
   in the repo being worked in (`~/.claude/deliverables/show-me/` outside a repo), then
   shown with `open-deliverable <path>` (the harness-wide
   rule from dotfiles #908, `harness/deliverable-locations.md`; PR #898 briefly used
   `~/reports/` and `wsl-cdp open`, replaced by PR #928). The upstream
   `Bash(open path/to/show-me-{description}.html)` step was removed: `open` here is
   `xdg-open`, Claude Code sets `BROWSER=true` in its sessions, so the command exits 0 and
   shows nothing (verified against the 2.1.258 binary).

Everything else — pseudocode, call tree, component tree, file tree, diff-shaped sketches,
whole-block, and the closing guidance — is byte-identical to upstream.
