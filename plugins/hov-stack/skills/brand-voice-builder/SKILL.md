---
name: brand-voice-builder
description: >-
  Define a brand voice from scratch (Build mode) OR extract one from existing content
  (Extract mode). Use when starting a new brand, sub-brand, product, persona, or author
  voice, when copy sounds generic, or when "how should this sound?" is unclear. Does NOT
  apply existing voices — for that, use the brand-specific voice skill.
---

# Brand Voice Builder

A distinct voice is why a reader keeps reading: it sounds like one person talking to them, where generic copy sounds like a committee. This skill finds that voice and writes it down so every later piece of copy can use it.

This skill defines that voice. Either by extracting it from existing content the user is proud of, or building it strategically from scratch.

The output is a structured Voice Profile that future skills, agents, or humans can read and produce on-brand content from.

## When to use this skill

- Starting a new brand, sub-brand, product line, or property
- Defining voice for a new persona (instructor, member spotlight, co-founder, partner author)
- Existing copy sounds generic and the brand voice was never explicitly defined
- Output across channels feels inconsistent and there's no shared reference
- A customer / client needs a voice deliverable as part of a brand engagement

## When NOT to use this skill

- The brand voice is already defined and encoded in a project-specific skill: use that skill directly (e.g. hov-brand-voice, acme-brand-voice).
- The task is "make this sound like [existing brand]": use the existing brand's skill.
- The user only needs a one-off tonal shift, not a structural definition.

---

## Two Modes

### Mode 1: Extract

**Use when:** the user has existing content they're proud of (website copy, emails, social posts, transcripts) that represents how they want to sound.

**Process:** analyze the content for patterns, then codify what makes it distinctive.

### Mode 2: Build

**Use when:** starting fresh, existing content is generic, or the user wants to evolve their voice strategically.

**Process:** ask strategic questions, then construct a voice aligned with identity, audience, positioning, and aspiration.

### How to choose

Ask the user: "Do you have existing content that represents how you want to sound?"

- "Yes, I have content I'm proud of" → Extract mode
- "No, I'm starting fresh" → Build mode
- "I have content but want to evolve it" → Build mode, with existing content as reference for what to keep / change
- "I'm not sure" → Show them 2-3 samples of voices that are clearly defined and ask which they admire most. If they have strong reactions, switch to Build.

Both modes produce the same Voice Profile output format.

---

## Mode 1: Extract

### Step 1: Request samples

Ask for 3-5 pieces of content the user considers "most them":
- Website copy (especially About page, homepage hero, manifesto sections)
- Emails they sent and felt good about
- Social posts that performed well AND felt authentic
- Newsletter editions
- Video / podcast transcripts
- Anything where they thought "this sounds like me"

### Step 2: Analyze across six lenses

Read the samples and capture patterns in each lens. Write quick notes per lens before synthesizing.

**1. Tone patterns**
- Formal ↔ Casual: contractions? slang? sentence fragments?
- Serious ↔ Playful: humor? lightness? gravity?
- Reserved ↔ Bold: hedging? strong claims? confidence level?
- Distant ↔ Intimate: we / they vs I / you? personal stories? named characters?

**2. Vocabulary patterns**
- Industry jargon level: heavy / light / translated?
- Signature words or phrases that repeat
- Words that seem to be deliberately avoided
- Curse words, edgy language, in-group slang
- Specific numbers vs vague descriptors

**3. Rhythm patterns**
- Average sentence length
- Paragraph length
- Mix of short punchy vs longer flowing
- Use of fragments
- List density

**4. Structural patterns**
- How do pieces open? (story / question / statement / claim)
- How do they transition between ideas?
- How do they close? (CTA style / summary / open loop)
- Headers, bold, formatting preferences

**5. Personality signals**
- Self-deprecating or confident?
- Teacher or peer?
- Polished or raw?
- Optimistic or realistic?
- Recurring references and examples

**6. POV patterns**
- First person (I) or plural (we)?
- How is the reader addressed? (you / folks / friends / by name)
- Direct address or general statements?

### Step 3: Synthesize into Voice Profile

Use the Voice Profile template (below). Lean on real phrases pulled from the samples for the on-brand examples section. For off-brand examples, write phrases that would clearly violate the patterns you observed.

---

## Mode 2: Build

### The 17 Strategic Questions

Ask in 5 batches. Don't dump all 17 at once. Wait for answers, react, refine.

**Batch 1: Identity (who is speaking)**
1. What are 3-5 words that describe your personality?
2. What do you stand for? What's your core belief about your industry or topic that not everyone shares?
3. What's your background? What experience shaped how you see things?
4. What makes you genuinely different from others in your space?

**Batch 2: Audience (who is listening)**
5. Who specifically are you talking to? (Be precise: not "founders," but "first-time technical founders who've never marketed before.")
6. What tone resonates with them? What do they respond to?
7. What would make them trust you? What would turn them off?

**Batch 3: Positioning (what role do you play)**
8. Are you the expert, the peer, the rebel, the guide, or the insider?
9. Where do you sit on accessible ↔ exclusive?
10. Where do you sit on approachable ↔ authoritative?

**Batch 4: Aspiration (who do you admire)**
11. Name 2-3 brands or people whose voice you admire. What specifically do you like about how they communicate?
12. What do you explicitly NOT want to sound like? (List 3-5 specific brands, voices, or vibes.)

**Batch 5: Practical (rules and rituals)**
13. Any words or phrases that are signature to you?
14. Any words or phrases you hate or want to avoid?
15. How do you feel about humor? Profanity? Hot takes?
16. Are there any mechanical rules that should always hold? (e.g. "no exclamation marks," "always specific numbers," "never use 'we' for first-person")
17. Where will this voice be applied? (channels, contexts, funnel stages)

### Synthesize

From the answers, construct the Voice Profile. Lean on the aspiration/anti-aspiration answers (Q11-12) heavily: they are the highest-signal data for tonal positioning. The mechanical rules from Q16 become the enforceability backbone.

---

## The Voice Profile (Output Format)

Use this exact structure for every Voice Profile, regardless of mode. Save it to a file the user can reference and feed into other skills.

```markdown
# [Brand / Person Name] Voice Profile

## Voice Summary
[2-3 sentences capturing the essence. What does this voice FEEL like to encounter? What kind of person does it sound like?]

## Core Personality Traits
- **[Trait 1]:** [What this means in practice, with one short example]
- **[Trait 2]:** [What this means in practice, with one short example]
- **[Trait 3]:** [What this means in practice, with one short example]
- **[Trait 4]:** [What this means in practice, with one short example]

## Tone Spectrum

| Dimension | Position | What this means in practice |
|---|---|---|
| Formal ↔ Casual | [position] | [specifics] |
| Serious ↔ Playful | [position] | [specifics] |
| Reserved ↔ Bold | [position] | [specifics] |
| Simple ↔ Sophisticated | [position] | [specifics] |
| Warm ↔ Direct | [position] | [specifics] |
| Polished ↔ Raw | [position] | [specifics] |
| Hyped ↔ Understated | [position] | [specifics] |
| Promise-heavy ↔ Proof-heavy | [position] | [specifics] |

## Vocabulary

**Words and phrases to USE (with reasons):**
- [word/phrase] -- [why / when]
- [word/phrase] -- [why / when]
- [signature phrases]

**Words and phrases to AVOID (with reasons):**
- [word/phrase] -- [why]
- [word/phrase] -- [why]
- [AI-sounding words to skip]

**Jargon level:** [Heavy / Moderate / Light / Translated]
**Profanity:** [Yes / Occasional / Never]

## Rhythm and Structure

**Sentences:** [pattern, e.g. "Mix of short punchy (3-5 words) and medium (10-15 words). Rarely long. Fragments welcome."]
**Paragraphs:** [pattern, e.g. "Short. 1-3 sentences max. Lots of white space."]
**Openings:** [pattern, e.g. "Often starts with a bold claim or a direct challenge. Rarely asks questions."]
**Formatting:** [headers, bullets, bold, emoji conventions]

## POV and Address

**First person:** [I / We / Mix]
**Reader address:** [You / Direct name / Folks / Friends / etc.]
**Relationship stance:** [Teacher / Peer / Guide / Insider / Rebel / Smart friend / etc.]

## Mechanical Rules (always enforceable)

These are bright-line rules. Violations should be auto-corrected.

- [rule 1, e.g. "Zero exclamation marks. Calm confidence, not performed excitement."]
- [rule 2, e.g. "Every claim backed by a specific number where possible."]
- [rule 3, e.g. "First-person singular only. Never 'we' for the founder voice."]
- [add more as needed -- mechanical rules are gold]

## On-Brand Example Phrases

Phrases that sound exactly like this voice:
- "[example phrase pulled from samples or constructed]"
- "[example phrase]"
- "[example phrase]"
- "[example phrase]"
- "[example phrase]"

## Off-Brand Example Phrases (with reasons)

Phrases that would clearly violate this voice:
- "[off-brand phrase]" -- [why it fails]
- "[off-brand phrase]" -- [why it fails]
- "[off-brand phrase]" -- [why it fails]
- "[off-brand phrase]" -- [why it fails]
- "[off-brand phrase]" -- [why it fails]

## Aspiration Models

Voices this brand admires and shares DNA with:
- **[Brand / Person]** -- [what specifically resonates]
- **[Brand / Person]** -- [what specifically resonates]
- **[Brand / Person]** -- [what specifically resonates]

When in doubt, ask: "Would [aspiration model] write it this way?"

## Anti-Aspiration

Voices this brand explicitly refuses to sound like:
- **[Brand / vibe]** -- [why it's wrong for this voice]
- **[Brand / vibe]** -- [why it's wrong for this voice]
- **[Brand / vibe]** -- [why it's wrong for this voice]

If a draft drifts toward any of these, rewrite.

## Channel and Stage Calibration

How the voice flexes across contexts. Pillar / dimension proportions shift; the core never does.

| Context | Lead emphasis | Support | Notes |
|---|---|---|---|
| [TOFU / cold / ad] | [trait] | [trait] | [specifics] |
| [MOFU / nurture] | [trait] | [trait] | [specifics] |
| [BOFU / sales] | [trait] | [trait] | [specifics] |
| [Post-purchase] | [trait] | [trait] | [specifics] |

(If voice doesn't flex by funnel, replace with relevant context dimensions: long-form vs short-form, public vs member-only, etc.)

## Quality Test

A draft passes this voice profile when:

1. **Recognizable:** could a member of this audience identify this content as "theirs" without a byline?
2. **Actionable:** could a writer (human or AI) produce on-brand content using only this profile?
3. **Differentiated:** does it sound different from the named anti-aspirations?
4. **Authentic:** can the user name a specific belief, story, or trait this reflects?
5. **Consistent:** can it be applied across formats (social, email, long-form, ad)?
6. **Mechanically clean:** does it pass every Mechanical Rule above?

If any answer is no, the profile needs more specificity. Iterate before locking it in.

## Maintenance

Voice is not static. Revisit this profile when:
- The brand evolves or pivots
- Audience changes significantly
- Current voice isn't converting (run the Quality Test on losing copy first)
- New team members or AI agents need onboarding
- Content starts feeling inconsistent across channels
```

---

## After the Profile: Encoding It as a Skill

A Voice Profile is most valuable when encoded as a project-specific skill. After the profile is approved:

1. Save the profile at `[project]/strategy/[BRAND]-BRAND-VOICE.md` as the source of truth.
2. Create a project skill at `[project]/.claude/skills/[brand]-brand-voice/SKILL.md` that:
   - References the profile as authoritative
   - Includes a Quick Reference distilled from the profile (pillars, tone spectrum, anti-patterns, locked terminology)
   - Includes a Maintenance section with a drift-check mechanism (sync header with source mtime)
3. Pattern template: model the new skill on any brand-voice skill already installed, if there is one; otherwise the three parts above are the whole template.

The builder CREATES voice. The encoded skill APPLIES voice. Don't skip the encoding step: a profile that isn't wired into a skill gets ignored.

---

## The Context Paradox

When applying a Voice Profile to actual copy generation downstream, less context often beats more. A 1500-word voice profile fed into every copy task produces hedged, committee-sounding output. Compress to essentials when chaining:

- For each task, pass: Voice Summary (3 sentences) + 2-3 Mechanical Rules + 3 on-brand and 3 off-brand example phrases.
- Pass full profile only for high-stakes work (launch sequence, hero page rewrite).
- If output feels generic or hedged, the profile is being over-passed. Strip back to essentials.

---

## Anti-Patterns to Avoid

When building voice profiles, watch for these failure modes:

- **The Frankenstein Voice:** stitching together traits from 5 admired brands without integration. Result is incoherent.
- **The Aspiration-Only Voice:** all "we want to sound like Stripe" with no anchor in actual identity. Result is imitation.
- **The Generic Voice:** "professional, friendly, approachable" describes 90% of brands. Force specificity.
- **The Unenforceable Voice:** all vibes, no mechanical rules. Result: voice drifts within weeks.
- **The Single-Channel Voice:** profile only works for one format (e.g. emails) and breaks on social or long-form. Test across channels.
- **The Personal-vs-Brand Confusion:** founder voice and brand voice need separate profiles when they're not the same person speaking. Define which is which up front.

---

## The Test

A good Voice Profile produces these results:

1. The user reads it and says "yes, that's it" without hedging
2. A second writer (human or AI) can produce content from it that the user accepts on first draft
3. Anti-aspiration sample phrases feel genuinely wrong, not just stylistically different
4. Mechanical rules are sharp enough to catch violations automatically
5. The profile gets used. (If it sits in a drive unused, the format failed.)
