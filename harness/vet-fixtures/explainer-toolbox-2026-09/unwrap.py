#!/usr/bin/env python3
"""Unwrap a `claude -p --output-format json` envelope: write result text beside it as .md, print one summary line."""
import json
import re
import sys

p = sys.argv[1]
b = p.rsplit("/", 1)[-1][:-5]
try:
    d = json.load(open(p))
except Exception as e:  # noqa: BLE001
    print(b, "PARSE-FAIL", e)
    sys.exit(0)
res = d.get("result", "")
open(p[:-5] + ".md", "w").write(res)
u = d.get("usage", {})
served = ",".join(d.get("modelUsage", {}).keys())
# visible prose words: strip fenced blocks and inline html tags
prose = re.sub(r"```.*?```", "", res, flags=re.S)
prose = re.sub(r"<[^>]+>", "", prose)
words = len(prose.split())
mermaid = len(re.findall(r"```mermaid", res))
svg = len(re.findall(r"<svg\b", res))
html = "yes" if re.search(r"<!DOCTYPE html|<html\b", res, re.I) else "no"
print(
    f"{b}: cost=${d.get('total_cost_usd', 0):.4f} served={served} in={u.get('input_tokens', 0)} "
    f"out={u.get('output_tokens', 0)} err={d.get('is_error')} prose_words={words} mermaid={mermaid} svg={svg} html={html}"
)
