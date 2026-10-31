# Delivery plan — getting token-eater to House of Vibe members

Decisions (2026-06-29): ship token-eater as a **Claude Code plugin** in a **new HoV-branded
marketplace**, and **require the compound-engineering plugin** (for the genuine `ce-*` reviewer
personas). HoV members live in Claude Code, so the native plugin install is the right path — one
command, native versioning/updates, no `curl|bash`.

## Member install (target experience)

```
/plugin marketplace add StartupBros-com/hov-stack     # one time
/plugin install token-eater@hov                              # + compound-engineering (companion)
/token-eater                                                 # interactive preflight, then just runs
```

## Build steps

1. ✅ **Plugin manifest** — `.claude-plugin/plugin.json`. Validates clean.
2. ✅ **Plugin skill layout** — `SKILL.md` + `scripts/` + `references/` + `skills-catalog.yaml` +
   `adapters.yaml` moved under `skills/token-eater/` (history-preserving `git mv`). `grok plugin validate`
   now reports **`1 skill dir(s)`** (was 0). Path resolution verified at the new location: scripts'
   `$ROOT` (dir above `scripts/`) still finds `adapters.yaml`/`skills-catalog.yaml`; `detect-adapters`,
   `detect-skills`, `run-gate --list` all work; `bash -n` clean. The dev symlink
   `~/.claude/skills/token-eater` was re-pointed to `skills/token-eater/`. Repo-root docs/`.claude-plugin/`
   stay at root. **Still TODO: a real `/plugin install` (from the git source) → `/token-eater` round-trip
   on a clean machine (ideally the mac)** — structural validation passed; the live install isn't tested
   here to avoid colliding with the dev symlink.
3. ✅ **HoV marketplace repo** — created at `StartupBros-com/hov-marketplace` (private/WIP until launch),
   `.claude-plugin/marketplace.json` (name `hov`) lists `token-eater` (source = this repo, pinned to
   main). **Live-validated:** `claude plugin marketplace add StartupBros-com/hov-marketplace` clones +
   validates + "Successfully added marketplace: hov". `compound-engineering` is documented in the
   marketplace README as the required companion (install from `every-marketplace`) + enforced by the
   SKILL preflight — NOT baked in as a fragile EveryInc source (left as a refinement if a one-add flow
   is wanted). **Flip the repo to public at launch.** Bump the pinned token-eater sha on each release.
4. **Dependency enforcement** (plugin manifests have NO hard-dependency field — verified). Two layers:
   - **Member-facing preflight** (SKILL.md): on first run, Claude checks whether the compound-engineering
     personas are available; if not, plain-language "I need the compound-engineering plugin for the code
     reviewers — install it?" → `/plugin install compound-engineering@hov` → continue.
   - **Engine fallback** (already shipped): if the personas aren't found, `run-session.sh` degrades to
     generic-lens reviewers rather than failing — the safety net.
5. **HoV course / vault content** in the House of Vibe app content directory — a short lesson:
   "Put your expiring AI credits to work" → the two install commands + `/token-eater` + how to review
   the draft PR. Plain language, screenshots, no flags.

## Open / confirm before public release

- **License** — manifest defaults to `MIT`; confirm or change (no `LICENSE` file yet).
- **End-to-end install test** — `/plugin install` from the git source on a clean machine (ideally the
  mac), then `/token-eater` runs the preflight. (Pairs with the cross-platform checklist item.)
- **Repo home** — token-eater was first developed in a standalone repository under a personal
  GitHub account (redirecting to `StartupBros-com`); confirm the canonical owner before publishing
  the marketplace source URL. (It now lives in `StartupBros-com/hov-stack`.)
- The 3 safety items + cross-platform are already DONE (see DISTRIBUTION-READINESS.md); the
  observability (per-run spend on grok) gap remains a known limitation to surface in the course copy.
