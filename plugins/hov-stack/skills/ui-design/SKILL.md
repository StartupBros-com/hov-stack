---
name: ui-design
description: >-
  Design rules and review method for front-end UI work. Use when building a
  screen or component from a design image, Figma link or spec; reviewing a
  page, prototype, flow or UI change for problems; or polishing or tidying
  how a page looks, however small the change: spacing, colour, type, layout,
  accessibility or motion.
---

# UI design

The pack's design skills are slash-only, so the Skill tool cannot load them. This skill is how a plain request reaches them: find the row that matches the work, read that skill's `SKILL.md` by path and apply it. Paths are relative to the directory that holds this file; the pack ships its skills side by side, so `../better-ui/SKILL.md` is the better-ui skill. Read the reference files a skill points to only where the task touches them.

When the project has a design doc (`design/DESIGN.md`, `DESIGN.md`, or the one its `AGENTS.md` names), read it before any row. Its tokens and rules come first.

## Route

| The work | Read |
|---|---|
| Building from a design image or Figma link | **Building from a design** below; add a row below only for a decision the design and the project leave open, such as the accessible markup for a control the project lacks |
| Accessible names, focus, keyboard, contrast, hit areas, forms, reduced motion | `../better-accessibility/SKILL.md` |
| Grouping, alignment, spacing, responsive layout, reading order | `../better-layout/SKILL.md` |
| Type scale, line length, wrapping, numerals, font loading | `../better-typography/SKILL.md` |
| Palettes, colour tokens, contrast pairs, dark mode | `../better-colors/SKILL.md` |
| Surfaces, radius, shadows, icons, optical alignment, UI transitions | `../better-ui/SKILL.md` |
| Button labels, errors, empty states and other product copy | `../better-writing/SKILL.md` |
| A new animation | `../animate/SKILL.md` |
| Gestures, springs, drag, sheets, momentum | `../apple-design/SKILL.md` |
| The generic AI look: stock gradients, glows, emoji, filler copy | `../kill-ai-slop/SKILL.md` |
| Which library to use for a UI need | `../pick-ui-library/SKILL.md` |
| Review of a screen, flow or page | `../better-interface/SKILL.md`, which reads the domain skills itself |
| Review of a diff, branch or pull request | `../interface-review/SKILL.md`, with the user's words as its target |
| Review of animation code | `../review-animations/SKILL.md` |

A task that spans several rows reads each of them. A one-line fix reads the row it touches, or none.

These do a separate job the user opts into. When one fits, name its command once at the end of the reply instead of starting it:

- `/hov-stack:prototype`: several versions of one piece behind a picker.
- `/hov-stack:break <component>`: every state of one component on a test page.
- `/hov-stack:explain-interface`: how another site built something.
- `/hov-stack:find-animation-opportunities` and `/hov-stack:improve-animations`: motion sweeps of a codebase.
- `/hov-stack:learn-taste`: turn the design corrections in past sessions into written rules.

When the user asks for one of those jobs, read its `SKILL.md` and do it.

## Building from a design

A screenshot or exported image has no values to read. Sizes are ratios to the capture, so state the scale you assumed and treat every measurement as an estimate.

Build from the image without waiting, and say in the reply that the Figma file, if there is one, would replace every estimate. A Figma link with no Figma tool available is the exception: ask for a connection or an exported image of that frame, and build nothing from a guess.

Map every value onto the project's own tokens and components, using only the steps its theme defines. Read the theme file for them: a project that resets the scale keeps none of the framework's defaults. Each estimate goes to its nearest defined step, the sizes and insets of a control you build locally included, and the reply lists the rounding. The estimate belongs in the reply and the step in the code. When the design needs a component or variant the project lacks, build it locally from those steps and the existing tokens, leave the shared components unchanged and name the gap.

The reply lists every value with no exact token: the estimate, written as "about 24px", and the step the build used. From an image they are estimates at the scale you stated, so write each one as an estimate beside its token; "matches" and "exact" are for values you read from a Figma file. Say the build was not compared with the design unless you rendered both and looked.
