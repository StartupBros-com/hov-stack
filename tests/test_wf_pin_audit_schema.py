#!/usr/bin/env python3
"""Schema-breadth (over-demanding required: list) tests for
scripts/wf-pin-audit.py. Split out of test_wf_pin_audit.py (finding
#3, PR #1352 round 7); see wf_pin_test_support.py for the shared fixture
helpers and the WF module-under-test load."""

import tempfile
import unittest
from pathlib import Path

from wf_pin_test_support import WF, _req, run_auditor, schema_lines


class SchemaBreadthTests(unittest.TestCase):
    def test_ten_required_is_flagged(self):
        """PLANTED NEGATIVE (issue #676): ten required properties must warn."""
        source = "const S = {type: 'object', required: %s, properties: {}}\n" % _req(10)
        self.assertEqual(schema_lines(source), [(1, 10, WF.REQUIRED_LIMIT)])

    def test_three_required_is_clean(self):
        source = "const S = {type: 'object', required: %s, properties: {}}\n" % _req(3)
        self.assertEqual(schema_lines(source), [])

    def test_limit_boundary(self):
        at_limit = "const S = {type: 'object', required: %s}\n" % _req(WF.REQUIRED_LIMIT)
        over = "const S = {type: 'object', required: %s}\n" % _req(WF.REQUIRED_LIMIT + 1)
        self.assertEqual(schema_lines(at_limit), [])
        self.assertEqual(
            schema_lines(over), [(1, WF.REQUIRED_LIMIT + 1, WF.REQUIRED_LIMIT)]
        )

    def test_additional_properties_false_lowers_the_limit(self):
        source = (
            "const S = {type: 'object', additionalProperties: false, "
            "required: %s, properties: {}}\n" % _req(6)
        )
        self.assertEqual(schema_lines(source), [(1, 6, WF.STRICT_REQUIRED_LIMIT)])

    def test_six_required_without_strictness_is_clean(self):
        source = "const S = {type: 'object', required: %s}\n" % _req(6)
        self.assertEqual(schema_lines(source), [])

    def test_at_strict_limit_with_additional_properties_false_is_clean(self):
        source = (
            "const S = {type: 'object', additionalProperties: false, "
            "required: %s}\n" % _req(WF.STRICT_REQUIRED_LIMIT)
        )
        self.assertEqual(schema_lines(source), [])

    def test_nested_subschema_is_judged_on_its_own(self):
        source = (
            "const S = {type: 'object', required: ['items'], properties: {\n"
            "  items: {type: 'array', items: {type: 'object', required: %s}}\n"
            "}}\n" % _req(10)
        )
        self.assertEqual(schema_lines(source), [(2, 10, WF.REQUIRED_LIMIT)])

    def test_nested_additional_properties_does_not_tighten_the_parent(self):
        """The nesting-vouching doctrine, inverted: a child's strictness is not the parent's."""
        source = (
            "const S = {type: 'object', required: %s, properties: {\n"
            "  basis: {type: 'object', additionalProperties: false, required: ['a']}\n"
            "}}\n" % _req(6)
        )
        self.assertEqual(schema_lines(source), [])

    def test_parent_additional_properties_does_not_tighten_a_child(self):
        source = (
            "const S = {type: 'object', additionalProperties: false, required: ['x'], properties: {\n"
            "  x: {type: 'object', required: %s}\n"
            "}}\n" % _req(6)
        )
        self.assertEqual(schema_lines(source), [])

    def test_json_quoted_keys_are_seen(self):
        entries = ", ".join('"f%d"' % i for i in range(8))
        source = 'const S = {"type": "object", "required": [%s]}\n' % entries
        self.assertEqual(schema_lines(source), [(1, 8, WF.REQUIRED_LIMIT)])

    def test_minified_schema_with_strict_pairing_is_seen(self):
        source = (
            "const S={type:'object',additionalProperties:false,"
            "required:%s,properties:{}}\n" % _req(6).replace(", ", ",")
        )
        self.assertEqual(schema_lines(source), [(1, 6, WF.STRICT_REQUIRED_LIMIT)])

    def test_non_schema_required_field_is_not_flagged(self):
        """Inward-vet DEFECT 1 regression: a plain JS object naming a field
        `required` is not a StructuredOutput schema."""
        source = "const report = {ok: results.length, required: %s}\n" % _req(8)
        self.assertEqual(schema_lines(source), [])

    def test_properties_key_alone_marks_a_schema(self):
        source = "const S = {required: %s, properties: {}}\n" % _req(8)
        self.assertEqual(schema_lines(source), [(1, 8, WF.REQUIRED_LIMIT)])

    def test_unterminated_required_array_is_skipped(self):
        """Inward-vet DEFECT 2 regression: a truncated array must not swallow
        every later string in the file into its count."""
        source = (
            "const S = {type: 'object', required: ['a', 'b'\n"
            "const exts = ['txt', 'md', 'json', 'yaml', 'csv', 'log', 'ini', 'toml']\n"
        )
        self.assertEqual(schema_lines(source), [])

    def test_required_inside_a_prompt_string_is_not_a_schema(self):
        source = (
            "await agent(`Return JSON like {required: %s}`, "
            "{model: 'sonnet'})\n" % _req(10)
        )
        self.assertEqual(schema_lines(source), [])

    def test_astral_character_before_a_schema_literal_is_still_flagged(self):
        """Finding #2 (PR #1352 round 7): an astral character (e.g. an
        emoji, two UTF-16 units but one Python code point) earlier in the
        file used to shift every later shim-derived offset one code point
        to the right once decoded here, corrupting blank_strings_keep_
        schema_keys()'s in-place slicing and silently losing this finding."""
        source = (
            "const marker = '\U0001F600'\n"
            "const S = {type: 'object', required: %s, properties: {}}\n" % _req(10)
        )
        self.assertEqual(schema_lines(source), [(2, 10, WF.REQUIRED_LIMIT)])


class SchemaBreadthCliTests(unittest.TestCase):
    def test_broad_fixture_warns_and_narrow_sibling_passes(self):
        """Issue #676's fixture pair: ten-required flagged, three-required untouched."""
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            scripts = home / ".claude/projects/project/session/workflows/scripts"
            scripts.mkdir(parents=True)
            (scripts / "broad.js").write_text(
                "await agent('work', {model: 'sonnet', schema: "
                "{type: 'object', required: %s, properties: {}}})\n" % _req(10),
                encoding="utf-8",
            )
            (scripts / "narrow.js").write_text(
                "await agent('work', {model: 'sonnet', schema: "
                "{type: 'object', required: %s, properties: {}}})\n" % _req(3),
                encoding="utf-8",
            )
            result = run_auditor(home)
            self.assertEqual(result.returncode, 0)  # breadth is a soft warning
            self.assertIn("broad.js", result.stdout)
            self.assertIn("required lists 10 properties (limit 7)", result.stdout)
            self.assertNotIn("narrow.js", result.stdout)
            self.assertIn("wf-pin-audit: clean", result.stdout)


if __name__ == "__main__":
    unittest.main()
