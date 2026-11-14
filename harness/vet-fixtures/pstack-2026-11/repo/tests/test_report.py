import unittest

from invoicer.report import format_summary, summarize
from tests.sample import INVOICES


class ReportTest(unittest.TestCase):
    def test_summarize(self):
        rows = summarize(INVOICES)
        self.assertEqual([r["invoice_id"] for r in rows], ["INV-1001", "INV-1002", "INV-1003", "INV-1004"])
        self.assertEqual(rows[0]["customer"], "Acme, Inc.")

    def test_format_summary(self):
        lines = format_summary(INVOICES).splitlines()
        self.assertEqual(len(lines), 4)
        self.assertTrue(lines[0].endswith("(unpaid)"))
        self.assertFalse(lines[2].endswith("(unpaid)"))


if __name__ == "__main__":
    unittest.main()
