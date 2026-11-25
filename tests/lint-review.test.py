#!/usr/bin/env python3
"""scripts/lint-review.py: every label has one known answer in a planted fixture.

The hermetic cases run a stub ruff and a stub oxlint, so they need only git and python3. The parity case runs the
real ruff when it is on PATH and prints a skip line when it is not: it checks the two calls the stub cannot
(ruff's sys.path exemption makes a noqa dead; a path computed into a variable first keeps it live).
"""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/lint-review.py"
spec = importlib.util.spec_from_file_location("lint_review", SCRIPT)
lint_review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint_review)

STUB_RUFF = r'''
import json, os, sys
args = sys.argv[1:]
if args == ["--version"]:
    print("ruff 0.0.0 (stub)"); sys.exit(0)
if args[:1] == ["rule"]:
    print(json.dumps([{"code": c} for c in ("E402", "F401", "F821", "RUF100")])); sys.exit(0)
files = [a for a in args if a.endswith(".py")]
skipped = lambda f: "/skip/" in "/" + f
if "--show-files" in args:
    for f in files:
        if not skipped(f):
            print(os.path.abspath(f))
    sys.exit(0)
select = args[args.index("--select") + 1].split(",") if "--select" in args else []
out = []
for f in files:
    if skipped(f):
        continue
    p = os.path.abspath(f)
    lines = open(p, encoding="utf-8").read().splitlines()
    if any("SYNTAXERR" in line for line in lines):
        out.append({"code": "invalid-syntax", "message": "stub", "filename": p, "location": {"row": 1}})
        continue
    for i, line in enumerate(lines, 1):
        if "noqa:" in line and "E402" in line:  # the stub's config leaves E402 off, so every E402 noqa is unused
            out.append({"code": "RUF100", "message": "Unused `noqa` directive (non-enabled: `E402`)",
                        "filename": p, "location": {"row": i}})
        if "F821" in select and "undefined_thing" in line:
            out.append({"code": "F821", "message": "Undefined name", "filename": p, "location": {"row": i}})
print(json.dumps(out))
'''

STUB_OXLINT = r'''
import json, sys
diags = []
for f in [a for a in sys.argv[1:] if a.endswith((".ts", ".js"))]:
    for i, line in enumerate(open(f, encoding="utf-8").read().splitlines(), 1):
        if "debugger" in line:
            diags.append({"code": "eslint(no-debugger)", "message": "stub", "filename": f,
                          "labels": [{"span": {"line": i}}]})
print(json.dumps({"diagnostics": diags}))
'''

STAMPED = "// TODO(logger): sync context\n// eslint-disable-next-line no-console\nconsole.log(1);\n"


def plant(root, files, track=True):
    root.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True)
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(textwrap.dedent(text).lstrip("\n"), encoding="utf-8")
    if track:
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, capture_output=True)
    return root


def run_script(*args):
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False)


class Hermetic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="lint-review-test-"))
        bin_dir = cls.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "ruff.py").write_text(STUB_RUFF, encoding="utf-8")
        (bin_dir / "oxlint.py").write_text(STUB_OXLINT, encoding="utf-8")
        cls.ruff = f"{sys.executable} -I {bin_dir / 'ruff.py'}"
        cls.oxlint = f"{sys.executable} -I {bin_dir / 'oxlint.py'}"
        fleet = cls.tmp / "fleet"
        plant(fleet / "alpha", {
            "pyproject.toml": '[tool.ruff.lint]\nselect = ["E", "F"]\n\n[dependency-groups]\ndev = ["ruff==0.15.0"]\n',
            "a.py": """
                import os  # noqa: E402
                import re  # noqa: F401
                import json  # noqa: E402, F401
                # The vendored module path must load first
                import csv  # noqa: F401
                import ast  # noqa: ZZZ999
                x = 1  # noqa
                import io  # noqa: F401 E402
            """,
            "skip/b.py": "import os  # noqa: F401\n",
            "bad.py": "SYNTAXERR\nimport os  # noqa: F401\n",
            "dist/gen.py": "import os  # noqa: F401\n",
            "web/x1.ts": STAMPED, "web/x2.ts": STAMPED, "web/x3.ts": STAMPED,
            "web/y.ts": """
                // eslint-disable-next-line no-console -- debug output for the CLI
                console.log(2);
                const z = 3;
                // eslint-disable-next-line no-console
                console.log(z);
            """,
            "run.sh": "# shellcheck disable=SC2086,SC2034\necho $x\n",
            "c.py": "print(undefined_thing)\nprint(undefined_thing)\nprint(undefined_thing)\n",
            "web/d.ts": "debugger;\n",
        })
        (fleet / "alpha" / "untracked.py").write_text("import os  # noqa: F401\n", encoding="utf-8")
        plant(fleet / "beta", {
            "ruff.toml": "line-length = 100\n",
            "c.py": "print(undefined_thing)\nprint(undefined_thing)\n",
            "web/d.ts": "debugger;\ndebugger;\n",
        })
        (fleet / "not-a-repo").mkdir()
        (fleet / "not-a-repo" / "e.py").write_text("import os  # noqa: F401\n", encoding="utf-8")
        cls.fleet = fleet
        cls.json = cls.tmp / "out.json"
        r = run_script("suppressions", str(fleet), "--ruff", cls.ruff, "--stamp-min", "3", "--json", str(cls.json))
        if r.returncode != 0:
            raise AssertionError(f"suppressions exited {r.returncode}: {r.stderr}")
        cls.stdout = r.stdout
        cls.data = json.loads(cls.json.read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def site(self, file, line, rule):
        hits = [s for s in self.data["sites"] if (s["file"], s["line"], s["rule"]) == (file, line, rule)]
        self.assertEqual(len(hits), 1, f"{file}:{line} {rule}: {hits}")
        return hits[0]

    def test_ruff_liveness(self):
        self.assertEqual(self.site("a.py", 1, "E402")["state"], "dead")
        self.assertEqual(self.site("a.py", 2, "F401")["state"], "live")
        self.assertEqual(self.site("a.py", 3, "E402")["state"], "dead")
        self.assertEqual(self.site("a.py", 3, "F401")["state"], "live")
        self.assertEqual(self.site("a.py", 6, "ZZZ999")["state"], "unknown-code")
        self.assertEqual(self.site("a.py", 7, lint_review.ALL_RULES)["state"], "live")
        self.assertEqual(self.site("skip/b.py", 1, "F401")["state"], "unchecked")
        self.assertEqual(self.site("bad.py", 2, "F401")["state"], "unparsed")

    def test_space_separated_codes(self):
        self.assertEqual(self.site("a.py", 8, "F401")["state"], "live")
        self.assertEqual(self.site("a.py", 8, "E402")["state"], "dead")

    def test_reasons(self):
        self.assertEqual(self.site("a.py", 1, "E402")["reason"], "none")
        above = self.site("a.py", 5, "F401")
        self.assertEqual(above["reason"], "line-above")
        self.assertEqual(above["reason_text"], "The vendored module path must load first")
        self.assertEqual(self.site("web/y.ts", 1, "no-console")["reason"], "same-line")
        self.assertEqual(self.site("web/y.ts", 4, "no-console")["reason"], "none")
        for f in ("web/x1.ts", "web/x2.ts", "web/x3.ts"):
            s = self.site(f, 2, "no-console")
            self.assertEqual((s["reason"], s["state"]), ("stamp", "not-measured"))

    def test_rule_rollup(self):
        rows = {r["rule"]: r for r in self.data["rules"]}
        nc = rows["eslint:no-console"]
        self.assertEqual(nc["sites"], 5)
        self.assertEqual(nc["open_reasonless"], 1)
        self.assertEqual(nc["reasons"], {"stamp": 3, "same-line": 1, "none": 1})
        self.assertEqual(rows["ruff:E402"]["states"], {"dead": 3})
        self.assertEqual(rows["ruff:E402"]["open_reasonless"], 0)
        self.assertEqual(rows["shellcheck:SC2086"]["sites"], 1)
        self.assertEqual(rows["shellcheck:SC2034"]["sites"], 1)

    def test_scope(self):
        files = {s["file"] for s in self.data["sites"]}
        self.assertNotIn("dist/gen.py", files)
        self.assertNotIn("untracked.py", files)
        self.assertEqual({r["repo"] for r in self.data["repos"]}, {"alpha", "beta"})

    def test_repo_profile(self):
        repos = {r["repo"]: r for r in self.data["repos"]}
        self.assertEqual(repos["alpha"]["ruff_configs"], ["pyproject.toml: pins select"])
        self.assertEqual(repos["alpha"]["ruff_pins"], ["==0.15.0 (pyproject.toml)"])
        self.assertEqual(repos["beta"]["ruff_configs"], ["ruff.toml: defaults"])
        self.assertIn("ruff 0.0.0 (stub)", self.stdout)

    def test_admit_sample_is_seeded_and_spread(self):
        outs = []
        for name in ("s1.json", "s2.json"):
            out = self.tmp / name
            r = run_script("admit", str(self.fleet), "--rules", "ruff:F821,oxlint:no-debugger", "--out", str(out),
                           "--per-rule", "2", "--seed", "7", "--ruff", self.ruff, "--oxlint", self.oxlint)
            self.assertEqual(r.returncode, 0, r.stderr)
            outs.append(json.loads(out.read_text(encoding="utf-8")))
        self.assertEqual(outs[0], outs[1])
        f821 = outs[0]["rules"]["ruff:F821"]
        self.assertEqual((f821["hits"], f821["repos"]), (5, {"alpha": 3, "beta": 2}))
        self.assertEqual(sorted(h["repo"] for h in f821["sample"]), ["alpha", "beta"])
        self.assertIn("undefined_thing", f821["sample"][0]["snippet"])
        ox = outs[0]["rules"]["oxlint:no-debugger"]
        self.assertEqual((ox["hits"], ox["repos"]), (3, {"alpha": 1, "beta": 2}))

    def test_admit_rejects_unprefixed_rules(self):
        r = run_script("admit", str(self.fleet), "--rules", "F821", "--out", str(self.tmp / "x.json"))
        self.assertNotEqual(r.returncode, 0)

    def test_missing_ruff_is_an_error_not_a_silent_skip(self):
        r = run_script("suppressions", str(self.fleet), "--ruff", "no-such-ruff-binary")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("ruff not found", r.stderr)


class Score(unittest.TestCase):
    R, L, F = "real_defect", "latent_risk", "false_positive"

    def test_bands(self):
        R, L, F = self.R, self.L, self.F
        self.assertEqual(lint_review.band([R, L, L, L, F]), "ADMIT")
        self.assertEqual(lint_review.band([L, L, L, L, F]), "UNDETERMINED")
        self.assertEqual(lint_review.band([R, L, L, F, F]), "UNDETERMINED")
        self.assertEqual(lint_review.band([R, F, F, F, F]), "NOISE")
        self.assertEqual(lint_review.band([F] * 5), "NOISE")
        self.assertEqual(lint_review.band([R, R, R, R]), "UNDETERMINED")

    def test_cli(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "labels.json"
            p.write_text(json.dumps({"ruff:F821": [self.R] * 5, "oxlint:x": [self.F] * 5}), encoding="utf-8")
            r = run_script("score", str(p))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn("ruff:F821 | 5 | 5 | 0 | 0 | ADMIT", r.stdout)
            self.assertIn("oxlint:x | 5 | 0 | 0 | 5 | NOISE", r.stdout)
            p.write_text(json.dumps({"ruff:F821": ["maybe"]}), encoding="utf-8")
            self.assertNotEqual(run_script("score", str(p)).returncode, 0)


@unittest.skipUnless(shutil.which("ruff"), "ruff not on PATH")
class RealRuffParity(unittest.TestCase):
    def test_sys_path_exemption_and_config_scope(self):
        with tempfile.TemporaryDirectory() as d:
            repo = plant(Path(d) / "repo", {
                "ruff.toml": 'extend-exclude = ["skip"]\n[lint]\nselect = ["E402", "F401"]\n',
                "a.py": """
                    import sys
                    sys.path.insert(0, "/x")
                    import json  # noqa: E402
                    from pathlib import Path
                    ROOT = Path(__file__).parent
                    import os  # noqa: E402
                    print(json, os, ROOT)
                """,
                "sub/ruff.toml": '[lint]\nselect = ["F"]\n',
                "sub/b.py": "x = 1\nimport os  # noqa: E402\nprint(os, x)\n",
                "skip/c.py": "x = 1\nimport os  # noqa: E402\nprint(os, x)\n",
            })
            out = Path(d) / "out.json"
            r = run_script("suppressions", str(repo), "--json", str(out))
            self.assertEqual(r.returncode, 0, r.stderr)
            sites = {(s["file"], s["line"]): s["state"] for s in json.loads(out.read_text())["sites"]}
            self.assertEqual(sites[("a.py", 3)], "dead")   # ruff exempts imports after a direct sys.path edit
            self.assertEqual(sites[("a.py", 6)], "live")   # ...but not after a computed path
            self.assertEqual(sites[("sub/b.py", 2)], "dead")  # the nearest config does not enable E402
            self.assertEqual(sites[("skip/c.py", 2)], "unchecked")


if __name__ == "__main__":
    if not shutil.which("ruff"):
        print("SKIP RealRuffParity: ruff not on PATH; the hermetic cases still run", flush=True)
    unittest.main(verbosity=2)
