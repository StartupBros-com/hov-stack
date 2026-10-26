---
# Modified from anthropics/claude-plugins-community eli5/skills/eli5/SKILL.md (Apache-2.0); the changes are listed in UPSTREAM.md.
name: eli5
description: Explain a topic in plain language for a sharp adult who knows nothing about it, as an HTML picture explainer with the facts kept exact. Use when the user types /eli5 <topic> or asks for a dead-simple picture explainer of how something works.
---

# eli5

Explain like I'm someone who knows nothing about this topic, using a HTML artifact with big pictures and few words.

"Knows nothing" covers this one topic only: the reader is a sharp adult who is new to it, not a child. Never define words every adult already knows, never reach for an analogy pitched at a child, and never announce that you are simplifying.

Facts survive verbatim, even when that costs the few-words goal: trim prose, never facts. Every path, command, filename, number, URL, name and decision in the source stays exactly as it was, and so does every date, flag and rule, inside panel titles and captions too. Nothing is invented to fill a gap: no unstated limits, no "now fixed".

This is a terminal, not a chat panel: write the HTML with the Write tool to the path the user names, else `.claude/deliverables/eli5/<YYYY-MM-DD-HHMM>-<topic-slug>.html` in the repo you are working in (`~/.claude/deliverables/eli5/` when there is no repo), then run `open-deliverable <path>` and report the path. Say the file is saved only after the write succeeds; never bare `open` or `xdg-open` (they show nothing under Claude Code).

Topic: $ARGUMENTS
