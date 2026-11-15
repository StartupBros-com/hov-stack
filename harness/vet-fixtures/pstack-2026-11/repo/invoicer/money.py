"""Money helpers. Amounts stay in mills (tenths of a cent) until rounded to cents."""


def to_cents(mills):
    """Round an amount in mills to whole cents (see Rounding in README.md)."""
    return round(mills / 10)


def format_cents(cents):
    """Render cents as dollars: 1234 -> "$12.34", -5 -> "-$0.05"."""
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}${cents // 100}.{cents % 100:02d}"
