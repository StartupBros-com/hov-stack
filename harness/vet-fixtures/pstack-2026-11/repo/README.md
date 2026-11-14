# invoicer

Invoice totals, summaries and payment reminders for the finance team.

```
make check                                   # unit tests
python3 -m invoicer.cli summary data.json    # text summary
python3 -m invoicer.cli overdue data.json    # overdue invoices
```

## Amounts

Unit prices are stored in mills (tenths of a cent), so `625` is 62.5¢. Credit
lines carry a negative unit price. Tax rates are basis points (`825` is 8.25%).

## Rounding

Amounts are rounded to whole cents **half away from zero**: 62.5¢ becomes 63¢
and a 62.5¢ credit becomes -63¢. A subtotal adds its lines in mills and rounds
once. Tax is computed on the rounded subtotal and rounded the same way.

## Summary formats

`summary_format` in `invoicer.toml` picks the layout by name; the names are
listed in `invoicer/plugins.py`.
