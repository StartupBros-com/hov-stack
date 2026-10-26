# Answer key — fixture.html (JUDGE ONLY; never include in an arm prompt)

## Planted defects (11)

| ID | Location | Defect | Domain |
|---|---|---|---|
| D1 | first `.icon-btn` button (menu icon) | icon-only button with no accessible name (no text, no aria-label, svg not labelled) | accessibility |
| D2 | `<div class="icon-btn" onclick="share()">` | div used as a button: not focusable, no role, no keyboard activation | accessibility |
| D3 | `input:focus { outline: none; }` | focus indicator removed on inputs with no replacement style | accessibility |
| D4 | `p.lead { line-height: 1.0; letter-spacing: 0.12em; }` | body text at line-height 1.0 (too tight) and wide letter-spacing on running text | typography |
| D5 | `p.hint` colour `#9a9a9a` on `#fff` | contrast ≈ 2.7:1, fails WCAG AA 4.5:1 for 14px text | color / accessibility |
| D6a | `.icon-btn { width:20px; height:20px }` | 20×20 px hit area, below 24 px minimum (WCAG 2.5.8) and far below 44 px comfortable | ui / accessibility |
| D6b | `.card { radius 16px; padding 8px }` + `.card .cta { radius 16px }` | nested radius equals outer radius; concentric rule wants inner = outer − padding = 8px | ui |
| D7 | `.page { width: 1200px; grid 3 cols }` no media/container query | fixed-width, three-column grid overflows on narrow viewports; not adaptive | layout |
| D8a | `<p class="error">Oops! Something went wrong :(</p>` | error copy: no cause, no action, emoticon, detached from the failing field (margin-top 24px, after both fields) | writing |
| D8b | `<h1>Sign in</h1>` vs button `Log In` | inconsistent terminology (sign in vs log in) and Title Case on the button | writing |
| D9 | `.btn { transition: all 0.6s }` + `.btn:hover { width: 220px }` | `transition: all` and animating `width` (layout property); 600 ms too slow for hover; no reduced-motion handling for this transition | ui / motion |

## Honest controls (9) — flagging any of these as a defect is a FALSE ACCUSATION

| ID | Location | Why it is correct |
|---|---|---|
| C1 | `<svg aria-hidden="true">` inside "Log In" button | decorative icon correctly hidden; button has visible text name |
| C2 | `.sr-only` span "Settings" in third icon button | correct visually-hidden accessible name using the standard clip pattern |
| C3 | `.btn:focus:not(:focus-visible) { outline:none }` + `.btn:focus-visible { outline: 2px solid }` | correct focus-visible pattern; keyboard focus ring preserved |
| C4 | `td.num { font-variant-numeric: tabular-nums; text-align:right }` | correct: tabular figures on a numeric column, right-aligned |
| C5 | `@media (prefers-reduced-motion: reduce) { .toast { animation:none } }` | reduced-motion respected for the toast; 240 ms ease-out enter is appropriate |
| C6 | `<label for="email">` / `<input id="email">` (and pw) | correctly associated labels; autocomplete tokens correct |
| C7 | `p.note` colour `#595959` on `#fff` | contrast 7.0:1, passes AA and AAA; NOT a contrast failure |
| C8 | `<button type="button">Cancel</button>` inside form | correct type; will not submit the form |
| C9 | `role="status"` on toast; "You have no unread notifications." empty state | polite live region is correct; empty-state copy is clear — demanding an illustration or CTA is taste, not a defect |
| C10 | `.btn` white `#fff` text on `#2f6fed` | contrast 4.55:1, passes WCAG AA for normal text (measured); flagging it as failing is a false accusation (flagging it as "marginal, verify" is not) |

## Scoring per run
- TP = number of D-items reported (partial credit 0.5 if the element is named but the reason is wrong)
- FA = number of C-items reported as defects
- Extra = findings not in either table; judge labels each `valid-unkeyed` (a real defect the key missed) or `taste/noise`
- Report TP/11, FA/9, extra counts.
