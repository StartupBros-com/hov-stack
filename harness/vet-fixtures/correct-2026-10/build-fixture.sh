#!/usr/bin/env bash
set -eu

ROOT=/tmp/hv-correct-2026-10-07
FX=$ROOT/fixture
TOOLS=$ROOT/tools
SHAS=$ROOT/key/shas.txt

if [ -e "$FX" ]; then
  echo "fixture already exists: $FX" >&2
  exit 1
fi

mkdir -p "$ROOT/key"
: > "$SHAS"
mkdir -p "$FX"
cd "$FX"
git init -q -b main
git config commit.gpgsign false
git config core.hooksPath /dev/null

commit() {
  # idx date name email message
  git add -A
  GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL="$4" GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
    GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git commit -q -m "$5"
  echo "c$1 $(git rev-parse --short=8 HEAD)" >> "$SHAS"
}
M() { commit "$1" "$2" "Maya Okafor" "maya@example.invalid" "$3"; }
CU() { commit "$1" "$2" "cursor-agent" "agent@example.invalid" "$3"; }
CL() { commit "$1" "$2" "claude" "claude@example.invalid" "$3"; }
rep() { python3 "$TOOLS/rep.py" "$@"; }

mkdir -p src/ledgerline/storage tests scripts .github/workflows

########## 01 scaffold (Maya)
printf '__pycache__/\n*.pyc\n' > .gitignore
printf 'export PYTHONPATH := src\n\n.PHONY: check\ncheck:\n\tpython3 -m unittest discover -s tests -q && python3 scripts/check.py\n' > Makefile

cat > README.md <<'EOF'
# ledgerline

Small invoicing service: invoices, line items, totals, CSV export.
Standard library only; runs offline.

Run `make check` for the unit tests and the static checks.
EOF

cat > AGENTS.md <<'EOF'
# ledgerline

Small invoicing service. Python 3, standard library only.

## Checks

Run `make check` before every commit. CI runs the same command.

## Rules

- Standard library only. No third-party packages.
- Name tests after the behaviour, not the function.
- Keep modules small and put new code next to the code it extends.
EOF

cat > .github/workflows/check.yml <<'EOF'
name: check
on:
  push:
    branches: [main]
  pull_request:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: make check
EOF

cat > scripts/check.py <<'EOF'
#!/usr/bin/env python3
"""Static checks for src/. Standard library only. Exit 1 on any finding."""
import ast
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

CHECKS = []


def source_files():
    return sorted(SRC.rglob("*.py"))


def main():
    problems = []
    for path in source_files():
        rel = path.relative_to(ROOT)
        tree = ast.parse(path.read_text(), filename=str(path))
        for check in CHECKS:
            problems.extend(check(rel, tree))
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
EOF

cat > src/ledgerline/__init__.py <<'EOF'
"""ledgerline: invoicing service."""
EOF

cat > tests/test_smoke.py <<'EOF'
import unittest


class PackageTests(unittest.TestCase):
    def test_package_imports_cleanly(self):
        import ledgerline

        self.assertTrue(ledgerline.__doc__)
EOF
M 01 "2026-08-03T10:15:00+0000" "scaffold ledgerline: package, make check, CI"

########## 02 models (cursor-agent)
cat > src/ledgerline/models.py <<'EOF'
"""Invoice domain models."""
from dataclasses import dataclass, field
from typing import List

INVOICE_STATUSES = ("draft", "sent", "paid")


@dataclass
class LineItem:
    description: str
    quantity: int
    unit_price_cents: int


@dataclass
class Invoice:
    number: str
    customer: str
    items: List[LineItem] = field(default_factory=list)
    status: str = "draft"
    tax_bps: int = 0

    def __post_init__(self):
        if self.status not in INVOICE_STATUSES:
            raise ValueError("unknown status: %s" % self.status)

    def transition(self, status):
        if status not in INVOICE_STATUSES:
            raise ValueError("unknown status: %s" % status)
        self.status = status
EOF
cat > tests/test_models.py <<'EOF'
import unittest

from ledgerline.models import Invoice


class InvoiceTests(unittest.TestCase):
    def test_new_invoice_starts_as_draft(self):
        self.assertEqual(Invoice("A-1", "Acme").status, "draft")

    def test_unknown_status_is_rejected_on_transition(self):
        inv = Invoice("A-1", "Acme")
        with self.assertRaises(ValueError):
            inv.transition("bogus")
EOF
CU 02 "2026-08-05T14:02:00+0000" "models: Invoice and LineItem with status validation"

########## 03 storage (claude)
cat > src/ledgerline/storage/__init__.py <<'EOF'
"""Storage package. Callers use ledgerline.storage.repo."""
EOF
cat > src/ledgerline/storage/_db.py <<'EOF'
"""Low-level in-memory tables. Only storage.repo should touch this."""

_TABLES = {}


def table(name):
    return _TABLES.setdefault(name, {})


def all_rows(name):
    return list(table(name).values())


def put_row(name, key, row):
    table(name)[key] = row


def get_row(name, key):
    return table(name).get(key)


def reset():
    _TABLES.clear()
EOF
cat > src/ledgerline/storage/repo.py <<'EOF'
"""Invoice persistence."""
from . import _db


def save_invoice(invoice):
    _db.put_row("invoices", invoice.number, invoice)


def get_invoice(number):
    return _db.get_row("invoices", number)


def list_invoices():
    return sorted(_db.all_rows("invoices"), key=lambda inv: inv.number)


def clear():
    _db.reset()
EOF
cat > tests/test_repo.py <<'EOF'
import unittest

from ledgerline.models import Invoice
from ledgerline.storage import repo


class RepoTests(unittest.TestCase):
    def setUp(self):
        repo.clear()

    def test_saved_invoice_can_be_fetched_by_number(self):
        repo.save_invoice(Invoice("A-1", "Acme"))
        self.assertEqual(repo.get_invoice("A-1").customer, "Acme")

    def test_missing_invoice_is_none(self):
        self.assertIsNone(repo.get_invoice("nope"))
EOF
CL 03 "2026-08-06T09:40:00+0000" "storage: in-memory tables behind a repo module"

########## 04 api (cursor-agent) -- print() introduced here
cat > src/ledgerline/api.py <<'EOF'
"""Thin request-handling layer over the repo."""
import logging

from ledgerline.models import Invoice, LineItem
from ledgerline.storage import repo

log = logging.getLogger(__name__)

INVOICE_STATUSES = ("draft", "sent", "paid")


class ApiError(Exception):
    def __init__(self, status_code, message):
        super().__init__(message)
        self.status_code = status_code


def invoice_view(inv):
    return {
        "number": inv.number,
        "customer": inv.customer,
        "status": inv.status,
        "items": len(inv.items),
    }


def create_invoice(number, customer, items, tax_bps=0):
    if repo.get_invoice(number) is not None:
        raise ApiError(409, "invoice exists: %s" % number)
    inv = Invoice(number, customer, [LineItem(**i) for i in items], tax_bps=tax_bps)
    repo.save_invoice(inv)
    print("created invoice", number)
    return invoice_view(inv)


def get_invoice(number):
    inv = repo.get_invoice(number)
    if inv is None:
        raise ApiError(404, "no such invoice: %s" % number)
    return invoice_view(inv)


def list_invoices():
    return [invoice_view(i) for i in repo.list_invoices()]


def set_status(number, status):
    if status not in INVOICE_STATUSES:
        raise ApiError(400, "bad status: %s" % status)
    inv = repo.get_invoice(number)
    if inv is None:
        raise ApiError(404, "no such invoice: %s" % number)
    inv.transition(status)
    return invoice_view(inv)
EOF
cat > tests/test_api.py <<'EOF'
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
EOF
CU 04 "2026-08-10T15:30:00+0000" "api: create, get, list and set status for invoices"

########## 05 ban print (Maya)
rep src/ledgerline/api.py '    print("created invoice", number)
' '    log.info("created invoice %s", number)
'
rep scripts/check.py 'CHECKS = []
' 'def no_print(rel, tree):
    found = []
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "print"
        ):
            found.append(
                "%s:%d: print() is not allowed in src/; "
                "use logging.getLogger(__name__).info(...)" % (rel, node.lineno)
            )
    return found


CHECKS = [no_print]
'
cat >> AGENTS.md <<'EOF'
- No `print()` in `src/`; use `logging`. `scripts/check.py` fails the build on it.
EOF
M 05 "2026-08-11T08:55:00+0000" "ban print() in src, log through logging instead"

########## 06 pricing in cents (claude)
cat > src/ledgerline/pricing.py <<'EOF'
"""Invoice totals. All amounts are integer cents."""


def subtotal_cents(items):
    return sum(i.quantity * i.unit_price_cents for i in items)


def tax_cents(subtotal, tax_bps):
    return (subtotal * tax_bps + 5000) // 10000


def total_cents(invoice):
    sub = subtotal_cents(invoice.items)
    return sub + tax_cents(sub, invoice.tax_bps)
EOF
rep src/ledgerline/api.py 'from ledgerline.models import Invoice, LineItem
' 'from ledgerline import pricing
from ledgerline.models import Invoice, LineItem
'
rep src/ledgerline/api.py '        "items": len(inv.items),
' '        "items": len(inv.items),
        "total_cents": pricing.total_cents(inv),
'
cat > tests/test_pricing.py <<'EOF'
import unittest

from ledgerline import pricing
from ledgerline.models import Invoice, LineItem


class PricingTests(unittest.TestCase):
    def test_tax_is_added_to_the_subtotal(self):
        inv = Invoice("A-1", "Acme", [LineItem("work", 2, 500)], tax_bps=1000)
        self.assertEqual(pricing.total_cents(inv), 1100)

    def test_empty_invoice_totals_zero(self):
        self.assertEqual(pricing.total_cents(Invoice("A-1", "Acme")), 0)
EOF
CL 06 "2026-08-14T11:20:00+0000" "pricing: totals and tax in integer cents"

########## 07 customer lookup via _db (cursor-agent) C3 #1
rep src/ledgerline/api.py 'from ledgerline.storage import repo
' 'from ledgerline.storage import _db, repo
'
cat >> src/ledgerline/api.py <<'EOF'


def invoices_for_customer(customer):
    rows = _db.all_rows("invoices")
    return [invoice_view(i) for i in rows if i.customer == customer]
EOF
cat >> tests/test_api.py <<'EOF'

    def test_customer_lookup_only_returns_that_customers_invoices(self):
        make("A-1", "Acme")
        make("B-1", "Globex")
        rows = api.invoices_for_customer("Acme")
        self.assertEqual([r["number"] for r in rows], ["A-1"])
EOF
CU 07 "2026-08-18T16:45:00+0000" "api: look up invoices by customer"

########## 08 fix C3 #1 (Maya)
rep src/ledgerline/api.py 'from ledgerline.storage import _db, repo
' 'from ledgerline.storage import repo
'
rep src/ledgerline/api.py '    rows = _db.all_rows("invoices")
    return [invoice_view(i) for i in rows if i.customer == customer]
' '    return [invoice_view(i) for i in repo.invoices_for_customer(customer)]
'
cat >> src/ledgerline/storage/repo.py <<'EOF'


def invoices_for_customer(customer):
    return [inv for inv in list_invoices() if inv.customer == customer]
EOF
cat >> AGENTS.md <<'EOF'
- Reach storage only through `ledgerline.storage.repo`.
EOF
M 08 "2026-08-19T09:10:00+0000" "api: customer lookup goes through repo, please route through repo not _db"

########## 09 pagination with off-by-one (claude) D1
rep src/ledgerline/api.py 'def list_invoices():
    return [invoice_view(i) for i in repo.list_invoices()]
' 'PAGE_SIZE = 20


def list_invoices(page=1, size=PAGE_SIZE):
    rows = repo.list_invoices()
    start = page * size
    return [invoice_view(i) for i in rows[start:start + size]]
'
CL 09 "2026-08-24T13:05:00+0000" "api: paginate invoice listing"

########## 10 fix D1 (Maya)
rep src/ledgerline/api.py '    start = page * size
' '    start = (page - 1) * size
'
cat >> tests/test_api.py <<'EOF'

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
EOF
M 10 "2026-08-25T08:30:00+0000" "api: fix pagination off-by-one, page 1 skipped the first rows"

########## 11 overdue in models only (cursor-agent) C1 #1
rep src/ledgerline/models.py 'INVOICE_STATUSES = ("draft", "sent", "paid")' 'INVOICE_STATUSES = ("draft", "sent", "paid", "overdue")'
cat >> tests/test_models.py <<'EOF'

    def test_overdue_is_a_valid_status(self):
        inv = Invoice("A-1", "Acme")
        inv.transition("overdue")
        self.assertEqual(inv.status, "overdue")
EOF
CU 11 "2026-09-01T10:00:00+0000" "models: add overdue status"

########## 12 fix C1 #1 (Maya)
rep src/ledgerline/api.py 'INVOICE_STATUSES = ("draft", "sent", "paid")' '# keep in sync with models.INVOICE_STATUSES
INVOICE_STATUSES = ("draft", "sent", "paid", "overdue")'
cat >> tests/test_api.py <<'EOF'

    def test_invoice_can_be_marked_overdue(self):
        make()
        self.assertEqual(api.set_status("A-1", "overdue")["status"], "overdue")
EOF
M 12 "2026-09-02T09:25:00+0000" "api: overdue was rejected with a 400, add it to the api status list too"

########## 13 export (claude)
cat > src/ledgerline/export.py <<'EOF'
"""CSV and summary exports."""
import csv
import io

from ledgerline import pricing
from ledgerline.storage import repo

INVOICE_STATUSES = ("draft", "sent", "paid", "overdue")


def invoices_csv(status=None):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(["number", "customer", "status", "total_cents"])
    for inv in repo.list_invoices():
        if status is not None and inv.status != status:
            continue
        writer.writerow([inv.number, inv.customer, inv.status, pricing.total_cents(inv)])
    return out.getvalue()


def status_summary():
    """Total cents per status, in display order."""
    totals = {s: 0 for s in INVOICE_STATUSES}
    for inv in repo.list_invoices():
        if inv.status in totals:
            totals[inv.status] += pricing.total_cents(inv)
    return totals
EOF
cat > tests/test_export.py <<'EOF'
import unittest

from ledgerline import export
from ledgerline.models import Invoice, LineItem
from ledgerline.storage import repo


class ExportTests(unittest.TestCase):
    def setUp(self):
        repo.clear()
        repo.save_invoice(Invoice("A-1", "Acme", [LineItem("work", 2, 500)], tax_bps=1000))

    def test_csv_has_a_row_per_invoice(self):
        lines = export.invoices_csv().splitlines()
        self.assertEqual(lines[1], "A-1,Acme,draft,1100")

    def test_status_summary_totals_cents_by_status(self):
        self.assertEqual(export.status_summary()["draft"], 1100)
EOF
CL 13 "2026-09-03T14:10:00+0000" "export: CSV and per-status summary"

########## 14 float tax and discount (cursor-agent) C2 #1
rep src/ledgerline/pricing.py '    return (subtotal * tax_bps + 5000) // 10000
' '    # float math is fine here, we truncate at the end
    return int(subtotal * (tax_bps / 10000))
'
cat >> src/ledgerline/pricing.py <<'EOF'


def apply_discount_cents(total, percent):
    return round(total * (1 - percent / 100))
EOF
cat >> tests/test_pricing.py <<'EOF'

    def test_discount_reduces_the_total(self):
        self.assertEqual(pricing.apply_discount_cents(1000, 15), 850)
EOF
CU 14 "2026-09-07T15:15:00+0000" "pricing: fractional tax rates and percentage discounts"

########## 15 fix C2 #1 (Maya)
cat > src/ledgerline/pricing.py <<'EOF'
"""Invoice totals. All amounts are integer cents."""


def subtotal_cents(items):
    return sum(i.quantity * i.unit_price_cents for i in items)


def tax_cents(subtotal, tax_bps):
    # integer half-up rounding; never go through float
    return (subtotal * tax_bps + 5000) // 10000


def apply_discount_cents(total, percent):
    return (total * (100 - percent) + 50) // 100


def total_cents(invoice):
    sub = subtotal_cents(invoice.items)
    return sub + tax_cents(sub, invoice.tax_bps)
EOF
cat >> tests/test_pricing.py <<'EOF'

    def test_tax_rounds_half_up_to_the_nearest_cent(self):
        self.assertEqual(pricing.tax_cents(1000, 825), 83)
EOF
cat >> AGENTS.md <<'EOF'
- Money is integer cents. No float arithmetic on amounts.
EOF
M 15 "2026-09-08T09:00:00+0000" "pricing: tax and discount in integer cents, floats were off by a cent at 825 bps"

########## 16 void in models+api, not export (claude) C1 #2
rep src/ledgerline/models.py 'INVOICE_STATUSES = ("draft", "sent", "paid", "overdue")' 'INVOICE_STATUSES = ("draft", "sent", "paid", "overdue", "void")'
rep src/ledgerline/api.py 'INVOICE_STATUSES = ("draft", "sent", "paid", "overdue")' 'INVOICE_STATUSES = ("draft", "sent", "paid", "overdue", "void")'
cat >> tests/test_api.py <<'EOF'

    def test_invoice_can_be_voided(self):
        make()
        self.assertEqual(api.set_status("A-1", "void")["status"], "void")
EOF
CL 16 "2026-09-11T11:35:00+0000" "add void status for cancelled invoices"

########## 17 fix C1 #2 (Maya)
rep src/ledgerline/export.py 'INVOICE_STATUSES = ("draft", "sent", "paid", "overdue")' '# must match api.INVOICE_STATUSES (void got missed last time)
INVOICE_STATUSES = ("draft", "sent", "paid", "overdue", "void")'
cat >> tests/test_export.py <<'EOF'

    def test_status_summary_includes_void_invoices(self):
        repo.get_invoice("A-1").transition("void")
        self.assertEqual(export.status_summary()["void"], 1100)
EOF
cat >> AGENTS.md <<'EOF'
- A new invoice status goes in every status list (models, api, export).
EOF
M 17 "2026-09-12T08:45:00+0000" "export: void missing from the status list again, summary dropped voided invoices"

########## 18 float dollars in export (cursor-agent) C2 #2
rep src/ledgerline/export.py '    writer.writerow(["number", "customer", "status", "total_cents"])' '    writer.writerow(["number", "customer", "status", "total"])'
rep src/ledgerline/export.py 'pricing.total_cents(inv)])' 'dollars(pricing.total_cents(inv))])'
rep src/ledgerline/export.py 'def invoices_csv(status=None):' 'def dollars(cents):
    # dollars for the finance sheet
    return round(cents / 100, 2)


def grand_total():
    return sum(dollars(pricing.total_cents(i)) for i in repo.list_invoices())


def invoices_csv(status=None):'
rep tests/test_export.py 'A-1,Acme,draft,1100' 'A-1,Acme,draft,11.0'
cat >> tests/test_export.py <<'EOF'

    def test_grand_total_adds_every_invoice(self):
        self.assertEqual(export.grand_total(), 11.0)
EOF
CU 18 "2026-09-15T14:20:00+0000" "export: show totals in dollars and add a grand total"

########## 19 fix C2 #2 (Maya)
rep src/ledgerline/export.py 'def dollars(cents):
    # dollars for the finance sheet
    return round(cents / 100, 2)


def grand_total():
    return sum(dollars(pricing.total_cents(i)) for i in repo.list_invoices())
' 'def format_cents(cents):
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return "%s%d.%02d" % (sign, cents // 100, cents % 100)


def grand_total_cents():
    return sum(pricing.total_cents(i) for i in repo.list_invoices())
'
rep src/ledgerline/export.py 'dollars(pricing.total_cents(inv))])' 'format_cents(pricing.total_cents(inv))])'
rep tests/test_export.py 'A-1,Acme,draft,11.0' 'A-1,Acme,draft,11.00'
rep tests/test_export.py 'export.grand_total(), 11.0' 'export.grand_total_cents(), 1100'
M 19 "2026-09-16T09:05:00+0000" "export: format amounts from integer cents, float rounding again"

########## 20 customer report via _db (claude) C3 #2
rep src/ledgerline/export.py 'from ledgerline.storage import repo
' 'from ledgerline.storage import _db, repo
'
cat >> src/ledgerline/export.py <<'EOF'


def customer_report():
    """Total cents per customer."""
    totals = {}
    for inv in _db.all_rows("invoices"):
        totals[inv.customer] = totals.get(inv.customer, 0) + pricing.total_cents(inv)
    return totals
EOF
cat >> tests/test_export.py <<'EOF'

    def test_customer_report_totals_cents_per_customer(self):
        self.assertEqual(export.customer_report(), {"Acme": 1100})
EOF
CL 20 "2026-09-21T13:50:00+0000" "export: per-customer report"

########## 21 fix C3 #2 (Maya)
rep src/ledgerline/export.py 'from ledgerline.storage import _db, repo
' "# don't import _db here, use repo
from ledgerline.storage import repo
"
rep src/ledgerline/export.py '_db.all_rows("invoices")' 'repo.list_invoices()'
M 21 "2026-09-22T08:40:00+0000" "export: customer report uses repo, same problem as the api lookup in August"

########## 22 disputed in api+export, not models (cursor-agent) C1 #3
rep src/ledgerline/api.py '"overdue", "void")' '"overdue", "void", "disputed")'
rep src/ledgerline/export.py '"overdue", "void")' '"overdue", "void", "disputed")'
cat >> tests/test_export.py <<'EOF'

    def test_status_summary_includes_disputed_invoices(self):
        inv = repo.get_invoice("A-1")
        inv.status = "disputed"
        self.assertEqual(export.status_summary()["disputed"], 1100)
EOF
CU 22 "2026-09-25T15:55:00+0000" "add disputed status"

########## 23 fix C1 #3 (Maya)
rep src/ledgerline/models.py '"overdue", "void")' '"overdue", "void", "disputed")'
cat >> tests/test_api.py <<'EOF'

    def test_invoice_can_be_marked_disputed(self):
        make()
        self.assertEqual(api.set_status("A-1", "disputed")["status"], "disputed")
EOF
M 23 "2026-09-26T09:30:00+0000" "models: add disputed, set_status raised ValueError. third time this month the lists drifted"

########## 24 readme (claude)
cat > README.md <<'EOF'
# ledgerline

Small invoicing service: invoices, line items, totals, CSV export.
Standard library only; runs offline.

## Layout

- `src/ledgerline/models.py` invoice and line item types
- `src/ledgerline/api.py` request handlers
- `src/ledgerline/pricing.py` subtotals, tax and discounts
- `src/ledgerline/export.py` CSV and summary reports
- `src/ledgerline/storage/` in-memory persistence, used through `repo`

## Checks

Run `make check` for the unit tests and the static checks. CI runs the same
command on every push and pull request.
EOF
CL 24 "2026-09-29T10:10:00+0000" "readme: describe layout and make check"

echo "built: $(git rev-list --count HEAD) commits"
