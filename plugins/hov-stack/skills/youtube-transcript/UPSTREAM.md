# Upstream provenance

Frozen snapshot of https://github.com/davidondrej/skills (commit
081d4d52cddb1f24e9358add21d47a45d82dd3fd, 2026-08-09, MIT license), skill
`skills/research-and-web/youtube-transcript/SKILL.md`, adapted 2026-08-10.
Deliberately NOT auto-tracked: re-pull manually if wanted.

Local changes: stripped ALL DeepAPI content. Upstream's primary path was
DeepAPI (a paid third-party scraping API); we hold no DeepAPI key and nothing
else in this harness references it (grep, 2026-08-10). The yt-dlp fallback
path — originally ~40% of the file — now stands alone as the only path.
`disable-model-invocation: true` set locally (upstream had it
model-invocable); see rationale in SKILL.md header comment. LOWER PRIORITY
than google-safe-browsing: thin without the vendor path, no established
transcript-fetching workflow in this operator's stack to justify always-on.

Additional SKILL.md changes: added an attribution/rationale comment, shortened the description and reorganized headings for the standalone yt-dlp path; the output rule now prints text only below approximately 500 words.
