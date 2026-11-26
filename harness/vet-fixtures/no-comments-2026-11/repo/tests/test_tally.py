import doctest
import unittest
from pathlib import Path

from tally import digest, importer, money, rules

DATA = Path(__file__).parent / "data"


def load_tests(loader, tests, ignore):
    tests.addTests(doctest.DocTestSuite(money))
    return tests


class MoneyTests(unittest.TestCase):
    def test_to_cents(self):
        self.assertEqual(money.to_cents("12.34"), 1234)

    def test_parse_amount_strips_the_dollar_sign(self):
        self.assertEqual(money.parse_amount(" $12.34 "), 1234)

    def test_format_money(self):
        self.assertEqual(money.format_money(123456), "$1,234.56")


class ImporterTests(unittest.TestCase):
    def test_read_rows_skips_pending_and_reads_big_amounts(self):
        rows = importer.read_rows(DATA / "export.csv")
        payees = [r.payee for r in rows]
        expected = ["NETFLIX.COM", "UBER EATS 8812", "AMAZON MKTPLACE", "UBER TRIP 4410", "CORNER CAFE"]
        self.assertEqual(payees, expected)
        self.assertEqual(rows[2].cents, 123450)


class RulesTests(unittest.TestCase):
    def test_categorize(self):
        self.assertEqual(rules.categorize("UBER EATS 8812"), "food")
        self.assertEqual(rules.categorize("UBER TRIP 4410"), "transport")
        self.assertEqual(rules.categorize("AMAZON MKTPLACE"), "shopping")
        self.assertEqual(rules.categorize("CORNER CAFE"), "other")

    def test_budget_for(self):
        self.assertEqual(rules.budget_for({"food": 30000}, "food"), 30000)


class DigestTests(unittest.TestCase):
    def setUp(self):
        self.rows = importer.read_rows(DATA / "export.csv")

    def test_month_totals(self):
        self.assertEqual(digest.month_totals(self.rows), {"2026-02": 1549, "2026-03": 127155})

    def test_build(self):
        d = digest.build(self.rows, "2026-03")
        assert d is not None
        self.assertEqual(d.total_cents, 127155)
        self.assertEqual(d.by_category, {"food": 2310, "shopping": 123450, "transport": 975, "other": 420})
        self.assertEqual(d.top_payees[0], ("AMAZON MKTPLACE", 123450))

    def test_build_drops_ignored_payees(self):
        ignore = DATA / "ignore.txt"
        d = digest.build(self.rows, "2026-03", ignore)
        assert d is not None
        self.assertNotIn("CORNER CAFE", dict(d.top_payees))

    def test_remaining(self):
        d = digest.build(self.rows, "2026-03")
        assert d is not None
        self.assertEqual(digest.remaining(d, {"food": 30000}, "food"), 30000 - 2310)

    def test_post_text(self):
        d = digest.build(self.rows, "2026-03")
        assert d is not None
        text = digest.post_text(d, "https://example.com/d/2026-03")
        self.assertTrue(text.startswith("2026-03: $1,271.55\n"))
        self.assertTrue(text.endswith("https://example.com/d/2026-03"))

    def test_write_digest(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "digest.txt"
            digest.write_digest(out, "hello")
            self.assertEqual(out.read_text(encoding="utf-8"), "hello")


if __name__ == "__main__":
    unittest.main()
