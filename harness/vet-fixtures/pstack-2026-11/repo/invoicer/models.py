"""Invoice data."""

from dataclasses import dataclass
from datetime import date


@dataclass(frozen=True)
class LineItem:
    description: str
    quantity: int
    unit_price_mills: int  # tenths of a cent: 625 is 62.5 cents; credits are negative


@dataclass(frozen=True)
class Invoice:
    invoice_id: str
    customer: str
    due_on: date
    lines: tuple = ()
    tax_bps: int = 0  # basis points: 825 is 8.25%
    paid: bool = False
