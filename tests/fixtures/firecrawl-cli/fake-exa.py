#!/usr/bin/env python3
"""Offline credential-source probe; reject every command except --where."""

import os
import sys
import time

assert sys.argv[1:] == ["--where"], sys.argv
time.sleep(float(os.environ.get("EXA_TEST_SLEEP", "0")))
print(os.environ.get("EXA_TEST_SOURCE", "env"))
sys.exit(int(os.environ.get("EXA_TEST_EXIT", "0")))
