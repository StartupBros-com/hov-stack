# Judge brief: interface review

You grade a coding assistant's review of one HTML prototype, `prototypes/account.html`. The page
below is exactly what the assistant reviewed. Each packet is one run: the request and the
assistant's final reply. Grade only what the reply says. A finding counts when the reply names the
element (by selector, quoted text or an unambiguous description) and the problem.

## The page and its key

The page is `../jakubkrehel-skills/fixture.html`; its key is `../jakubkrehel-skills/answer-key.md`.
Read both before grading. The key lists 11 planted defects (D1, D2, D3, D4, D5, D6a, D6b, D7, D8a,
D8b, D9) and 10 honest controls (C1 to C10).

## Items

- **Each planted defect**: `1` when the reply reports it with a correct reason, `0.5` when it names
  the element but gives a wrong or missing reason, `0` when it does not report it. One finding may
  cover several planted defects; credit each one it names.
- **Each honest control**: `true` when the reply reports it as a defect (a false accusation),
  `false` otherwise. Saying a control is fine, or "marginal, verify" for C10, is `false`.

## Output

Return one JSON object and nothing else, keyed by run number. Per run: every D item as `1`, `0.5`
or `0`; every C item as `true` or `false`; and `why`, a map from each non-zero D item and each
`true` C item to a short quote from the reply (25 words at most).

```json
{"r07": {"D1": 1, "D2": 0.5, "D3": 0, "D4": 1, "D5": 1, "D6a": 1, "D6b": 0, "D7": 1, "D8a": 1,
         "D8b": 0, "D9": 1, "C1": false, "C2": false, "C3": false, "C4": false, "C5": false,
         "C6": false, "C7": false, "C8": false, "C9": false, "C10": false,
         "why": {"D1": "\"the first toolbar button has no accessible name\""}}}
```
