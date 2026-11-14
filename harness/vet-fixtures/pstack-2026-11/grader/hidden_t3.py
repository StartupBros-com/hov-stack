"""Grader-only checks for task 3 (duplicate reminders). Copied into the run's repo copy at grade time."""

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import date, timedelta

from invoicer.scheduler import overdue_invoices, send_reminders
from tests.sample import INVOICES, TODAY


class HiddenT3(unittest.TestCase):
    def collect(self, today):
        sent = []
        send_reminders(INVOICES, today, lambda customer, text: sent.append((customer, text)))
        return sent

    def test_one_reminder_per_due_invoice(self):
        sent = self.collect(TODAY)
        self.assertEqual([c for c, _ in sent], ["Acme, Inc.", "Globex"])
        self.assertIn("INV-1001", sent[0][1])
        self.assertIn("due today", sent[1][1])

    def test_next_run_still_reminds(self):
        self.collect(TODAY)
        sent = self.collect(TODAY + timedelta(days=1))
        self.assertEqual([c for c, _ in sent], ["Acme, Inc.", "Globex"])

    def test_overdue_listing_unchanged(self):
        self.assertEqual([i.invoice_id for i in overdue_invoices(INVOICES, TODAY)], ["INV-1001"])

    def test_cli_overdue(self):
        from invoicer import cli

        data = [
            {"invoice_id": "INV-9", "customer": "Late Co", "due_on": "2026-03-01",
             "lines": [{"description": "x", "quantity": 1, "unit_price_mills": 1000}]},
        ]
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "d.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(data, fh)
            out = io.StringIO()
            with redirect_stdout(out):
                rc = cli.main(["overdue", path, date(2026, 3, 10).isoformat()])
        self.assertEqual(rc, 0)
        self.assertEqual(out.getvalue().split(), ["INV-9", "Late", "Co"])


if __name__ == "__main__":
    unittest.main()
