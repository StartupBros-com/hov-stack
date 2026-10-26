#!/usr/bin/env node
/**
 * shape-rewrite reach-check helpers: word-object accessors, the
 * interp-carve-out heredoc-body denylist scan, and the `gh` verb
 * classification family.
 *
 * Split out of hooks/PreToolUse/shape-rewrite.js (ce-code-review
 * round on 2b279d2, finding #8: the hook file grew 1014 -> 1363 lines
 * across four new detection families landed in one file). These three
 * groups were chosen because each is a self-contained pure-function family
 * with no dependency on the rest of the reach-check engine (segment
 * walking, wrapper stripping, the per-shape carve-outs in `reachesWithin`)
 * beyond the plain `word = { parts: [...] }` object shape itself -- moving
 * anything more (the carve-outs, `reachesWithin` itself) would require
 * pulling most of the engine along with it, which is not a "modest split."
 * Every symbol used outside this file is re-exported below; nothing here
 * changes behavior, only location.
 */

'use strict';

function wordLiteralText(word) {
  return word.parts.filter((p) => p.type === 'text').map((p) => p.value).join('');
}
function wordHasDynamic(word) {
  return word.parts.some((p) => p.type !== 'text');
}
function wordDynamicPayloads(word) {
  return word.parts.filter((p) => p.type !== 'text').map((p) => p.payload);
}

/**
 * Normalizes a `reachWords()`-style word array into the `{ literal,
 * dynamic }` token shape `hasNonFlagOperand` (below) and
 * `isInterpStdinArgShape` (shape-rewrite.js) share. A non-word entry (an
 * operator token that slipped through a filter upstream) or a word carrying
 * dynamic content ($()/backtick/process-substitution) both become
 * `{ literal: null, dynamic: true }` -- indistinguishable to a predicate
 * that only ever asks "is this token unresolvable," the same treatment
 * every other reach-check already gives an unresolved argument.
 *
 * F3 (adversarial review of PR #1295 round 6): shape-rewrite.js computed
 * this exact mapping inline at three separate call sites (one of which fed
 * `isInterpStdinArgShape`, the other two feeding the `hasNonFlagOperand`
 * predicate below); extracted here alongside it so neither half of the
 * "normalize, then ask is there a real operand" pair is duplicated.
 */
function toLiteralTokens(words) {
  return words.map((w) => (w.type === 'word' && !wordHasDynamic(w)
    ? { literal: wordLiteralText(w), dynamic: false }
    : { literal: null, dynamic: true }));
}

/**
 * F3 (adversarial review of PR #1295 round 6): "is there a real, distinct,
 * non-flag operand" -- STDIN_ALIAS_PATHS-aware (round 5 finding #2, a path
 * that merely renames the same piped stdin is not a genuine distinct
 * operand) -- was written three times over three call sites in
 * shape-rewrite.js (hasBareExecShape, and reachesWithin's own
 * INLINE_INTERPRETERS and SHELLS piped-stdin branches), rather than one
 * shared predicate, despite the identical class of duplication already
 * having been fixed once in this same PR (round 3 finding #12's
 * `isInterpStdinArgShape`, round 3 finding #8's split of this file).
 * `stdinAliasPaths` is a parameter, not a module-scoped import, so this
 * stays a pure function with no dependency on shape-rewrite.js's own
 * constants -- consistent with this file's stated design (see header
 * comment: "a self-contained pure-function family").
 */
function hasNonFlagOperand(tokens, stdinAliasPaths) {
  return tokens.some((t) => !t.dynamic && !t.literal.startsWith('-') && !stdinAliasPaths.has(t.literal));
}

// F1 (adversarial review of PR #1295 round 6): the heredoc-body denylist
// family that used to live here (HEREDOC_BODY_LITERAL_DENY,
// HEREDOC_BODY_DENY_PATH_PREFIXES, normalizeHeredocPathToken,
// heredocBodyHasOutsidePath, heredocBodyReaches) gated an interp carve-out
// in shape-rewrite.js's reachesWithin() that is now reverted outright: a
// denylist/pattern scan over a Turing-complete language's raw source text
// cannot be made sound against composed or computed constructions (proven
// live against 682831d -- chr()-built path strings and a
// getattr(os, 'sys'+'tem') dynamic dispatch both evaded every entry on the
// list with zero denylisted literal ever appearing in the source text).
// With the carve-out gone, this family had no remaining caller and was
// removed rather than left as dead code claiming to gate a mechanism that
// no longer exists. See git history at or before this commit for the full
// implementation and its round-1/2/3 rationale (parity argument,
// network-egress and path-normalization scope, and the disclosed
// tripwire-not-containment limit that round 6 ultimately confirmed as
// exploitable rather than merely residual).
// gh-read no-path: `gh` read verbs whose generic arguments never build a path
// (a $var in `gh pr view $n`, a `--jq` string with `\(...)`). Pairs are
// `<noun>:<verb>`; `api`/`search`/`auth status` are handled separately below
// since they do not fit the noun:verb shape (or, for `api`, need an extra
// write-flag check). Any verb NOT listed here (checkout, clone, download,
// create, edit, comment, close, merge, delete, review, ready, sync, fork)
// keeps today's behavior by simply never matching -- the default (not
// exempted) is the safe direction.
const GH_READ_VERB_PAIRS = new Set([
  'pr:view', 'pr:list', 'pr:checks', 'pr:diff', 'pr:status',
  'issue:view', 'issue:list', 'issue:status',
  'run:list', 'run:view', 'run:watch',
  'repo:view',
  'release:list', 'release:view',
  'label:list',
  'workflow:list', 'workflow:view',
]);
const GH_API_WRITE_FLAGS = new Set(['-f', '-F', '--field', '--raw-field', '--input', '--body-file']);

// Finding #2 (adversarial review of PR #1295 round 3): a whole-word bare
// shell-variable reference (`$FLAG`, `${FLAG}`) as a `gh api` argument. This
// codebase's own tokenizer (`reachWords()`) never turns a plain `$VAR` into a
// dynamic `sub` part -- only `$( )`, backticks, `<( )`, `>( )` do -- so such
// a word reads as ordinary literal text "$FLAG" to `litAt()` below, matches
// none of the fixed flag patterns, and silently passed as an inert argument.
// At runtime an unquoted `$FLAG` undergoes ordinary word-splitting, so it can
// resolve to `-f body=...`, `-X DELETE`, or any other write-shaped flag the
// static scan below can never see coming -- unlike a bare `$var` embedded
// INSIDE a larger literal (`repos/.../$n`), which the gh-read no-path
// feature deliberately keeps exempt (that variable's expansion lands inside
// one path segment, not in flag position), a whole-word bare variable IS the
// argument in flag position and must fail closed.
const GH_BARE_VAR_WORD_RE = /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/;

/** Is this literal `gh api ...` invocation free of every write-shaped flag? */
function ghApiIsReadOnly(core) {
  const litAt = (k) => (core[k] && core[k].type === 'word' && !wordHasDynamic(core[k]) ? wordLiteralText(core[k]) : null);
  for (let k = 1; k < core.length; k += 1) {
    const w = core[k];
    // Any word carrying dynamic content ($( ), backticks, <( ), >( )) in
    // flag-scanning position is unresolvable at static-analysis time and
    // could expand to anything, including a write flag glued or bare
    // (`--$(echo field)=x`, `-$(echo X) PATCH`) -- fail closed on the whole
    // gh api call rather than silently skipping the word, the same
    // rationale GH_BARE_VAR_WORD_RE already applies to a bare `$VAR`/`${VAR}`
    // word (which reachWords() never tags as dynamic, so it needs its own
    // check below). This generalizes that one-syntax special case to the
    // full unresolvable-argument surface.
    if (w && w.type === 'word' && wordHasDynamic(w)) return false;
    const b1 = litAt(k);
    if (b1 === null) continue;
    if (GH_BARE_VAR_WORD_RE.test(b1)) return false;
    if (GH_API_WRITE_FLAGS.has(b1)) return false;
    // Glued long-flag form: gh (cobra/pflag) accepts `--flag=value` identically
    // to `--flag value` for every long flag in GH_API_WRITE_FLAGS -- checked
    // generically here rather than one hardcoded `startsWith` per flag, so a
    // future addition to the set stays covered: `--input=payload.json` would
    // otherwise be missed because only the exact-token and
    // `--field=`/`--raw-field=` forms were checked.
    let gluedWrite = false;
    for (const flag of GH_API_WRITE_FLAGS) {
      if (flag.startsWith('--') && b1.startsWith(`${flag}=`)) { gluedWrite = true; break; }
    }
    if (gluedWrite) return false;
    if (/^(-f|-F)./.test(b1)) return false; // a glued short-flag form: fail closed
    if (b1 === '-X' || b1 === '--method') {
      const val = litAt(k + 1);
      if (val === null || val.toUpperCase() !== 'GET') return false;
    } else if (b1.startsWith('--method=')) {
      if (b1.slice('--method='.length).toUpperCase() !== 'GET') return false;
    } else if (/^-X./.test(b1)) {
      if (b1.slice(2).toUpperCase() !== 'GET') return false;
    }
  }
  return true;
}

// gh global flags that take a value and can sit before the subcommand
// (`gh --repo owner/repo pr view 1`, `gh -R owner/repo issue list`). Each
// consumes exactly one following token UNLESS glued (`--repo=owner/repo`,
// `-Rowner/repo`), which stays a single token and is skipped alone. This is
// gh's own small, stable global-flag set -- not every possible flag a wrapper
// might invent -- so an unrecognised `-`-prefixed token before the
// subcommand is skipped as a bare flag with no assumed value; ending the
// skip on a token that fails to resolve at all (a dynamic/unresolvable word)
// leaves that word as the (unrecognised, therefore write-shaped) subcommand
// candidate, which is the safe direction.
const GH_GLOBAL_FLAGS_WITH_VALUE = new Set(['--repo', '-R', '--hostname']);

/**
 * Reads the `gh` subcommand from a FIXED position -- the first one or two
 * bare (non-flag) words after skipping the leading run of global flags --
 * instead of scanning every adjacent literal pair in the argument list for a
 * match. The unbounded scan let a WRITE verb whose ARGUMENT VALUES happened
 * to contain read-verb tokens read as a no-path read: `gh issue edit $n
 * --title search` matched the bare literal "search" sitting in a `--title`
 * value, and `gh issue edit $n --body pr view` matched the adjacent pair
 * "pr view" sitting in a `--body` value. Anchoring to this one fixed
 * position closes both: `api`
 * and `search` are recognised only when they land exactly here, never
 * elsewhere in the call.
 */
function ghSubcommandPosition(core) {
  const litAt = (k) => (core[k] && core[k].type === 'word' && !wordHasDynamic(core[k]) ? wordLiteralText(core[k]) : null);
  let i = 1;
  while (i < core.length) {
    const t = litAt(i);
    if (t === null || !t.startsWith('-')) break;
    i += GH_GLOBAL_FLAGS_WITH_VALUE.has(t) ? 2 : 1;
  }
  return { b1: litAt(i), b2: litAt(i + 1) };
}

/**
 * Is this `gh` call (`core[0]` already known to be "gh") one of the
 * read-only verb shapes from gh-read no-path? Reads the subcommand from the
 * fixed, global-flag-skipped position (ghSubcommandPosition) rather than
 * scanning the whole argument list. Fails closed: anything not positively
 * recognised at that position, or `api` with a write-shaped flag, is NOT
 * exempted (today's behavior).
 */
function ghNoPathSegment(core) {
  const { b1, b2 } = ghSubcommandPosition(core);
  if (b1 === null) return false;
  if (b1 === 'api') return ghApiIsReadOnly(core);
  if (b1 === 'search') return true;
  if (b1 === 'auth' && b2 === 'status') return true;
  return GH_READ_VERB_PAIRS.has(`${b1}:${b2}`);
}

/**
 * Should this `gh` call be treated as reaching outright, from its verb
 * alone -- independent of whether any argument is a path or an unresolved
 * variable? This is the fail-closed counterpart to ghNoPathSegment() (findings
 * #3/#6, adversarial review of PR #1295 round 3). Before this function, the
 * ONLY unconditional-reach gh verbs were a two-line hardcoded literal check
 * for exactly `pr checkout` and `repo clone`/`repo sync` in the caller;
 * everything else fell through to the generic per-argument scan, which only
 * flags a call that also carries an unresolved variable -- so any OTHER
 * write verb invoked with purely literal arguments (`gh co 123`, gh's own
 * built-in alias for `pr checkout`; `gh issue delete 5`; an interposed
 * unrecognized global flag shifting the subcommand anchor) read as safe to
 * rewrite-and-execute. That contradicted this hook's own doctrine doc
 * ("an unrecognized verb/flag combination ... is treated as write-shaped
 * (reaching), never assumed safe") and was exactly the kind of hardcoded
 * allowlist the next alias defeats.
 *
 * `api`/`search`/`auth status` are excluded here and keep their existing,
 * separately-nuanced dispatch (ghNoPathSegment + the generic argument scan):
 * a fully-static, no-variable `gh api ... -f k=v` write call staying
 * non-reaching is long-standing, deliberate, pre-#1273 behavior (everything
 * in that call is exactly what was statically reviewed; only an unresolved
 * argument makes its effect unpredictable) and is not part of the alias/
 * unrecognized-verb bug this function closes. Every OTHER noun:verb pair --
 * including a `b1` of `null`, when the subcommand position itself could not
 * be resolved at all -- is judged the same way the doc has always claimed:
 * not positively recognized as a read shape (GH_READ_VERB_PAIRS) means
 * write-shaped, unconditionally. This subsumes (and replaces) the old
 * hardcoded `pr:checkout`/`repo:clone`/`repo:sync` pair check, since neither
 * pair is a GH_READ_VERB_PAIRS member either.
 */
function ghReachesOutright(core) {
  const { b1, b2 } = ghSubcommandPosition(core);
  if (b1 === 'api' || b1 === 'search') return false;
  if (b1 === 'auth' && b2 === 'status') return false;
  return !GH_READ_VERB_PAIRS.has(`${b1}:${b2}`);
}

module.exports = {
  wordLiteralText,
  wordHasDynamic,
  wordDynamicPayloads,
  toLiteralTokens,
  hasNonFlagOperand,
  GH_READ_VERB_PAIRS,
  GH_API_WRITE_FLAGS,
  GH_GLOBAL_FLAGS_WITH_VALUE,
  ghApiIsReadOnly,
  ghSubcommandPosition,
  ghNoPathSegment,
  ghReachesOutright,
};
