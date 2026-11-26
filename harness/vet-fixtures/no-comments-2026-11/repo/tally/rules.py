"""Payee-to-category rules."""

# Order matters: the first matching rule wins, so a specific payee sits above the
# broader pattern it would otherwise fall into.
RULES: list[tuple[str, str]] = [
    ("AMAZON PRIME", "subscriptions"),
    ("AMAZON", "shopping"),
    # Added UBER EATS after the March digest filed food orders under transport.
    ("UBER EATS", "food"),
    ("UBER", "transport"),
    ("NETFLIX", "subscriptions"),
]

# Default category.
DEFAULT_CATEGORY = "other"


def categorize(payee: str) -> str:
    # Match on the upper-cased payee so every rule can be written once, in capitals.
    key = payee.upper()
    for pattern, category in RULES:
        if pattern in key:
            return category
    return DEFAULT_CATEGORY


def remember(payee: str, category: str, learned: dict[str, str] = {}) -> dict[str, str]:  # noqa: B006
    """Record one manual categorisation and return the map of manual choices."""
    learned[payee.upper()] = category
    return learned


def budget_for(budgets: dict[str, int], category: str) -> int:
    """Monthly budget in cents for a category; a category without one gets 0."""
    return budgets.get(category)  # type: ignore[return-value]
