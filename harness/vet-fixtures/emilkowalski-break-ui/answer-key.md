# Answer key — MemberList.tsx + member-list.css (JUDGE ONLY; never include in an arm prompt)

The component is a members list. Every planted defect is latent: it is invisible
with the demo data and appears only under worst-case data. Every control is a
place that looks suspicious on a skim but is correct.

## Planted defects (11)

| ID | Location | Defect | Signature it maps to |
|---|---|---|---|
| D1 | `initials()` — `name.split(" ")` then `parts[0][0] + parts[1][0]` | Single-word name ("Cher", "Madonna", a CJK name) → `parts[1]` is undefined → TypeError, the row (or the whole list) crashes; emoji-first or CJK-first name → lone surrogate / wrong glyph; particles and suffixes ("van der Berg", "Montgomery III") → wrong letters | wrong initials / `.split(' ')[0][0]` |
| D2 | `.member-text { flex: 1 }` with no `min-width: 0`, while `.member-name` and `.member-email` are `nowrap` + `ellipsis` | Flex item min-width:auto equals the nowrap content width, so a long name or email never truncates: the text column grows, the row overflows and the trailing badge/pill/numbers are pushed off or clipped | text overflows instead of truncating / `min-width: 0` |
| D3 | `{m.openTasks} open tasks` | Hardcoded plural: "1 open tasks" (contrast: the header count uses Intl.PluralRules correctly) | "1 members" / hardcoded plural |
| D4 | `<img className="avatar" src={m.avatarUrl}>` with no `onError` and no branch for a missing `avatarUrl` | Missing avatarUrl renders `src={undefined}` (empty image, or in some setups a request to the page URL); a 404 renders the broken-image icon; no fallback to initials | broken-image icon / no `onError` fallback |
| D5 | `.member-site { word-break: break-all }` | Long URL breaks at arbitrary characters on every line (mid-token), not only when it has to; the fix is `overflow-wrap: anywhere` (and ideally middle truncation for URLs) | long word breaks mid-word / `word-break: break-all` |
| D6 | `.btn-invite { width: 96px; white-space: nowrap; overflow: hidden }` | A translated label ("Einladung senden", "Convidar membro", "Inviter un membre") is clipped; width should come from content with a min-width | long translated button label / fixed-width button |
| D7 | `.count-pill { width: 20px; height: 20px }` rendering the raw `m.openTasks` | Counts of 3+ digits overflow or get squeezed out of the 20px circle; the number is also unformatted (1284, not 1,284 or 99+) | badge/pill too small for the value; raw number |
| D8 | `daysAgo()` — `${days} days ago` | "0 days ago", "1 days ago", negative values with clock skew or a future timestamp, and never "hours ago"; should use `Intl.RelativeTimeFormat` with a unit choice | hardcoded time copy / no `Intl.RelativeTimeFormat` |
| D9 | `shown.map(...)` with no empty branch | Zero members, or a search with no match, renders the header ("0 members") over a blank list with no message | empty state missing |
| D10 | `<span className="chip chip-more">+{teams.length - TEAM_PREVIEW}</span>` rendered unconditionally | "+0" when there are exactly 3 teams, "+-2" when there is 1, "+-3" when there are none | tag row `+N` overflow computed without a guard |
| D11 | `.member-bio { max-height: 36px; overflow: hidden; line-height: 1.5 }` at 13px | 1.5 × 13px = 19.5px per line, so a two-line bio is cut mid-glyph at 36px; no `line-clamp`, no fade; worse at larger root font size / 200% zoom | last line cut off mid-glyph / use `line-clamp` |

Partial credit (0.5): the element is named and the data that breaks it is right, but the stated cause or fix is wrong (e.g. D2 blamed on `text-overflow` instead of flex min-width; D5 "fix" that keeps `break-all`).

## Honest controls (11) — reporting any of these as a defect is a FALSE ACCUSATION

| ID | Location | Why it is correct |
|---|---|---|
| C1 | `.avatar { flex-shrink: 0; object-fit: cover }` | The avatar cannot be squished into an oval and any aspect ratio is cropped correctly |
| C2 | Header count via `Intl.PluralRules` ("1 member" / "2 members") | Correct pluralization; it is the row's "open tasks" copy (D3) that is hardcoded, not this |
| C3 | `.num { font-variant-numeric: tabular-nums }` on storage and time | Correct: tabular figures on values that change |
| C4 | `alt=""` on the avatar | The avatar is decorative next to the visible name; empty alt is the correct choice, not a missing alt |
| C5 | `loading="lazy" decoding="async"` on avatars | Correct for a list of images; not a defect |
| C6 | `Intl.NumberFormat(locale, { maximumFractionDigits: 1 })` for GB | Float noise (2.3000000001) and locale separators are handled; not a raw number |
| C7 | `integer.format(totalCount)` in the header | 1,284 / 1.284 per locale; the header number is formatted (the pill, D7, is not) |
| C8 | `.badge-role { white-space: nowrap; flex-shrink: 0 }` | The role badge cannot wrap or shrink; this is the textbook fix, already applied |
| C9 | `.members { container-type: inline-size }` + `@container (max-width: 360px)` stacks the row and widens search | Narrow containers are handled; "no narrow-width handling" is a false accusation. (D2 still breaks inside the stacked layout, which is a different finding.) |
| C10 | `prefers-color-scheme: dark` token overrides | Dark mode is handled; "no dark mode" is a false accusation |
| C11 | `members` is one page of at most 50 rows (file header comment and the `Props` comment) | "Renders 1,000 rows without virtualization" is a false accusation: the page size is schema-backed at 50. Suggesting the parent or API be checked is fine; reporting virtualization as a break here is not |

## Part 1 dataset rubric (10 + plausibility)

Score the arm's worst-case dataset, 1 point each when a concrete value is given:

| ID | Value the dataset must contain |
|---|---|
| Q1 | A single-word name (mononym) |
| Q2 | A name in a non-Latin script (CJK, Thai, Devanagari, Cyrillic, Arabic) |
| Q3 | An RTL name or RTL text somewhere in the row |
| Q4 | An emoji or ZWJ sequence in a name or bio |
| Q5 | A long plausible name (≥ 35 characters that read as a real name, e.g. a Spanish or Portuguese compound name, or a long Thai or Sri Lankan name) |
| Q6 | A long email or URL (≥ 50 characters) with no spaces |
| Q7 | Counts at 0, 1 and ≥ 1,000 (openTasks and/or totalCount) |
| Q8 | A member with missing optional fields (no title, no avatarUrl / a 404 URL, no teams, no bio) |
| Q9 | The empty list and the single-item list as explicit cases |
| Q10 | A long translated invite label (German, Portuguese, French, Finnish, …) |

Plausibility flag P: PASS when the long values read as real-world data (names, domains, copy); FAIL when the dataset relies on "aaaaaaaa…", "Lorem ipsum", "xxxx" or repeated characters as its long values. Record PASS/FAIL per run; it is reported beside Q/10, not added to it.

## Scoring per run

- TP = D-items reported (1 each, 0.5 partial) → TP/11
- FA = C-items reported as defects → FA/11
- Q = dataset rubric points → Q/10, plus P: PASS/FAIL
- Extra = findings in neither table; label each `valid-unkeyed` (a real break the key missed; name it) or `taste/noise`
- Declined = the arm refused to produce findings (e.g. "cannot observe without a browser"); record it as a run outcome, with TP 0, FA 0, and whatever Q it still produced. Report it separately from a run that tried and missed.

## Corrections, 2026-10-07 (after the first six-run scoring; the key above is kept as scored)

- **C2 is a defect, not a control.** `plural.select(totalCount) === "one"` chooses between the English nouns "member" and "members" by the viewer's locale category, so fr-FR renders "0 member" (French treats 0 as singular) and ru-RU renders "21 member". All six runs reported it and both judges scored it FA under the key as written. Reclassified as **D12**: hardcoded English nouns selected by a foreign plural category; the fix is a per-locale string map, and `Intl.PluralRules` alone is not it. README.md records the scores both ways. `MemberList.tsx` is unchanged so the recorded runs stay reproducible; a future key revision that wants a real C2 control must make the header English-only (`totalCount === 1`) or key the nouns per locale.
- **D10 is visible in the demo data.** The chip renders for every row, so the shipped page already shows "+-1" for the two-team member and "+-2" for the one-team member. Every arm saw it rather than had to construct it. It stays in the key as the easiest row.
- **Saturation.** Under sonnet, no tools, one turn, all three arms scored 10 or 11 of 11 on D1-D11 at n=2 (12 or 11 of 12 with D12). This key does not separate a bare model from a skill at this difficulty; the next run needs harder latent defects (interactions between two rules, defects that only a rendered layout shows) or a rendering arm before it can rank skills.
