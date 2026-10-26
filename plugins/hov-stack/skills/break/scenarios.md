# Scenario axes

The menu step 2 of [SKILL.md](SKILL.md) selects from. Each axis carries a cue: the property of the component that makes the axis worth running. Cue matches, axis stays; cue fails, axis is dropped and the drop is named in the plan.

An axis that stays contributes its scenarios as written here, plus any value the component's own props make obviously worse, such as the longest option in a real dataset.

## Content length

**Cue: the component renders text it does not author.** User input, CMS content, API data, translations. A fixed label the codebase controls fails the cue.

| Scenario | What it catches |
| --- | --- |
| Empty string | Collapsed boxes, floating labels with nothing to float over, placeholder-only inputs |
| One word | Buttons and badges sized to their longest expected content |
| Typical content | The baseline the others are judged against |
| Several sentences | Wrapping, line-height at multiple lines, containers that assumed one line |
| One unbreakable string | A long URL or `Donaudampfschiffahrtsgesellschaft`: overflow with no wrap opportunity |

Breaks land in `better-typography` for wrapping and truncation, `better-layout` where the container has no room and `better-writing` where the source copy is the problem.

## Content shape

**Cue: the text can come from users or locales the team does not write in.** Same sources as content length, minus content the codebase fully controls.

| Scenario | What it catches |
| --- | --- |
| Emoji, alone and mixed into text | Line-height jumps, broken vertical centering, truncation splitting a character |
| RTL text | Direction handling, punctuation landing on the wrong side |
| Mixed-direction text | An LTR product name inside an RTL sentence, and the reverse |
| Diacritics and tall scripts | Clipped ascenders and descenders in tight line boxes |
| Numbers where columns align | Proportional figures wobbling in tables and timers |

Breaks land in `better-typography`; spatial mirroring lands in `better-layout`.

## Quantity

**Cue: the component repeats over items.** Lists, tables, grids, tag rows, avatar stacks. A singular component fails the cue.

| Scenario | What it catches |
| --- | --- |
| Zero items | Blank regions, missing empty states |
| One item | Grids and layouts designed around plural content |
| The realistic count | The baseline |
| Ten times the realistic count | Missing scroll or pagination, performance collapse, sticky elements unsticking |

Zero-item breaks land in `better-writing` for the empty state and `better-layout` for the region; the rest land in `better-layout`.

## Container

**Cue: always.** Everything renders inside something, and the component does not choose its container's width. Each width is a fixed container on the page, never a viewport to resize.

| Scenario | What it catches |
| --- | --- |
| A 320px container | Clipping, horizontal scroll, controls escaping the box |
| Squeezed by a flex or grid sibling | Min-content blowout, the component refusing to shrink |
| A very wide container | Unbounded measure, stretched controls, content pinned to opposite edges |

Breaks land in `better-layout`.

## Time

**Cue: the component renders a timestamp, a relative time, or a duration from data.** A date the codebase formats once at build time fails the cue.

| Scenario | What it catches |
| --- | --- |
| Now, and a few seconds ago | "0 seconds ago" or "0 days ago" where "just now" belongs |
| Twelve days, eleven months and three years ago | Relative-time thresholds that never hand off to an absolute date |
| A future timestamp | "-3 days ago" from clock skew or a scheduled date |
| A zero or epoch timestamp | 1970 rendered as a real date instead of a missing value |
| A late-evening timestamp in a far timezone | The day flips between UTC and the viewer's zone |
| A very long duration | Hours that never roll up to days |

Hand-built strings fail these. `Intl.RelativeTimeFormat` and `Intl.DateTimeFormat` localize the value and unit you hand them; choosing the unit, the threshold for handing off to an absolute date, the clock-skew guard for a future timestamp, and what a zero or missing timestamp means stay the component's job, so a swap to Intl alone fixes the wording, not the rows above. Breaks land in `better-writing` for the copy and `better-ui` for the formatting.

## Images and media

**Cue: the component renders an image it does not ship.** Avatars, covers, logos and thumbnails from data. A static illustration in the bundle fails the cue.

| Scenario | What it catches |
| --- | --- |
| An image URL that 404s | The broken-image icon where a fallback belongs |
| No image at all | The fallback itself: initials, colour, and size parity with real images |
| A very wide or very tall source | Distortion without `object-fit: cover`, a card blown out on one axis |
| A transparent or dark logo on a dark surface | The asset disappears into the background |
| A slow image | Layout shift without fixed dimensions or `aspect-ratio` |

Breaks land in `better-layout` for sizing and shift, and in `better-colors` for the dark-surface case.

## State

**Cue: the component has the state.** Read the props and the interaction model; render only the states that arrive as props. A static component fails the cue entirely.

| Scenario | What it catches |
| --- | --- |
| Loading | Layout shift when content arrives, spinners with no accessible name |
| Error | Messages that overflow, color as the only signal |
| Disabled | Contrast collapse, focus behavior on disabled controls |

Focus and hover are the user's to try while they view the page. Invite them to tab through the instances in the report rather than simulating focus in the harness.

Breaks land in `better-accessibility`; purely visual state polish lands in `better-ui`.

## Environment

**Cue: the project supports the mode.** These are viewing modes, not page content, so the page renders nothing for them. Name them in the report for the user to toggle while viewing: OS dark mode where a dark theme exists, browser zoom, reduced motion. Simulating one on the page, such as re-declaring dark tokens under a class, observes a different component.

Dark-mode breaks land in `better-colors`; zoom and motion land in `better-accessibility`.
