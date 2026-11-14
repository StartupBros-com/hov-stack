import unittest

from invoicer.models import Invoice, LineItem
from invoicer.money import format_cents
from invoicer.totals import invoice_total, line_total, subtotal_cents, tax_cents
from tests.sample import INVOICES


class TotalsTest(unittest.TestCase):
    def test_line_total(self):
        self.assertEqual(line_total(LineItem("Widgets", 3, 12340)), 3702)

    def test_credit_line(self):
        self.assertEqual(line_total(LineItem("Credit", 1, -4000)), -400)

    def test_subtotal_rounds_once(self):
        inv = Invoice("X", "c", None, (LineItem("a", 1, 1234), LineItem("b", 1, 1234)))
        self.assertEqual(subtotal_cents(inv), 247)

    def test_tax(self):
        self.assertEqual(tax_cents(INVOICES[0]), 336)

    def test_invoice_total(self):
        self.assertEqual(invoice_total(INVOICES[0]), 4538)

    def test_format_cents(self):
        self.assertEqual(format_cents(1234), "$12.34")
        self.assertEqual(format_cents(-5), "-$0.05")


if __name__ == "__main__":
    unittest.main()
