#!/usr/bin/env python3
"""Extract timing fields from arm results using the rerun's sealed label mapping.

Derived from the session script that generated the recorded timing.json. Added
post-run: configurable paths and strict mapping/input validation. The recorded
snapshot is never overwritten by default.
"""
import argparse
import json
import math
from pathlib import Path

ARMS = [f'a{arm}-{trial}' for arm in range(1, 4) for trial in range(1, 4)]
FIELDS = ['duration_ms', 'duration_api_ms', 'num_turns', 'total_cost_usd']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('/tmp/hv-correct-2026-10-07'))
    parser.add_argument('--mapping', type=Path, help='default: ROOT/key/mapping.tsv')
    parser.add_argument('--output', type=Path, help='default: ROOT/out/timing.json')
    args = parser.parse_args()
    mapping_path = args.mapping or args.root / 'key/mapping.tsv'
    output = args.output or args.root / 'out/timing.json'
    try:
        pairs = [line.split('\t') for line in mapping_path.read_text().splitlines()]
        if (len(pairs) != 9 or any(len(pair) != 2 for pair in pairs)
                or {pair[0] for pair in pairs} != {f'r{i:02d}' for i in range(1, 10)}
                or {pair[1] for pair in pairs} != set(ARMS)):
            raise ValueError('mapping must contain each of the nine arms and labels exactly once')
        mapping = {arm: label for label, arm in pairs}
        rows = []
        for arm in ARMS:
            data = json.loads((args.root / 'arms' / arm / 'result.json').read_text())
            row = dict(arm=arm, blind_label=mapping[arm])
            for field in FIELDS:
                value = data[field]
                if (type(value) not in (int, float) or not math.isfinite(value) or value < 0
                        or (field == 'num_turns' and type(value) is not int)):
                    raise ValueError(f'{arm}: invalid {field}')
                row[field] = value
            rows.append(row)
        payload = dict(
            source='arms/<arm>/result.json fields copied by gen-timing.py; labels from the supplied mapping',
            wall_s_rule="the note's 'wall s' column is duration_ms / 1000 rounded to the nearest second",
            runs=rows,
        )
        # Read and validate every source before opening an existing output.
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(payload, indent=1, allow_nan=False) + '\n')
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f'ERROR: {exc}\n')
    print(f'wrote {output}: {len(rows)} runs')


if __name__ == '__main__':
    main()
