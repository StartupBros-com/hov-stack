"""Shared Python floor assertion for checkers that can report clean.

This is the import-only counterpart of floor-assert.sh. Callers decide whether
an unavailable corpus is fatal or becomes an explicit unverified signal; the
library never prints and never exits the process.
"""

from __future__ import annotations


class FloorNotMet(RuntimeError):
    """The checker did not examine enough of its expected corpus."""


def require_floor(total: int, minimum: int, label: str) -> bool:
    """Return true at the floor; otherwise raise a diagnostic-only exception."""
    if total < minimum:
        raise FloorNotMet(
            f"WARN {label}: examined {total} item(s), expected at least {minimum} — "
            "refusing to report clean"
        )
    return True
