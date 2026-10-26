# Break-glass install — canonical harness lives in WSL

This Windows-side Claude Code is a minimal fallback for when WSL is unavailable.
Do NOT add skills, agents, hooks, commands, model pins, or rules here — they drift.
Canonical config: WSL `~/.claude/` (`\\wsl.localhost\Ubuntu\home\will\.claude\`).
Real work happens in WSL, launched from `~/SITES/<repo>` — not from the Windows home dir.

Rules that still apply here:

- pnpm not npm/yarn; uv not pip; pipx for Python apps.
- Never commit to main/master — branch or worktree, draft PRs.
- Conventional commit prefixes: feat, fix, perf, chore, docs.
- Run linters/typechecks/tests before finalizing.
- vast.ai GPU rental: `vastai` and `vast-ssh` on this PATH hop into the WSL wrapper (`wsl.exe -e`), where the credential and guards live. There is no native Windows vast.ai CLI by design; `%USERPROFILE%\.local\bin\vastai.cmd` is the Windows entry point. The hop needs your own unsandboxed account: `Wsl/Service/CreateInstance/E_ACCESSDENIED` means the shell does not hold your ordinary token (a Codex Windows sandbox, a restricted token): `whoami` names another account, or `whoami /groups | findstr /i "S-1-5-12 S-1-15-2"` lists a RESTRICTED or AppContainer SID. The fix is to rerun outside the sandbox or with escalated permissions. Never install the vendor plugin or CLI here, never `vastai set api-key`; details: WSL `~/dotfiles/harness/data-source-clis.md`.
