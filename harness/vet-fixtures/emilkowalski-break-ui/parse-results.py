"""Turn each arm's claude -p JSON into a markdown file and one summary line.

Usage: python3 -I parse-results.py <out-dir>

Prints, per run: cost, token counts, number of turns, number of markdown table
rows in the result, and whether the CLI reported an error. With --tools "" no
tool can run, so num_turns is the confound record: every arm should show 1.
"""
import glob
import json
import os
import sys

out = sys.argv[1]
for path in sorted(glob.glob(os.path.join(out, "*.json"))):
    name = os.path.basename(path)[:-5]
    if name == "arm-settings":
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        print(name, "PARSE-FAIL", exc)
        continue
    result = data.get("result", "") or ""
    with open(path[:-5] + ".md", "w", encoding="utf-8") as fh:
        fh.write(result)
    usage = data.get("usage", {}) or {}
    rows = result.count("\n|")
    print(
        "%s: cost=$%.4f in=%s cache_r=%s cache_w=%s out=%s turns=%s rows=%s chars=%s err=%s"
        % (
            name,
            data.get("total_cost_usd", 0) or 0,
            usage.get("input_tokens", 0),
            usage.get("cache_read_input_tokens", 0),
            usage.get("cache_creation_input_tokens", 0),
            usage.get("output_tokens", 0),
            data.get("num_turns"),
            rows,
            len(result),
            data.get("is_error"),
        )
    )
