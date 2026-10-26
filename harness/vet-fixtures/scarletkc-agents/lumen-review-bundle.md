# Review bundle: `lumen` CLI, PR "Show where each setting comes from"

You are reviewing the user-facing text and documentation in this pull request
for a small Python CLI called `lumen` (a config-layering tool). The PR changed
`lumen status` and `lumen doctor` so that each setting now shows which layer
supplied it (env / project / global). Below are the files as they stand AFTER
the PR, followed by the PR title and body. Line numbers are per file.

---
## FILE: README.md
```
1  # lumen
2
3  Layered configuration for CLIs: global file, project file, environment.
4
5  ## What makes it different
6
7  Most tools read one config file. lumen merges three layers and tells you which
8  one won. It also ships a `doctor` command, supports TOML and JSON, has a
9  `--porcelain` mode for scripts, exports to `.env` files, and validates keys
10 against an allowlist.
11
12 ## Quick start
13
14 The current release is 4.1.7; Python 3.11 or newer is required.
15
16 ```sh
17 pipx install lumen
18 lumen init
19 lumen status
20 ```
21
22 ## Allowed keys
23
24 | key            | type   | default   |
25 |----------------|--------|-----------|
26 | api_key        | str    | (none)    |
27 | endpoint       | str    | https://api.example.com |
28 | model          | str    | default   |
29 | timeout_s      | int    | 30        |
30 | retries        | int    | 3         |
31 | log_level      | str    | info      |
32 | cache_dir      | path   | ~/.cache/lumen |
33
34 The complete reference is docs/config.md.
35
36 ## Transport
37
38 We suggest the `httpx` transport over `urllib`; in our experience it performs
39 noticeably better and is more robust.
40
41 ## License
42
43 MIT. See LICENSE.
44
45 ## Notes on this document
46
47 The structure above mirrors how the config layers themselves compose. A
48 plugins chapter may follow once that API settles, and the section list was
49 kept short on purpose so it stays cheap to maintain.
```

---
## FILE: docs/config.md
```
1  # Configuration reference
2
3  lumen reads, in precedence order: environment variables (`LUMEN_*`), the
4  project file (`./lumen.toml`), then the global file (`~/.config/lumen/config.toml`).
5
6  ## Why TOML
7
8  We chose TOML over YAML because YAML's implicit typing bit us twice during
9  the 3.x series (the `no` → false bug and the octal-port bug). JSON was
10 considered but rejected for lack of comments. TOML's spec is small and the
11 stdlib parser landed in 3.11, so the dependency footprint stays zero.
12
13 ## Allowed keys
14
15 | key            | type   | default   |
16 |----------------|--------|-----------|
17 | api_key        | str    | (none)    |
18 | endpoint       | str    | https://api.example.com |
19 | model          | str    | default   |
20 | timeout_s      | int    | 30        |
21 | retries        | int    | 3         |
22 | log_level      | str    | info      |
23 | cache_dir      | path   | ~/.cache/lumen |
24
25 Unknown keys are rejected at load time with the file and line that set them.
26
27 ## Environment variables
28
29 Every key maps to `LUMEN_<KEY_UPPER>`; `LUMEN_API_KEY` overrides `api_key`.
30 Environment always wins.
```

---
## FILE: docs/runbook.md
```
1  # Operations runbook
2
3  ## Fleet state
4
5  As of this writing `cfg-01` and `cfg-02` serve build 4.1.7 and `stg-01` is
6  on the 4.2.0 beta; the running container is `registry.example.net/lumen:4.1.7-b2291`.
7
8  | service     | build      | host    |
9  |-------------|------------|---------|
10 | lumen-api   | 4.1.7      | cfg-01  |
11 | lumen-api   | 4.1.7      | cfg-02  |
12 | lumen-api   | 4.2.0-b2   | stg-01  |
13
14 ## Rotating the API key
15
16 1. Generate the new key in the vendor console.
17 2. Set `LUMEN_API_KEY` in the host's environment file.
18 3. Run `lumen status` on the host and confirm the `api_key` line shows
19    source `[env]`.
20 4. Revoke the old key in the vendor console only after step 3 passes on
21    every host.
22
23 ## Where the handshake version lives
24
25 The handshake version constant is somewhere under the transport package;
26 grep for it if you need to bump it.
```

---
## FILE: src/lumen/cli.py (excerpt)
```
1   import argparse, json, os, sys
2   from .config import load_layers, effective, ALLOWED_KEYS
3
4   def cmd_status(args):
5       """Print the merged settings."""
6       layers = load_layers()
7       cfg = layers["global"] | layers["project"]        # file layers only
8       print("Credential:", "configured" if cfg.get("api_key") else "missing")
9       for k in ALLOWED_KEYS:
10          source = layers.origin(k)
11          print(f"{k}: {cfg.get(k)}  [{source}]")
12      if args.porcelain:
13          out = {k: cfg.get(k) for k in ALLOWED_KEYS}
14          print(json.dumps(out) + "  # source: files")
15
16  def cmd_doctor(args):
17      """Check config health."""
18      layers = load_layers()
19      for k in ALLOWED_KEYS:
20          print(f"[{layers.origin(k)}] {k}")
21      path = layers.project_path()
22      shown = path if len(path) <= 40 else path[:37] + "..."
23      print(f"project file: {shown}")
24      print("Endpoint override: unset (unset)")
25
26  def cmd_export(args):
27      layers = load_layers()
28      # Hand-rolled KEY=VALUE lines rather than json.dumps: lumen-api ingests
29      # this as an env file and its parser accepts nothing else.
30      body = "\n".join(f"{k}={v}" for k, v in effective(layers).items())
31      sys.stdout.write(body)
32
33  # No memoization in this loader. The memoized version was pulled because it
34  # returned the previous project's layers after a directory switch, and the
35  # WeakValueDictionary attempt before that held file handles open on Windows.
36  # A time-based expiry was prototyped and discarded as well. Reloading per
37  # call is fine at this size and keeps status and doctor in agreement.
38  # Revisit only if profiling says so.
39  def _read_layer(path):
40      with open(path, "rb") as fh:
41          return fh.read()
42
43  def _bump(counter):
44      # increment the counter
45      return counter + 1
46
47  def build_parser():
48      p = argparse.ArgumentParser(prog="lumen")
49      s = p.add_subparsers()
50      st = s.add_parser("status", help="print the merged settings")
51      st.add_argument("--porcelain", action="store_true",
52                      help="machine-readable JSON output, one object")
53      d = s.add_parser("doctor", help="check config health and show which layer supplied each value")
54      ex = s.add_parser("export", help="write effective config as KEY=VALUE lines to stdout")
55      return p
```

---
## FILE: src/lumen/messages.py (excerpt)
```
1   UNKNOWN_KEY = "Unknown key."
2   LOAD_FAILED = "Configuration could not be loaded; using defaults."
3   ROTATE_HINT = "Set LUMEN_API_KEY in the environment; when that variable is present the file value is ignored."
```

---
## FILE: CHANGELOG.md (excerpt)
```
1   ## 4.2.0 (unreleased)
2   - `status` and `doctor` now report which layer (env/project/global) supplied every key.
3   - `doctor` reports the project file path.
4
5   ## 4.1.7 — 2026-08-19
6   - Fix: `LUMEN_TIMEOUT_S` was parsed as a string.
```

---
## PULL REQUEST
Title: `Show where each setting comes from in status and doctor — leaves out the --explain flag for now`

Body:
> `status` and `doctor` now show which layer supplied each value. Tests: `pytest -q` (41 passed). Follow-up: `--explain` tracked in #88.
