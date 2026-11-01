# token-eater 🍔

Got AI credits about to expire? token-eater puts them to work.

**Just run `/token-eater`.** It tidies up your code in an isolated copy of your project, double-checks nothing broke, and opens a **draft pull request** for you to review. It **never merges** — you decide.

```
/token-eater
```

## Install

Two steps, from inside Claude Code:

```
/plugin marketplace add StartupBros-com/hov-stack
/plugin install token-eater@hov
```

Then type `/token-eater` in any project you want cleaned up.

The first time, it asks a couple of plain questions (what to clean up, which credits to spend) and remembers them — after that, `/token-eater` just runs. No flags to learn.

## How it works

1. **Run `/token-eater`.** First time on a project, pick what to do and which credits from a short menu; it saves your choices so it never asks again.
2. **token-eater does the cleanup** in an isolated copy of your project and checks the result — with your project's own tests/type-check when it has them, or an AI code review when it doesn't (clearly labeled either way).
3. **You get a draft PR** with a plain-language summary of what changed. Review it — or have AI review it (`/ce-code-review`) — before merging.

> Power users: you can still pass `/token-eater grok de-monolithize`, `--gate`, `--install-deps`, etc. — see `SKILL.md`. Everyone else can ignore that.

## Safety

- **Informed consent comes first.** Before any shell command runs against a project, token-eater explains that it will execute that project's tests, builds, and lint commands. With a separate opt-in, it can also run dependency lifecycle scripts. Accept only for repositories you trust.
- Consent is saved outside the project, keyed by its canonical filesystem path and the current caveat version. The same version does not ask again. A changed caveat asks again. A repository cannot bypass the prompt by committing a token-eater config or consent file.
- **The isolated worktree is not a security sandbox.** It protects your current checkout and uncommitted work, but project code can still access files, credentials, and the network available to your user account. OS sandboxing remains future hardening.
- **Prefers proof, degrades honestly.** When your project has tests/type-check, it runs them and re-verifies the result independently. When it doesn't, it still helps but the PR is clearly labeled "AI-reviewed only, please read before merging."
- Every run happens in an isolated copy of your project. Your branch and uncommitted work are never touched.
- Never merges, never marks a PR ready, never auto-pushes to main.
- Only spends the credits you chose.

## Status

🧪 Beta. Run it manually for now (`disable-model-invocation: true` — a human must type `/token-eater`).

## For builders

token-eater is a Claude Code skill. The orchestrator is `SKILL.md`; the playbooks are in `references/`; the provider registry is `adapters.yaml`. (The `docs/` design notes predate the simplification — `SKILL.md` and `references/` are the source of truth.)

## Releases and HoVStack

This plugin lives at `plugins/token-eater/` in [StartupBros-com/hov-stack](https://github.com/StartupBros-com/hov-stack/tree/main/plugins/token-eater). A `VERSION` bump merged to hov-stack main tags `token-eater--v<version>`, and hov-stack's release workflow drafts the release once the plugin's CI passes. The marketplace entry is then repinned, the release is published, and the release train announces it. See the [plugin release recipe](https://github.com/StartupBros-com/hov-stack/blob/main/docs/release/plugin-release-recipe.md).
