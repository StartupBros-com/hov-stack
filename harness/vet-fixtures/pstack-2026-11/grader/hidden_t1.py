"""Grader-only checks for task 1 (CSV export). Copied into the run's repo copy at grade time."""

import csv
import io
import unittest

from tests.sample import INVOICES

BASE_TEXT = (
    "INV-1001  Acme, Inc.           $45.38  (unpaid)\n"
    "INV-1002  Globex               $4.94  (unpaid)\n"
    "INV-1003  Initech              $35.96\n"
    "INV-1004  Umbrella             $150.00  (unpaid)"
)
BASE_COMPACT = "INV-1001 $45.38\nINV-1002 $4.94\nINV-1003 $35.96\nINV-1004 $150.00"


class HiddenT1(unittest.TestCase):
    def test_csv_rows(self):
        from invoicer.report import summary_to_csv

        rows = list(csv.reader(io.StringIO(summary_to_csv(INVOICES))))
        rows = [r for r in rows if r]
        self.assertEqual(rows[0], ["invoice_id", "customer", "total", "paid"])
        self.assertEqual(
            rows[1:],
            [
                ["INV-1001", "Acme, Inc.", "$45.38", "no"],
                ["INV-1002", "Globex", "$4.94", "no"],
                ["INV-1003", "Initech", "$35.96", "yes"],
                ["INV-1004", "Umbrella", "$150.00", "no"],
            ],
        )

    def test_csv_empty(self):
        from invoicer.report import summary_to_csv

        rows = [r for r in csv.reader(io.StringIO(summary_to_csv([]))) if r]
        self.assertEqual(rows, [["invoice_id", "customer", "total", "paid"]])

    def test_compat_alias(self):
        import invoicer

        self.assertIs(invoicer.summarise, invoicer.summarize)
        self.assertIn("summarise", invoicer.__all__)

    def test_compact_format_by_name(self):
        from invoicer.plugins import load_formatter

        self.assertEqual(load_formatter("compact")(INVOICES), BASE_COMPACT)

    def test_text_summary_unchanged(self):
        from invoicer.report import format_summary

        self.assertEqual(format_summary(INVOICES), BASE_TEXT)


if __name__ == "__main__":
    unittest.main()
