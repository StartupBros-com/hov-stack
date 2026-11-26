"""Money helpers. Every amount inside tally is an int count of cents."""

from decimal import ROUND_HALF_UP, Decimal


def to_cents(amount: str) -> int:
    """Convert a decimal amount string such as ``"12.34"`` to integer cents.

    Rounds half away from zero, the way the bank's statement totals round.
    Raises ``decimal.InvalidOperation`` when the string is not a number.

    >>> to_cents("12.345")
    1235
    >>> to_cents("-0.005")
    -1
    """
    # Decimal, not float: binary floats drift by a cent over a long statement.
    value = Decimal(amount)
    return int((value * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def parse_amount(text: str) -> int:
    """Parse one amount cell from the export, such as ``"$12.34"``, into cents."""
    # Strip the currency symbol and surrounding spaces.
    cleaned = text.strip().lstrip("$")
    return to_cents(cleaned)


def format_money(cents: int) -> str:
    # A negative total keeps its sign in front of the dollar sign (-$4.20), the
    # form the post template expects.
    sign = "-" if cents < 0 else ""
    whole, frac = divmod(abs(cents), 100)
    return f"{sign}${whole:,}.{frac:02d}"
