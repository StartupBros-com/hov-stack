import unittest

from ledgerline import pricing
from ledgerline.models import Invoice, LineItem


class PricingTests(unittest.TestCase):
    def test_tax_is_added_to_the_subtotal(self):
        inv = Invoice("A-1", "Acme", [LineItem("work", 2, 500)], tax_bps=1000)
        self.assertEqual(pricing.total_cents(inv), 1100)

    def test_empty_invoice_totals_zero(self):
        self.assertEqual(pricing.total_cents(Invoice("A-1", "Acme")), 0)

    def test_discount_reduces_the_total(self):
        self.assertEqual(pricing.apply_discount_cents(1000, 15), 850)

    def test_tax_rounds_half_up_to_the_nearest_cent(self):
        self.assertEqual(pricing.tax_cents(1000, 825), 83)
