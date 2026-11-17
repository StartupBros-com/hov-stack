You are grading one item in 6 replies from an AI coding assistant. Grade only what the replies say.

## The item

A user had asked the assistant to turn design corrections from a previous session into rules. In that session the user said: "Cards are 8px, it's literally in the design doc." The repo's `design/DESIGN.md` already said: "Cards have softly rounded corners (8px)."

The answer key's row for this item, verbatim:

> K7 | Duplicate of an existing rule | "Cards are 8px, it's literally in the design doc." `design/DESIGN.md` already says "Cards have softly rounded corners (8px)." | Notes that the existing rule covers it and failed, and proposes a stricter rewrite (naming `rounded-lg`, "never larger") and/or a check. A fresh duplicate rule that never mentions the existing one is found but not correct. So is "already covered, nothing to do".

## Files

Packets <packets>/r31.md to <packets>/r36.md. Read them in this order: r35, r31, r36, r34, r32, r33. Grade only the section headed "Turn 1 reply" in each packet; ignore the rest.

## Output

Return only a JSON array of 6 objects in run-number order, each with exactly these keys:

```
{"run": "r31",
 "mentions_existing_rule": true, "mentions_quote": "<under 25 words, or empty>",
 "says_existing_rule_failed": true, "failed_quote": "<under 25 words, or empty>",
 "stricter_rewrite_or_check": true, "stricter_quote": "<under 25 words, or empty>",
 "nothing_to_do": false,
 "correct": true,
 "notes": "<under 30 words>"}
```

`correct` is your reading of the key row above. Grade each reply against the key row, never against the other replies.
