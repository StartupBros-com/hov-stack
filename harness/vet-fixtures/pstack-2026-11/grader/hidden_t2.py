"""Grader-only checks for task 2 (cent rounding). Copied into the run's repo copy at grade time."""

import unittest
from datetime import date

from invoicer.models import Invoice, LineItem
from invoicer.money import format_cents
from invoicer.totals import invoice_total, line_total, subtotal_cents, tax_cents
from tests.sample import INVOICES

D = date(2026, 3, 1)


class HiddenT2(unittest.TestCase):
    def test_reported_case(self):
        inv = Invoice("A", "c", D, (LineItem("x", 1, 625),))
        self.assertEqual(invoice_total(inv), 63)

    def test_line_half_up(self):
        self.assertEqual(line_total(LineItem("x", 1, 625)), 63)
        self.assertEqual(line_total(LineItem("x", 1, 635)), 64)

    def test_credit_half_away_from_zero(self):
        self.assertEqual(line_total(LineItem("credit", 1, -625)), -63)

    def test_tax_half_up(self):
        inv = Invoice("T", "c", D, (LineItem("x", 1, 10000),), tax_bps=825)
        self.assertEqual(tax_cents(inv), 83)
        self.assertEqual(invoice_total(inv), 1083)

    def test_tax_on_rounded_subtotal(self):
        inv = Invoice("S", "c", D, (LineItem("x", 1, 12345),), tax_bps=1000)
        self.assertEqual(subtotal_cents(inv), 1235)
        self.assertEqual(tax_cents(inv), 124)
        self.assertEqual(invoice_total(inv), 1359)

    def test_subtotal_rounds_once(self):
        inv = Invoice("O", "c", D, (LineItem("a", 1, 625), LineItem("b", 1, 625)))
        self.assertEqual(subtotal_cents(inv), 125)

    def test_unchanged_amounts(self):
        self.assertEqual([invoice_total(i) for i in INVOICES], [4538, 494, 3596, 15000])
        self.assertEqual(line_total(LineItem("x", 1, 1234)), 123)
        self.assertEqual(format_cents(-5), "-$0.05")


if __name__ == "__main__":
    unittest.main()
