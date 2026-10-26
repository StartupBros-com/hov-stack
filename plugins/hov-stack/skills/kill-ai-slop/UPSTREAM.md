# Upstream provenance

Frozen snapshot of https://github.com/yetone/kill-ai-slop (commit f6e2ae32b30443ec7bd0da4da971ee18d8f8ffcb, Apache-2.0 license),
first cherry-picked 2026-07-22 at 88cd5446be74793edd906dcf56f28deb6182852e per the
harness-addition evaluation and re-pinned 2026-09-20 (dotfiles#1230, item 7 of the pstack vet
triage in #1202). Deliberately NOT auto-tracked: upstream churns opinions fast; re-pull with
`python3 scripts/repin-kill-ai-slop.py <sha>` and re-read the diff.

What the 2026-09-20 re-pin brought (88cd544..f6e2ae3, 3 upstream commits): tell #27 "wobbling
spinner" (a centering translate clobbered by a spin keyframe, or an off-centre transform-origin)
with four scanner patterns in `scripts/scan.mjs`, its detection recipe and fix, taxonomy 34 -> 35
tells with 27-34 renumbered to 28-35, and a description tweak. Verified locally: `node --check`
clean, upstream `scripts/scan.test.mjs` passes, and the de-slopify overlay's `rules.prose.mjs`
still loads through `--rules` on the anti-slop fixture.

Local changes, both in SKILL.md's frontmatter and both re-applied by the repin script:
`disable-model-invocation: true` (on-demand posture), where upstream does not set it, and a
first line that is a comment naming the upstream file and pointing here. Everything else is
upstream text byte for byte; the repo LICENSE is copied verbatim.

Modification notice (Apache-2.0 section 4(b)): this `SKILL.md` is a modified version of the
upstream file, changed only as listed above; its first frontmatter line says so.
