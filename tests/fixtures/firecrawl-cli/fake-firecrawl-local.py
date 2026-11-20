#!/usr/bin/env python3
"""Stand-in for firecrawl-local 0.1.1 in tests/firecrawl-cli.test.sh (#807).

The wrapper hands the scraper an environment built from nothing, so this stub finds
its control and log beside itself (after resolving symlinks), not through variables:
  control.json  {"version": spec, "first": spec, "chrome": spec, "by_url": {url: spec}}
                a spec is a case name from local-responses.json (recorded from the
                pinned binary) or {"case", "rc", "stdout", "sleep", "spawn", "signal"};
                by_url replaces the first-pass spec for that URL
  calls.jsonl   one line per run: {"pass", "argv", "env", "pid"}
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
control = json.loads((HERE / "control.json").read_text())
responses = json.loads((HERE / "local-responses.json").read_text())
argv = sys.argv[1:]
step = "version" if argv == ["--version"] else (
    "chrome" if "--browser" in argv else "first"
)
with open(HERE / "calls.jsonl", "a") as log:
    log.write(json.dumps(
        {"pass": step, "argv": argv, "env": dict(os.environ), "pid": os.getpid()}
    ) + "\n")
spec = control.get(step, "version" if step == "version" else "plain")
if step == "first" and len(argv) > 1 and argv[1] in control.get("by_url", {}):
    spec = control["by_url"][argv[1]]
if isinstance(spec, str):
    spec = {"case": spec}
if spec.get("spawn"):
    # A stand-in browser: a grandchild that outlives this process unless its group is killed.
    child = subprocess.Popen(
        [sys.executable, "-c", f"import time; time.sleep({float(spec['spawn'])})"]
    )
    (HERE / "grandchild.pid").write_text(str(child.pid))
if spec.get("sleep"):
    time.sleep(spec["sleep"])
if spec.get("signal"):
    os.kill(os.getpid(), spec["signal"])
case = responses[spec.get("case", "plain")]
sys.stdout.write(spec.get("stdout", case["stdout"]))
sys.exit(spec.get("rc", case["rc"]))
