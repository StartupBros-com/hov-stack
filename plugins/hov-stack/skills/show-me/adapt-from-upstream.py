#!/usr/bin/env python3
"""Generate the adapted show-me SKILL.md from the upstream text with exact, listed replacements.
Usage: adapt-from-upstream.py <upstream SKILL.md> <out SKILL.md>
Prints each replacement applied; exits 1 if any anchor is missing (upstream drifted), 2 on usage."""
import sys

if len(sys.argv) != 3:
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(2)
src_path, out_path = sys.argv[1], sys.argv[2]
s = open(src_path).read()

REPLACEMENTS = [
    # 1. frontmatter: invoke-only posture (harness convention for vendored skills)
    (
        "description: Help the user understand the current topic visually with concise diagrams, code-shape sketches, and focused HTML artifacts.\n---",
        "description: Help the user understand the current topic visually with concise diagrams, code-shape sketches, and focused HTML artifacts.\ndisable-model-invocation: true\n---",
    ),
    # 2. Mermaid: scope to surfaces that render it (this harness is a terminal)
    (
        "- Show component interaction, control flow, or data flow with Mermaid:",
        "- Show component interaction, control flow, or data flow with Mermaid only where the reader will render it (a PR or issue body on GitHub, a Markdown viewer, a written plan). This harness is a terminal: Mermaid arrives as raw source there, so in chat prefer the call tree, pseudocode, or diff forms above and reserve Mermaid for a file or PR body:",
    ),
    # 3. HTML file: Write tool, named landing path, no `open` (xdg-open no-ops under Claude Code's BROWSER=true)
    (
        "Match the product's colors, type, spacing, and components; use real labels and data; support desktop and mobile. Then open it for the user:\n\n```\nBash(open path/to/show-me-{description}.html)\n```",
        "Match the product's colors, type, spacing, and components; use real labels and data. Write it with the Write tool to the path the user names, else `.claude/deliverables/show-me/<YYYY-MM-DD-HHMM>-<description>.html` in the repo you are working in (`~/.claude/deliverables/show-me/` when there is no repo), then run `open-deliverable <path>` and report the path. Never bare `open` or `xdg-open`: they show nothing under Claude Code.",
    ),
]

for old, new in REPLACEMENTS:
    if s.count(old) != 1:
        print(f"ANCHOR MISSING OR AMBIGUOUS ({s.count(old)} hits): {old[:70]!r}")
        sys.exit(1)
    s = s.replace(old, new)
    print(f"applied: {old[:60]!r} ->")

open(out_path, "w").write(s)
print("wrote", out_path, len(s), "bytes")
