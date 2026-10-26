// rules.prose.mjs — deterministic English prose tells for de-slopify's mechanical pre-pass.
//
//   node ~/.claude/skills/kill-ai-slop/scripts/scan.mjs <dir> \
//        --rules=$HOME/.claude/skills/de-slopify/scripts/rules.prose.mjs
//   ($HOME, not ~: bash does not tilde-expand after "=" in a non-assignment word.)
//
// A --rules module for kill-ai-slop's scanner (same tell shape; `copy: true` reads .md).
// Every hit is a place to look, confirmed by reading — the visual tells work the same way.
// p1 fires on em-dashes used as house style (the harness's own docs: 46 hits over 301 lines,
// zero from the other tells), so it locates, it never judges.
//
// Measured 2026-09-02 (memory: anti-slop-skill-list-vet-2026-09): on a 21-defect prose
// fixture, p1-p12 hit 12 defect classes with 0 false positives on 11 honest controls,
// including the em-dash that four of four Sonnet reading passes missed. p13-p15 are
// artifact tokens that never belong in prose (chatbot citation markup, template
// placeholders, zero-width characters); they were not planted in that fixture — the
// deciding measurement is a plant of each in the next fixture revision.
const VOCAB = "delve|delves|tapestry|seamless(?:ly)?|robust|leverage|empower(?:s|ing)?|streamlined?|frictionless|elevate|holistic|unlock|game-chang\\w+|cutting-edge|paradigm|synerg\\w+";

export default [
  { id: "p1", group: "copy", name: "em-dash as prose punctuation", fix: "comma, semicolon, colon, or split the sentence",
    copy: true, patterns: [ /^(?![ \t]*[|`]).*—/m ] },
  { id: "p2", group: "copy", name: "bold-label bullet", fix: "prose, or plain bullets",
    copy: true, patterns: [ /^[ \t]*[-*] \*\*[^*\n]{1,40}:\*\*/m ] },
  { id: "p3", group: "copy", name: "sentence-initial Additionally/Moreover", fix: "delete or use a real transition",
    copy: true, patterns: [ /(?:^|[.!?]\s+)(?:Additionally|Moreover|Furthermore),/m ] },
  { id: "p4", group: "copy", name: "trailing -ing commentary clause", fix: "cut the commentary; keep the fact",
    copy: true, patterns: [ /,\s(?:ensuring|highlighting|underscoring|reflecting|emphasizing|showcasing|empowering|enabling|allowing|making it)\b[^.\n]{0,80}[.!]$/m ] },
  { id: "p5", group: "copy", name: "AI vocabulary cluster (2 within 120 chars)", fix: "plain synonyms; density is the signal",
    copy: true, patterns: [ new RegExp(`\\b(?:${VOCAB})\\b[^\\n]{0,120}?\\b(?:${VOCAB})\\b`, "i") ] },
  { id: "p6", group: "copy", name: "negative parallelism (not just X, it's Y)", fix: "say what it is; drop the strawman",
    copy: true, patterns: [ /\b(?:is|it's|isn't|not)\s+(?:just|only|merely)\s+(?:a|an|about\s)?[^.\n]{2,60}?,?\s+(?:it's|it is|but)\b/i ] },
  { id: "p7", group: "copy", name: "forced enthusiasm", fix: "just announce",
    copy: true, patterns: [ /\b(?:thrilled|excited|delighted) to (?:announce|share|introduce)\b|couldn't be more (?:excited|thrilled)/i ] },
  { id: "p8", group: "copy", name: "here's-why lead-in", fix: "explain directly, or delete",
    copy: true, patterns: [ /\bHere's (?:why|the thing|what)\b/ ] },
  { id: "p9", group: "copy", name: "significance inflation", fix: "cut the commentary; state the fact",
    copy: true, patterns: [ /\b(?:marks|represents) a (?:pivotal|defining|significant|crucial|major) (?:moment|milestone|step)\b/i, /\bunderscor(?:es|ing) (?:our|the|its)\b/i ] },
  { id: "p10", group: "copy", name: "hedge filler", fix: "delete unless the caveat changes reader behavior",
    copy: true, patterns: [ /\b(?:It's worth noting|It bears mentioning|Keep in mind that|It is important to note)\b/i ] },
  { id: "p11", group: "copy", name: "weasel attribution", fix: "name the source or cut the claim",
    copy: true, patterns: [ /\b(?:Many|Most) (?:developers|engineers|experts|people|users) (?:agree|would tell you|say|believe)\b/i, /\bExperts (?:agree|argue|say)\b|\bIndustry reports\b/i ] },
  { id: "p12", group: "copy", name: "rhetorical question setup", fix: "state the reason",
    copy: true, patterns: [ /\bWhy (?:does this matter|should you care)\?/i ] },
  // p13-p15: artifact tokens, never legitimate in shipped prose. Unmeasured on the vet fixture.
  { id: "p13", group: "copy", name: "chatbot citation markup leaked", fix: "delete the token; cite properly or not at all",
    copy: true, patterns: [ /citeturn\d+search\d+|oaicite:\d+|contentReference\[/, /utm_source=chatgpt\.com/, /\[cite: \d+\]/ ] },
  { id: "p14", group: "copy", name: "template placeholder left in", fix: "fill it in or cut the sentence",
    copy: true, patterns: [ /\[(?:Your|Insert|INSERT|Company|Product) [^\]\n]{1,40}\]/ ] },
  { id: "p15", group: "copy", name: "zero-width or invisible character", fix: "strip it; nothing in prose needs U+200B/U+200C/U+FEFF",
    copy: true, patterns: [ /[​‌‍﻿]/ ] },
];
