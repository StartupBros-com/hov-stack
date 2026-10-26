import unittest

from ledgerline import api
from ledgerline.storage import repo


def make(number="A-1", customer="Acme"):
    items = [{"description": "work", "quantity": 1, "unit_price_cents": 1000}]
    return api.create_invoice(number, customer, items)


class ApiTests(unittest.TestCase):
    def setUp(self):
        repo.clear()

    def test_creating_an_invoice_twice_conflicts(self):
        make()
        with self.assertRaises(api.ApiError) as ctx:
            make()
        self.assertEqual(ctx.exception.status_code, 409)

    def test_unknown_status_is_rejected_with_400(self):
        make()
        with self.assertRaises(api.ApiError) as ctx:
            api.set_status("A-1", "bogus")
        self.assertEqual(ctx.exception.status_code, 400)

    def test_invoice_can_be_marked_paid(self):
        make()
        self.assertEqual(api.set_status("A-1", "paid")["status"], "paid")

    def test_customer_lookup_only_returns_that_customers_invoices(self):
        make("A-1", "Acme")
        make("B-1", "Globex")
        rows = api.invoices_for_customer("Acme")
        self.assertEqual([r["number"] for r in rows], ["A-1"])

    def test_first_page_starts_at_the_first_invoice(self):
        for n in ("A-1", "A-2", "A-3"):
            make(n)
        page = api.list_invoices(page=1, size=2)
        self.assertEqual([r["number"] for r in page], ["A-1", "A-2"])

    def test_last_page_holds_the_remainder(self):
        for n in ("A-1", "A-2", "A-3"):
            make(n)
        page = api.list_invoices(page=2, size=2)
        self.assertEqual([r["number"] for r in page], ["A-3"])

    def test_invoice_can_be_marked_overdue(self):
        make()
        self.assertEqual(api.set_status("A-1", "overdue")["status"], "overdue")

    def test_invoice_can_be_voided(self):
        make()
        self.assertEqual(api.set_status("A-1", "void")["status"], "void")

    def test_invoice_can_be_marked_disputed(self):
        make()
        self.assertEqual(api.set_status("A-1", "disputed")["status"], "disputed")
