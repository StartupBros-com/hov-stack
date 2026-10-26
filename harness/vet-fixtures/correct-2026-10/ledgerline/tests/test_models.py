import unittest

from ledgerline.models import Invoice


class InvoiceTests(unittest.TestCase):
    def test_new_invoice_starts_as_draft(self):
        self.assertEqual(Invoice("A-1", "Acme").status, "draft")

    def test_unknown_status_is_rejected_on_transition(self):
        inv = Invoice("A-1", "Acme")
        with self.assertRaises(ValueError):
            inv.transition("bogus")

    def test_overdue_is_a_valid_status(self):
        inv = Invoice("A-1", "Acme")
        inv.transition("overdue")
        self.assertEqual(inv.status, "overdue")
