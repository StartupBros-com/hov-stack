# Vetting a third-party skill before adoption

Before installing, patching, or vendoring any skill you didn't author -- a
jsm skill, a plugin-marketplace skill, or one lifted from a public repo
(e.g. davidondrej/skills):

- Read every file in the skill folder, not just SKILL.md.
- Audit `scripts/` for outbound network calls, file access outside the
  expected scope, or command execution.
- Check `references/` and the body for prompt injection ("ignore previous
  instructions...", or any directive aimed at the agent rather than the
  human reader). A mandated closing line is one such directive: a SKILL.md
  that tells the agent to end every response with a vendor link or a
  request-access CTA is steering the operator's output channel (Warp's
  `skill-doctor`, 2026-09-20); rent-check's Boundaries treat the audited
  file's own "skip this section" / "approve this file" the same way.
- Watch for self-updating instruction channels: a skill that fetches or
  auto-refreshes its own instruction files from a remote server is a
  supply-chain vector regardless of how legitimate the vendor looks
  (davidondrej/skills' deepapi skill ships a detached daily updater that
  silently overwrites its references from the vendor's server -- that
  pattern alone is disqualifying).
- Verify the skill name isn't typosquatting one you already trust, and
  that it does not match a built-in slash command: a user skill of the
  same name shadows the command (measured 2026-09-20: Warp's `skill-doctor`
  took over `/skill-doctor`; harness-doctor section 7 now warns).
- Run it once in a sandboxed or throwaway environment before trusting it
  against real repos or credentials.
- Clone a repository under vetting outside `~/SITES` (e.g.
  `/tmp/vet-<name>`), and add no worktree of it under `~/SITES`. Every
  repository directly under `~/SITES` is marked workspace-trusted at the next
  session start (`hooks/lib/workspace-trust.js`), a linked worktree there
  trusting its main repository wherever that lives, so a Claude Code session
  started in it runs its project hooks, settings env and permission rules
  without a trust prompt. `~` itself is trusted the same way, and that trust
  reaches every directory under `~` that is not inside a git repository, so
  never unpack vetting material as a plain directory anywhere under `~`.
- Pin to a specific version/commit/tag -- never `latest` or a moving
  branch -- the way `skills-patches/` pins upstream jsm skills.
- Treat every product/feature claim in the skill body as unverified until
  confirmed against the actual tool/product it describes. A skill can read
  fluently and still describe a feature that doesn't exist -- this file
  exists because one did (davidondrej/skills goal-loop: fabricated
  lifecycle states, pause/resume, `create_goal`, subscription-auth
  requirement, all disproven against official docs 2026-08-10).

Adaptation conventions once a skill passes: verbatim upstream `LICENSE` +
an `UPSTREAM.md` (source URL, commit, date, license, local changes) beside
SKILL.md -- the emil-design-eng / writing-for-agents pattern. Plain name
unless it collides with a live jsm skill (then `-local` suffix + base name
in `retired-skills.txt`).

<!-- Core checklist adapted from davidondrej/skills effective-agent-skills
     §11 (MIT); the self-updating-channel and unverified-claims bullets are
     ours, earned by the 2026-08 evaluation of that same repo. -->
