"""Command line: python3 -m invoicer.cli summary|overdue DATA.json [YYYY-MM-DD]"""

import json
import sys
from datetime import date

from invoicer.models import Invoice, LineItem
from invoicer.report import format_summary
from invoicer.scheduler import overdue_invoices


def load(path):
    with open(path, encoding="utf-8") as fh:
        raw = json.load(fh)
    return [
        Invoice(
            invoice_id=r["invoice_id"],
            customer=r["customer"],
            due_on=date.fromisoformat(r["due_on"]),
            lines=tuple(LineItem(**line) for line in r.get("lines", [])),
            tax_bps=r.get("tax_bps", 0),
            paid=r.get("paid", False),
        )
        for r in raw
    ]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    command, path = argv[0], argv[1]
    today = date.fromisoformat(argv[2]) if len(argv) > 2 else date.today()
    invoices = load(path)
    if command == "summary":
        print(format_summary(invoices))
    elif command == "overdue":
        for inv in overdue_invoices(invoices, today):
            print(inv.invoice_id, inv.customer)
    else:
        print(f"unknown command: {command}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
