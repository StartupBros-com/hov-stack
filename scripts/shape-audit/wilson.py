"""Wilson score interval shared by the shape-audit scripts.

Return is (point, low, high) in percentage points, not a unit proportion.
n == 0 returns (0.0, 0.0, 0.0). The low/high clamps can be int 0 or int 100
when the interval hits the boundary (max/min with a bare 0 or 1).

Do not merge with rlm-bakeoff's wilson_ci: that returns a unit-interval pair
and (0.0, 1.0) when n == 0.
"""
import math


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (100 * p, 100 * max(0, c - h), 100 * min(1, c + h))
