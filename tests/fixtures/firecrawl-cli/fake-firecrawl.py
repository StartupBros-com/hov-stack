#!/usr/bin/env python3
"""Offline vendor: control maps verbs to fixture filenames and optional exits."""

import json
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
with open(os.environ["FIRECRAWL_TEST_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps(args) + "\n")
control = json.loads(Path(os.environ["FIRECRAWL_TEST_CONTROL"]).read_text())
fixtures = Path(os.environ["FIRECRAWL_TEST_FIXTURES"])
rule = control.get(args[0], control.get("default", {}))
if args[0] == "credit-usage":
    rule = control.get("credit-usage", {"fixture": "credit-usage.json"})
    reads = sum(
        json.loads(line)[0] == "credit-usage"
        for line in Path(os.environ["FIRECRAWL_TEST_LOG"]).read_text().splitlines()
    )
    if reads <= rule.get("failures", 0) or reads in rule.get("failed_reads", []):
        sys.stderr.write("synthetic credit-usage read failure\n")
        sys.exit(1)
    if "remaining" in rule:
        values = rule["remaining"]
        payload = json.loads((fixtures / "credit-usage.json").read_text())
        payload["data"]["remainingCredits"] = values[min(reads - 1, len(values) - 1)]
        print(json.dumps(payload))
        sys.exit(0)
for target in args[1:]:
    if target in control.get("targets", {}):
        rule = control["targets"][target]
        break
# A rule's "keyless" sub-rule answers the wrapper's keyless leg, which strips
# the key from this process's environment (#2118). The optional env log records
# which credentials each call saw, never their values.
if os.environ.get("FIRECRAWL_TEST_ENV_LOG"):
    with open(os.environ["FIRECRAWL_TEST_ENV_LOG"], "a", encoding="utf-8") as log:
        log.write(json.dumps({
            "argv": args,
            "key": "FIRECRAWL_API_KEY" in os.environ,
            "url": "FIRECRAWL_API_URL" in os.environ,
        }) + "\n")
if "FIRECRAWL_API_KEY" not in os.environ and isinstance(rule.get("keyless"), dict):
    rule = rule["keyless"]
# Inputs must still resolve when the wrapper changes the vendor's cwd.
if args[0] == "parse":
    assert Path(args[1]).is_file()
for flag in ("--schema-file", "--actions-file"):
    if flag in args:
        json.loads(Path(args[args.index(flag) + 1]).read_text())
if rule.get("sleep"):
    time.sleep(rule["sleep"])
if rule.get("block"):
    flag = Path(rule["block"])
    flag.with_suffix(".entered").touch()
    deadline = time.monotonic() + 10
    while not flag.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not flag.exists():
        sys.exit(1)
if rule.get("write"):
    Path(rule["write"]).write_text("fake vendor artifact\n")
if rule.get("stderr"):
    sys.stderr.write((fixtures / rule["stderr"]).read_text())
if rule.get("stderr_text"):
    sys.stderr.write(rule["stderr_text"])
if "text" in rule:
    sys.stdout.write(rule["text"])
if rule.get("body_size"):
    sys.stdout.write(json.dumps({"data": {"markdown": "x" * rule["body_size"]}}))
if rule.get("fixture"):
    sys.stdout.write((fixtures / rule["fixture"]).read_text())
sys.exit(rule.get("exit", 0))
