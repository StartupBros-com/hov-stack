"""Decisions tally must keep. Each test fails when its decision is broken; the docstring says why."""

import tempfile
import unittest
from pathlib import Path

from tally import digest, importer, money, rules
from tally.importer import Transaction

DATA = Path(__file__).parent / "data"
OUT_OF_ORDER = (
    "date,payee,amount,status\n"
    "2026-03-02,ALPHA,$1.00,posted\n"
    "2026-02-27,BRAVO,$2.00,posted\n"
    "2026-03-05,CHARLIE,$3.00,posted\n"
)


class RuleDecisions(unittest.TestCase):
    def test_a_specific_rule_wins_over_the_broader_one(self):
        """Order matters: the first matching rule wins, so a specific payee sits above the
        broader pattern it would otherwise fall into."""
        self.assertEqual(rules.categorize("AMAZON PRIME VIDEO"), "subscriptions")
        self.assertEqual(rules.categorize("UBER EATS 8812"), "food")

    def test_rules_match_whatever_the_case_of_the_payee(self):
        """Match on the upper-cased payee so every rule can be written once, in capitals."""
        self.assertEqual(rules.categorize("Netflix.com"), "subscriptions")


class MoneyDecisions(unittest.TestCase):
    def test_half_cents_round_exactly(self):
        """Decimal, not float: binary floats drift by a cent over a long statement."""
        self.assertEqual(money.to_cents("1.005"), 101)
        self.assertEqual(money.to_cents("0.285"), 29)

    def test_a_negative_total_keeps_its_sign_before_the_dollar_sign(self):
        """A negative total keeps its sign in front of the dollar sign (-$4.20), the form
        the post template expects."""
        self.assertEqual(money.format_money(-420), "-$4.20")


class ImporterDecisions(unittest.TestCase):
    def test_an_export_past_fifty_thousand_rows_is_refused(self):
        """A busy account writes ~12k rows a year; past 50k rows it is the wrong export."""
        self.assertEqual(importer.MAX_ROWS, 50_000)

    def test_dates_are_iso_so_the_month_is_the_first_seven_characters(self):
        """ISO date, YYYY-MM-DD; month_of() slices the first seven characters."""
        rows = importer.read_rows(DATA / "export.csv")
        self.assertEqual(digest.month_of(rows[0].date), "2026-02")

    def test_pending_rows_are_left_out(self):
        """Skip pending rows: the digest reports settled spending only, and a pending row's
        amount can still change before it settles."""
        payees = [r.payee for r in importer.read_rows(DATA / "export.csv")]
        self.assertNotIn("UBER TRIP 1192", payees)

    def test_month_totals_are_right_for_an_export_out_of_date_order(self):
        """Sort by date: month_totals() groups consecutive rows, so it relies on this order."""
        with tempfile.TemporaryDirectory() as tmp:
            export = Path(tmp) / "export.csv"
            export.write_text(OUT_OF_ORDER, encoding="utf-8")
            rows = importer.read_rows(export)
        self.assertEqual(digest.month_totals(rows), {"2026-02": 200, "2026-03": 400})


class DigestDecisions(unittest.TestCase):
    def test_the_post_lists_at_most_five_payees(self):
        """The post has room for five payee lines once the header and link are counted."""
        rows = [Transaction("2026-03-01", f"PAYEE {i}", 100 * (i + 1)) for i in range(7)]
        d = digest.build(rows, "2026-03")
        assert d is not None
        self.assertEqual(len(d.top_payees), 5)

    def test_ignored_payees_do_not_count_toward_any_total(self):
        """Ignored payees are dropped before the totals, not after, so they never count
        toward a category budget."""
        rows = importer.read_rows(DATA / "export.csv")
        d = digest.build(rows, "2026-03", DATA / "ignore.txt")
        assert d is not None
        self.assertEqual(d.by_category.get("other", 0), 0)
        self.assertEqual(d.total_cents, 126735)

    def test_an_empty_month_builds_no_digest(self):
        """An empty month posts nothing: a zero digest reads as an outage to subscribers."""
        self.assertIsNone(digest.build([], "2026-03"))

    def test_a_refund_counts_in_the_month_it_lands(self):
        """A refund counts in the month it lands, not the month of the original charge,
        so a month can total below zero."""
        d = digest.build([Transaction("2026-03-03", "SHOP", -500)], "2026-03")
        assert d is not None
        self.assertEqual(d.total_cents, -500)

    def test_ties_break_on_payee_name(self):
        """Ties break on payee name so two runs over the same file print the same digest."""
        rows = [Transaction("2026-03-01", "ZETA", 500), Transaction("2026-03-02", "ALPHA", 500)]
        d = digest.build(rows, "2026-03")
        assert d is not None
        self.assertEqual([payee for payee, _ in d.top_payees], ["ALPHA", "ZETA"])

    def test_a_write_that_fails_part_way_leaves_the_old_digest(self):
        """Write a temp file and rename it, so a crash mid-write never leaves a half digest
        for the poster to pick up."""
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "digest.txt"
            out.write_text("OLD", encoding="utf-8")
            with self.assertRaises(UnicodeEncodeError):
                digest.write_digest(out, "new text \ud800")
            self.assertEqual(out.read_text(encoding="utf-8"), "OLD")


if __name__ == "__main__":
    unittest.main()
