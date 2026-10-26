#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

from wf_pin_test_support import WF, _req, run_auditor, schema_lines, write_workflow, lines_of

class FanoutScopeTests(unittest.TestCase):
    def test_capped_sibling_does_not_vouch_for_uncapped_call(self):
        """The regression: one .slice() anywhere used to silence the whole file."""
        source = (
            "const a = await parallel(items.slice(0, 8).map(x => () => agent(x)))\n"
            "const b = await parallel(others.map(x => () => agent(x)))\n"
        )
        self.assertEqual(lines_of(source), [2])

    def test_capped_call_alone_is_clean(self):
        source = "const a = await parallel(items.slice(0, 8).map(x => () => agent(x)))\n"
        self.assertEqual(lines_of(source), [])

    def test_named_const_cap_is_clean(self):
        source = (
            "const MAX_VERIFY = 8\n"
            "const a = await parallel(items.slice(0, MAX_VERIFY).map(x => () => agent(x)))\n"
        )
        self.assertEqual(lines_of(source), [])

    def test_rebindable_named_cap_is_flagged(self):
        source = (
            "let max = 8\n"
            "const a = await parallel(items.slice(0, max).map(x => () => agent(x)))\n"
        )
        self.assertEqual(lines_of(source), [2])

    def test_uncapped_call_alone_is_flagged(self):
        source = "const a = await parallel(items.map(x => () => agent(x)))\n"
        self.assertEqual(lines_of(source), [1])

    def test_both_uncapped_calls_are_reported(self):
        source = (
            "const a = await parallel(items.map(x => () => agent(x)))\n"
            "const b = await pipeline(others.map(x => () => agent(x)))\n"
        )
        self.assertEqual(lines_of(source), [1, 2])

    def test_unrelated_slice_elsewhere_does_not_silence(self):
        """A .slice() outside the fan-out call must not count as its cap."""
        source = (
            "const head = title.slice(0, 40)\n"
            "const a = await parallel(items.map(x => () => agent(x)))\n"
        )
        self.assertEqual(lines_of(source), [2])

    def test_slice_in_a_string_literal_is_not_a_cap(self):
        source = 'const a = await parallel(items.map(x => () => agent("use .slice( here")))\n'
        self.assertEqual(lines_of(source), [1])

    def test_fanout_without_map_is_not_flagged(self):
        """parallel() over a literal thunk list has no data-driven fan-out to cap."""
        source = "const a = await parallel([() => agent('one'), () => agent('two')])\n"
        self.assertEqual(lines_of(source), [])

    def test_nested_inner_uncapped_outer_has_no_own_map(self):
        """pipeline() whose own args hold no .map( is clean; the inner one is not."""
        source = (
            "const r = await pipeline(\n"
            "  dims,\n"
            "  d => agent(d),\n"
            "  rev => parallel(rev.findings.map(f => () => agent(f)))\n"
            ")\n"
        )
        self.assertEqual(lines_of(source), [4])

    def test_nested_inner_cap_does_not_vouch_for_outer(self):
        """The same bug one scope down: a child's .slice( must not silence its parent."""
        source = (
            "const r = await parallel(\n"
            "  producers.map(x => () => parallel(x.items.slice(0, 8).map(y => () => agent(y))))\n"
            ")\n"
        )
        self.assertEqual(lines_of(source), [1])

    def test_nested_outer_cap_does_not_vouch_for_inner(self):
        """And the reverse: a parent's .slice( must not silence its child."""
        source = (
            "const r = await pipeline(\n"
            "  dims.slice(0, 5),\n"
            "  d => agent(d),\n"
            "  rev => parallel(rev.findings.map(f => () => agent(f)))\n"
            ")\n"
        )
        self.assertEqual(lines_of(source), [4])

    def test_both_nested_uncapped_are_reported_independently(self):
        source = (
            "const r = await parallel(\n"
            "  producers.map(x => () => parallel(x.items.map(y => () => agent(y))))\n"
            ")\n"
        )
        self.assertEqual(lines_of(source), [1, 2])

    def test_multiline_capped_call_is_clean(self):
        source = (
            "const a = await parallel(\n"
            "  items\n"
            "    .slice(0, 8)\n"
            "    .map(x => () => agent(x))\n"
            ")\n"
        )
        self.assertEqual(lines_of(source), [])


class MapReceiverCapScopeTests(unittest.TestCase):
    """#1304: uncapped_fanouts()'s substring check let a per-item .slice()
    ANYWHERE in the fan-out's own text vouch for a .map( it was never
    chained onto. MAP_RECEIVER_RE scopes the cap check to the receiver
    immediately, syntactically adjacent to .map(/.flatMap(."""

    def test_per_item_slice_inside_map_callback_is_not_a_cap(self):
        """PLANTED NEGATIVE: the exact P1-A fixture (fanout-admission.test.js
        591-604) ported to parallel()/.map() shape. The per-item
        `.slice(0, 200)` prompt truncation on `x.description` is not chained
        onto `items.list.map(`, so the fan-out itself is genuinely uncapped."""
        source = (
            "const checked = await parallel(items.list.map(x => () => "
            "agent('check: ' + x.description.slice(0, 200), {model: 'sonnet'})))\n"
        )
        self.assertEqual(lines_of(source), [1])

    def test_receiver_chained_slice_is_still_a_cap(self):
        """Regression guard: the scoped fix must not over-flag the ordinary
        capped shape it is meant to leave alone."""
        source = "const a = await parallel(items.slice(0, 8).map(x => () => agent(x)))\n"
        self.assertEqual(lines_of(source), [])


class UnresolvableReceiverFailsClosedTests(unittest.TestCase):
    """Round 8 (issue #1351, adversarial review of #1309/#1304) finding 1
    (P1): MAP_RECEIVER_RE requires a bare identifier (optionally
    `.prop`-chained) immediately before `.map(`/`.flatMap(`, so it never
    matches at all for a call-expression or non-chain receiver. The old
    check -- `any(m.group(3) is None for m in MAP_RECEIVER_RE.finditer(text))`
    -- then sees zero matches and `any()` over an empty iterable is False: a
    genuinely uncapped fan-out read clean (fail OPEN). Every `.map(`/
    `.flatMap(` occurrence is now checked individually; an unresolvable
    receiver counts as uncapped, same as fanout-admission.js's
    scopedMapCap() (`count == null`) doctrine."""

    def test_call_expression_receiver_is_unresolvable_and_flagged(self):
        """PLANTED NEGATIVE: main's substring check flagged this; the
        unfixed lexer port's MAP_RECEIVER_RE never matches `getItems()` and
        read it clean."""
        source = "const a = await parallel(getItems().map(x => () => agent(x)))\n"
        self.assertEqual(lines_of(source), [1])

    def test_filter_then_map_receiver_is_unresolvable_and_flagged(self):
        """PLANTED NEGATIVE: same gap -- `.filter(...)` breaks the identifier
        chain immediately before `.map(`."""
        source = (
            "const a = await parallel(items.filter(x => x.ok).map(x => () => agent(x)))\n"
        )
        self.assertEqual(lines_of(source), [1])

    def test_parenthesized_await_receiver_is_unresolvable_and_flagged(self):
        """PLANTED NEGATIVE: same gap -- a parenthesized expression receiver."""
        source = "const a = await parallel((await fetchAll()).map(x => () => agent(x)))\n"
        self.assertEqual(lines_of(source), [1])

    def test_plain_slice_capped_receiver_is_still_clean(self):
        """Control: an ordinary resolvable, capped receiver must stay clean."""
        source = "const a = await parallel(items.slice(0, 8).map(x => () => agent(x)))\n"
        self.assertEqual(lines_of(source), [])

    def test_p1_a_fixture_still_flagged(self):
        """The existing #1304 planted negative (a resolvable receiver with
        no chained cap) must still be caught after this round's fix -- an
        unresolvable-receiver check must not mask a resolvable-but-uncapped
        one, or vice versa."""
        source = (
            "const checked = await parallel(items.list.map(x => () => "
            "agent('check: ' + x.description.slice(0, 200), {model: 'sonnet'})))\n"
        )
        self.assertEqual(lines_of(source), [1])


class SharedReceiverResolutionTests(unittest.TestCase):
    """Round 9 (#1351 second adversarial pass), findings P2-A and P2-B:
    uncapped_fanouts() now delegates to fanout-admission.js's own
    ownText()/scopedMapCap() instead of a second, independently-drifting
    port of the same logic (see uncapped_fanouts()'s own doc comment)."""

    def test_unrelated_inner_map_in_prompt_builder_is_not_the_fanouts_own_map(self):
        """PLANTED NEGATIVE (P2-A): the old port required EVERY `.map(` in
        the fan-out's own text to resolve a cap, so the unrelated
        `extraTags.map(...)` inside the prompt-builder argument false-WARNed
        a fan-out whose OWN `.map(` (on `uniqueIds`) is genuinely capped by
        `.slice(0, 8)`. main read this clean; verified directly against
        fanout-admission.js's uncappedFanouts() before this fix landed."""
        source = (
            "parallel(uniqueIds.slice(0, 8).map(id => () => "
            "agent(buildPrompt(id, extraTags.map(t => t.name)), {model: 'sonnet'})))\n"
        )
        self.assertEqual(lines_of(source), [])

    def test_call_expression_receiver_with_its_own_slice_still_warns(self):
        """P2-B fixture 1: `getItems().slice(0, 20).map(...)` reads clean
        under a bare "is .slice( anywhere" substring check (what main did),
        but MAP_RECEIVER_RE -- both the old Python port's and the hook's own
        scopedMapCap() -- requires a bare identifier immediately before
        `.map(`, so a call-expression receiver still cannot resolve a cap
        here. This asserts the shared hook's CURRENT WARN, not a fix: it
        gates live spawns and has its own adversarial history, so this PR
        does not change its receiver resolution. A follow-up to teach it to
        resolve a call-expression receiver's own chained `.slice(` belongs
        in scopedMapCap() itself, for both consumers at once."""
        source = "parallel(getItems().slice(0, 20).map(x => agent(x)))\n"
        self.assertEqual(lines_of(source), [1])

    def test_filter_interposed_receiver_with_its_own_slice_still_warns(self):
        """P2-B fixture 2: same gap, a `.filter(...)` interposed between a
        resolvable identifier and `.map(` breaks the immediately-adjacent
        receiver chain MAP_RECEIVER_RE requires. Same doctrine as above:
        asserts the hook's current WARN, not a fix."""
        source = "parallel(items.slice(0, 20).filter(x => x.ok).map(x => agent(x)))\n"
        self.assertEqual(lines_of(source), [1])


class SchemaCommentAwareCountingTests(unittest.TestCase):
    """Round 8 (#1351) finding 2 (P2): overdemanding_schemas() counted
    required-array entries with STRING_RE over raw text, the same
    comment-blind gap #1309 fixed everywhere else -- an apostrophe inside an
    inline `//` comment flips quote parity and the regex reads past the real
    closing quote into the next real entry. Counting on lexical_spans()
    instead (falling back to STRING_RE only when the segment fails to lex)
    fixes it at this call site too."""

    def test_apostrophe_comments_do_not_inflate_the_count(self):
        """PLANTED NEGATIVE: this exact 8-entry array with two inline
        apostrophe comments counted 9 before the fix (verified against the
        pre-fix STRING_RE-over-raw-text path)."""
        source = (
            "const S = {type: 'object', required: [\n"
            "  'a', 'b', 'c', 'd', // don't skip\n"
            "  'e', 'f', 'g', // can't skip either\n"
            "  'h'\n"
            "], properties: {}}\n"
        )
        self.assertEqual(schema_lines(source), [(1, 8, WF.REQUIRED_LIMIT)])

    def test_dropping_to_seven_entries_does_not_warn(self):
        """The count driving the WARN decision must be the real, lexed
        count: one fewer real entry (still carrying both comments) must
        drop below REQUIRED_LIMIT and stop warning."""
        source = (
            "const S = {type: 'object', required: [\n"
            "  'a', 'b', 'c', // don't skip\n"
            "  'e', 'f', 'g', // can't skip either\n"
            "  'h'\n"
            "], properties: {}}\n"
        )
        self.assertEqual(schema_lines(source), [])


class CommentTextBlankingTests(unittest.TestCase):
    """Round 8 (#1351) finding 3 (P2): blank_strings() blanked only
    `kind == "string"` spans, leaving comment TEXT visible in the stripped
    view -- a comment mentioning `.map(` or `agent(` then read as real code
    to every downstream caller. fanout-admission.js's blankStrings() blanks
    both strings and comments (keeping a comment's newlines so line numbers
    still hold); blank_strings() and blank_strings_keep_schema_keys() now do
    the same."""

    def test_comment_mentioning_map_does_not_flag_a_capped_fanout(self):
        """PLANTED NEGATIVE: main did not flag this shape; the unfixed
        lexer port did, because the comment's `legacy.map(x => x)` survived
        blanking as a second, receiver-resolvable-but-uncapped `.map(` in
        the same fan-out's own text."""
        source = (
            "await parallel(\n"
            " // see also: legacy.map(x => x) for the old approach\n"
            " capped.slice(0, 10).map(x => () => agent(x))\n"
            ")\n"
        )
        self.assertEqual(lines_of(source), [])

    def test_comment_mentioning_agent_call_is_not_a_phantom_call(self):
        """A comment naming `agent('x')` must not create a second call_spans()
        hit alongside the one real, pinned call below it."""
        source = (
            "// agent('x') is the old shape, not called here\n"
            "await agent('y', {model: 'sonnet'})\n"
        )
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 1)

    def test_comment_newline_is_preserved_so_line_numbers_hold(self):
        """A blanked comment must keep its own newline -- otherwise every
        line number computed against the stripped text (not just the
        original) after it shifts by one per comment."""
        source = "// a comment\nawait agent('y')\n"
        stripped = WF.blank_strings(source)
        self.assertEqual(stripped.count("\n"), source.count("\n"))
        call_start = list(WF.call_spans(stripped))[0][0]
        self.assertEqual(source.count("\n", 0, call_start) + 1, 2)


class NoRegressionAcrossRoundsTests(unittest.TestCase):
    """Nothing from the earlier rounds (#1309, #1304) moves backwards under
    this round's three fixes (unresolvable-receiver fail-closed, lexed
    schema-breadth count, comment blanking)."""

    def test_1309_apostrophe_fixture_still_reports_one_fanout_two_calls(self):
        source = "// don't forget: this list is unbounded\n" + CommentAwareQuoteParityTests.ISSUE_BODY
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 2)
        self.assertEqual(len(WF.uncapped_fanouts(stripped)), 1)

    def test_url_in_string_negative_still_holds(self):
        source = "const u = 'http://example.com/path'\nawait agent('work', {model: 'sonnet'})\n"
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 1)

    def test_unterminated_input_is_reported_via_lex_error_not_a_silent_fallback(self):
        """Finding #1 (PR #1352 round 7): the auditor now fails closed on an
        unlexable script instead of falling back to a comment-blind regex
        scan. lex_error() is the one function safe to call on an unlexable
        text directly; lexical_spans()/blank_strings() assume the caller
        already checked it and raise instead of silently degrading."""
        source = "const a = 'never closes\nawait agent('x', {model: 'sonnet'})\n"
        error = WF.lex_error(source)
        self.assertIsNotNone(error)
        self.assertTrue(error.startswith("unlexable"))
        with self.assertRaises(RuntimeError):
            WF.lexical_spans(source)
        with self.assertRaises(RuntimeError):
            WF.blank_strings(source)


class TemplateAndRegexLexingTests(unittest.TestCase):
    """Round 9 (#1351 second adversarial pass), findings P1-A, P1-B, and P3:
    the hand-ported lexical_spans() had no `${...}` interpolation awareness
    and no regex-literal handling at all -- both fixed by delegating to
    fanout-admission.js's own lexCode()/blankStrings() (see
    lexical_spans()'s own doc comment)."""

    def test_apostrophe_in_nested_template_literal_does_not_hide_the_next_call(self):
        """PLANTED NEGATIVE (P1-A): the old hand-rolled scanner closed the
        OUTER backtick literal at the nested template's OWN opening
        backtick (no `${...}` awareness), leaking the apostrophe inside
        `it's the label` to open a bogus single-quoted string that ran to
        EOF and swallowed `agent(` itself -- call_spans() returned [] and
        the audit exited 0 clean. Verified directly: the unfixed
        lexical_spans()-based scan finds 0 agent() calls here; the
        hook-backed one finds 1."""
        source = (
            "const label = `outer ${`it's the label`} done`;\n"
            "agent('unpinned call');\n"
        )
        stripped = WF.blank_strings(source)
        calls = list(WF.call_spans(stripped))
        self.assertEqual(len(calls), 1)
        self.assertTrue(WF.is_unpinned(stripped[calls[0][0]:calls[0][1]]))

    def test_regex_containing_slash_star_is_not_a_block_comment_open(self):
        """PLANTED NEGATIVE (P1-B): the old scanner treated the `/*` inside
        `/[/*]/ ` as a block-comment open with no regex-literal awareness,
        and swallowed everything up to the NEXT real `*/` anywhere later in
        the file -- hiding both agent() calls and the fan-out between them.
        This is a regression from main's own STRING_RE-only behavior, which
        read this fixture clean of the bug (main has no `/* */` notion at
        all, so it never misreads a regex as a comment)."""
        source = (
            "pattern.split(/[/*]/);\n"
            "agent('one');\n"
            "await parallel(items.map(x => () => agent(x)));\n"
            "const c = /* comment */ 1;\n"
        )
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 2)
        self.assertEqual(len(WF.uncapped_fanouts(stripped)), 1)

    def test_apostrophe_inside_a_regex_literal_does_not_flip_parity(self):
        """P3: a regex literal containing an apostrophe (`/don't-match/`)
        must not flip quote parity for the rest of the file. The old
        scanner had no regex notion at all, so it read the apostrophe as a
        string-open and lost the FIRST agent() call to the fallback's
        mis-pairing; the hook's regex-aware lexer reads both calls and the
        fan-out clean, matching main's own (accidentally correct, since
        main also has no regex notion but never gets this far off) count."""
        source = (
            "const re = /don't-match/;\n"
            "agent('two');\n"
            "await pipeline(others.map(x => () => agent(x)));\n"
        )
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 2)
        self.assertEqual(len(WF.uncapped_fanouts(stripped)), 1)


class CommentAwareQuoteParityTests(unittest.TestCase):
    """#1309: blank_strings() used a bare quote-matching regex with no
    comment notion, so one apostrophe inside a `//` comment flipped quote
    parity for the rest of the file and every agent() call / fan-out after
    it vanished from the audit. lexical_spans() fixes this by recognizing a
    `//`/`/* */` comment as one atomic span before any quote inside it is
    ever inspected."""

    ISSUE_BODY = (
        "const claims = await agent('produce claims')\n"
        "await parallel(claims.map(c => agent('verify: ' + c)))\n"
    )

    def test_no_leading_comment_is_unaffected(self):
        """Baseline/control: without any comment, the fixture already read
        correctly -- the fix must not change this case."""
        stripped = WF.blank_strings(self.ISSUE_BODY)
        self.assertEqual(len(list(WF.call_spans(stripped))), 2)
        self.assertEqual(len(WF.uncapped_fanouts(stripped)), 1)

    def test_apostrophe_free_comment_is_unaffected(self):
        source = "// do not forget: this list is unbounded\n" + self.ISSUE_BODY
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 2)
        self.assertEqual(len(WF.uncapped_fanouts(stripped)), 1)

    def test_line_comment_apostrophe_does_not_hide_agent_calls(self):
        """PLANTED NEGATIVE (issue's exact repro): the apostrophe in `don't`
        used to flip quote parity and swallow both the fan-out and both
        agent() calls into a spurious blanked "string"."""
        source = "// don't forget: this list is unbounded\n" + self.ISSUE_BODY
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 2)
        self.assertEqual(len(WF.uncapped_fanouts(stripped)), 1)

    def test_block_comment_apostrophe_does_not_hide_agent_calls(self):
        """Block comments share the same STRING_RE gap; the issue only shows `//`."""
        source = "/* it's a note */\n" + self.ISSUE_BODY
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 2)
        self.assertEqual(len(WF.uncapped_fanouts(stripped)), 1)

    def test_url_inside_string_is_not_mistaken_for_a_comment(self):
        """PLANTED NEGATIVE: a `//` inside a string must stay part of the
        string, not get read as a comment start (which would prove the fix
        degraded to a blanket "strip after //" instead of staying
        string-vs-comment scoped)."""
        source = "const u = 'http://example.com/path'\nawait agent('work', {model: 'sonnet'})\n"
        stripped = WF.blank_strings(source)
        self.assertEqual(len(list(WF.call_spans(stripped))), 1)

    def test_apostrophe_comment_does_not_hide_a_schema_breadth_finding(self):
        """PLANTED NEGATIVE: overdemanding_schemas() shares blank_strings_
        keep_schema_keys()'s call to the same comment-blind primitive -- an
        8-required schema behind an apostrophe comment used to drop to zero
        findings."""
        source = "// don't skip this one\nconst S = {type: 'object', required: %s, properties: {}}\n" % _req(8)
        self.assertEqual(schema_lines(source), [(2, 8, WF.REQUIRED_LIMIT)])


class LexicalSpansFailClosedTests(unittest.TestCase):
    """Finding #1 (PR #1352 round 7): a null lexCode() result inside
    wf-pin-lex.js used to fall through to a fallback blanked view with empty
    spans, so wf-pin-audit.py read an unlexable script as clean instead of
    unaudited. The shim now reports it as a per-script {"error": "unlexable:
    ..."} entry (see lex_error()'s own doc comment); lexical_spans() and
    blank_strings() raise if called on such a text without checking
    lex_error() first (a gate that cannot compare must fail), rather than
    silently degrading to a comment-blind regex scan."""

    def test_unterminated_string_is_reported_via_lex_error_and_raises_on_direct_use(self):
        source = "const a = 'never closes\nawait agent('x', {model: 'sonnet'})\n"
        error = WF.lex_error(source)
        self.assertIsNotNone(error)
        self.assertTrue(error.startswith("unlexable"))
        with self.assertRaises(RuntimeError):
            WF.lexical_spans(source)
        with self.assertRaises(RuntimeError):
            WF.blank_strings(source)

    def test_unterminated_block_comment_is_reported_via_lex_error_and_raises_on_direct_use(self):
        source = "/* never closes\nawait agent('x', {model: 'sonnet'})\n"
        error = WF.lex_error(source)
        self.assertIsNotNone(error)
        self.assertTrue(error.startswith("unlexable"))
        with self.assertRaises(RuntimeError):
            WF.lexical_spans(source)
        with self.assertRaises(RuntimeError):
            WF.blank_strings(source)

    def test_planted_negative_the_same_fixture_terminated_lexes_normally(self):
        """PLANTED NEGATIVE: closing the same string makes it lex normally --
        proves the raise above is specific to the unterminated literal, not
        some unrelated breakage in these fixtures."""
        source = "const a = 'now closes'\nawait agent('x', {model: 'sonnet'})\n"
        self.assertIsNone(WF.lex_error(source))
        self.assertIsInstance(WF.lexical_spans(source), list)
        self.assertIsInstance(WF.blank_strings(source), str)


class UnlexableScriptTests(unittest.TestCase):
    """Finding #1 (PR #1352 round 7), CLI-level: an unlexable script is
    reported unaudited (exit 4), never silently read as clean."""

    def _write(self, scripts_dir: Path, name: str, content: str) -> None:
        scripts_dir.mkdir(parents=True, exist_ok=True)
        (scripts_dir / name).write_text(content, encoding="utf-8")

    def test_unterminated_string_script_is_unaudited_not_clean(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(scripts, "bad.js", "const a = 'never closes\nawait agent('work')\n")
            result = run_auditor(home)
            self.assertEqual(result.returncode, 4)
            self.assertIn("bad.js", result.stderr)
            self.assertIn("unlexable", result.stderr)
            self.assertNotIn("wf-pin-audit: clean", result.stdout)

    def test_planted_negative_terminated_string_is_audited_and_reports_unpinned(self):
        """PLANTED NEGATIVE: closing the same string makes bad.js lex
        normally and report its genuinely unpinned agent() call (exit 1),
        proving the exit-4 case above is specific to the unlexable literal,
        not some unrelated fixture breakage."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            self._write(scripts, "bad.js", "const a = 'now closes'\nawait agent('work')\n")
            result = run_auditor(home)
            self.assertEqual(result.returncode, 1)
            self.assertIn("UNPINNED", result.stdout)
            self.assertIn("bad.js", result.stdout)


class AstralOffsetTests(unittest.TestCase):
    """Finding #2 (PR #1352 round 7): wf-pin-lex.js reports UTF-16 code-unit
    offsets (JavaScript's own string indexing), while Python indexes `text`
    by code point. An astral character (outside the Basic Multilingual
    Plane, e.g. an emoji) spends two UTF-16 units but one Python code point,
    so every offset the shim returns AFTER one used to land one character
    too far to the right once decoded here -- corrupting blank_strings()'s
    in-place slicing and silently misaligning every downstream span. See
    wf_pin_lex_client.py's _normalize_offsets()/_utf16_boundary_to_codepoint()
    doc comments for the fix."""

    def test_astral_character_before_an_uncapped_fanout_is_still_reported(self):
        source = (
            "const label = '\U0001F600 marker'\n"
            "const items = ['a', 'b']\n"
            "await parallel(items.map(x => () => agent(x)))\n"
        )
        blanked = WF.blank_strings(source)
        uncapped = WF.uncapped_fanouts(blanked)
        self.assertEqual(len(uncapped), 1)
        start, end = uncapped[0]
        expected = "parallel(items.map(x => () => agent(x)))"
        self.assertEqual(blanked[start:end], expected)
        # blank_strings() only ever overwrites already-string/comment/regex
        # span contents with spaces -- the fan-out call text itself is
        # untouched, so slicing the ORIGINAL source at the same offsets must
        # land on the exact same substring too.
        self.assertEqual(source[start:end], expected)

    def test_mutation_check_skipping_offset_normalization_loses_the_fanout(self):
        """Documents the exact failure shape a reverted #2 fix produces:
        with _normalize_offsets() disabled, the shim's raw UTF-16 offsets
        are used as Python code-point offsets directly, blank_strings()
        slices the wrong characters, and the fan-out is silently missed
        (empty list) instead of reported -- a false clean, not a crash."""
        import wf_pin_lex_client as client
        from unittest import mock

        source = (
            "const label = '\U0001F600 marker'\n"
            "const items = ['a', 'b']\n"
            "await parallel(items.map(x => () => agent(x)))\n"
        )
        # The sibling test above already primed WF's module-level
        # _LEX_CACHE with the CORRECT (normalized) result for this exact
        # text; without evicting it here, this test would silently hit
        # that cache and never exercise the mocked-out _normalize_offsets
        # at all, regardless of test execution order.
        WF._LEX_CACHE.pop(source, None)
        with mock.patch.object(client, "_normalize_offsets", lambda *a, **k: None):
            blanked = WF.blank_strings(source)
            uncapped = WF.uncapped_fanouts(blanked)
        self.assertEqual(uncapped, [])
        # Clean up: leave the correct result cached for any later test that
        # reuses this exact fixture text, rather than a mutated one.
        WF._LEX_CACHE.pop(source, None)
        WF._LEX_CACHE.pop(blanked, None)

    def test_lexical_spans_and_call_spans_agree_on_exact_substrings(self):
        """Residual risk 8: an astral character earlier in the same text
        must not shift either lexical_spans()'s (the shim's own, now
        code-point-normalized) string spans, or call_spans()'s (pure-Python
        paren counting on the resulting blanked text) call span, off their
        true code-point boundaries -- both must slice back to the exact
        original substrings."""
        source = (
            "const marker = '\U0001F600'\n"
            "const x = 'literal-marker'\n"
            "await agent('work')\n"
        )
        string_spans = [(s, e) for s, e, kind in WF.lexical_spans(source) if kind == "string"]
        self.assertEqual(len(string_spans), 3)
        self.assertEqual(source[string_spans[0][0]:string_spans[0][1]], "'\U0001F600'")
        self.assertEqual(source[string_spans[1][0]:string_spans[1][1]], "'literal-marker'")
        self.assertEqual(source[string_spans[2][0]:string_spans[2][1]], "'work'")

        blanked = WF.blank_strings(source)
        calls = list(WF.call_spans(blanked))
        self.assertEqual(len(calls), 1)
        start, end = calls[0]
        self.assertEqual(source[start:end], "agent('work')")


class PinSpanTests(unittest.TestCase):
    def test_call_spans_defaults_to_agent_calls(self):
        source = "await agent('a', {model: 'sonnet'})\nawait parallel(xs.map(f))\n"
        stripped = WF.blank_strings(source)
        spans = list(WF.call_spans(stripped))
        self.assertEqual(len(spans), 1)
        self.assertTrue(stripped[spans[0][0]:spans[0][1]].startswith("agent("))

    def test_unpinned_detection_still_works_per_call(self):
        """Guard the pre-existing pin check against regression from the refactor.

        Calls the production predicate, not a copy of it: an inlined
        `"model" not in span` here would pass even if main() regressed.
        """
        source = "await agent('a', {model: 'sonnet'})\nawait agent('b')\n"
        stripped = WF.blank_strings(source)
        unpinned = [
            source.count("\n", 0, start) + 1
            for start, end in WF.call_spans(stripped)
            if WF.is_unpinned(stripped[start:end])
        ]
        self.assertEqual(unpinned, [2])

    def test_model_lookalike_key_is_not_a_pin(self):
        """`modelName:` is not `model:` — a substring test would call this pinned."""
        self.assertTrue(WF.is_unpinned("agent('a', {modelName: 'sonnet'})"))
        self.assertFalse(WF.is_unpinned("agent('a', {model: 'sonnet'})"))
        self.assertFalse(WF.is_unpinned("agent('a', {model : 'sonnet'})"))



FRONTMATTER_TRUE = "---\nname: x\nomitClaudeMd: true\n---\nBody text.\n"
FRONTMATTER_MISSING = "---\nname: x\n---\nBody text.\n"
FRONTMATTER_FALSE = "---\nname: x\nomitClaudeMd: false\n---\nBody text.\n"
NO_FRONTMATTER = "Just a body, no frontmatter block at all.\n"


class OmitClaudeMdTests(unittest.TestCase):
    def test_true_flag_is_compliant(self):
        self.assertFalse(WF.missing_omit_claude_md(FRONTMATTER_TRUE))

    def test_missing_key_is_flagged(self):
        self.assertTrue(WF.missing_omit_claude_md(FRONTMATTER_MISSING))

    def test_false_value_is_flagged(self):
        """`omitClaudeMd: false` is not the true flag — must still be flagged."""
        self.assertTrue(WF.missing_omit_claude_md(FRONTMATTER_FALSE))

    def test_no_frontmatter_is_flagged(self):
        self.assertTrue(WF.missing_omit_claude_md(NO_FRONTMATTER))

    def test_keep_list_marker_exempts(self):
        """A file that deliberately opts out documents it with the marker sentence."""
        text = "---\nname: x\n---\n%s\n" % WF.KEEP_LIST_MARKER
        self.assertFalse(WF.missing_omit_claude_md(text))


class OmitClaudeMdCliTests(unittest.TestCase):
    def test_bad_agent_flagged_exempt_agent_is_not(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            write_workflow(home, old=True)
            agents_dir = home / "agents"
            agents_dir.mkdir()
            (agents_dir / "bad.md").write_text(
                "---\nname: bad\n---\nNo mention of the flag.\n", encoding="utf-8",
            )
            (agents_dir / "exempt.md").write_text(
                "---\nname: exempt\n---\n%s\n" % WF.KEEP_LIST_MARKER, encoding="utf-8",
            )
            result = run_auditor(home, agents_dir=agents_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("bad.md", result.stdout)
            self.assertIn("missing omitClaudeMd: true", result.stdout)
            self.assertNotIn("exempt.md", result.stdout)


if __name__ == "__main__":
    unittest.main()
