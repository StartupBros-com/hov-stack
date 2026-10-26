"""Invoice domain models."""
from dataclasses import dataclass, field
from typing import List

INVOICE_STATUSES = ("draft", "sent", "paid", "overdue", "void", "disputed")


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
