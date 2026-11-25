#!/usr/bin/env python3
"""scripts/comment-check.py and scripts/comment-check-hook.sh, on synthetic repositories.

A fake `claude` (COMMENT_CHECK_CLAUDE) stands in for the model: it labels each unit from a
keyword in its text and logs its argv and environment, so these tests pin the extractor, the
tool-directive filter, the flag rule, chunking, the isolation flags and every hook path. A fake
`gh` (COMMENT_CHECK_GH) answers `pr view` with the checkout's HEAD unless a test names a head. The
labeller's quality is not measured here; that needs real comments with audited verdicts and
runs against the real model (`--label`, issue #895).
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "comment-check.py"
GATE = ROOT / "scripts" / "comment-check-hook.sh"

FAKE = f"""#!{sys.executable}
import json, os, sys, time
log = os.environ.get("FAKE_CLAUDE_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps({{"args": sys.argv[1:], "mds": os.environ.get("CLAUDE_CODE_DISABLE_CLAUDE_MDS")}}) + "\\n")
mode = os.environ.get("FAKE_CLAUDE_MODE", "ok")
if mode == "fail":
    print("boom", file=sys.stderr)
    sys.exit(1)
if mode == "hang":
    time.sleep(60)
units = json.loads(sys.stdin.read().split("Units:\\n", 1)[1])
labels = []
for u in units:
    t = u["text"]
    if mode == "drop" and "vendor" in t:
        continue
    lab = "D"
    if "increment" in t:
        lab = "T"
    elif "used to" in t:
        lab = "H"
    elif "=====" in t:
        lab = "S"
    elif "TODO" in t:
        lab = "E"
    labels.append({{"id": u["id"], "label": lab, "ticket": "#" in t}})
print(json.dumps({{"subtype": "success", "is_error": False, "total_cost_usd": 0.001,
                  "modelUsage": {{"fake-model": {{}}}}, "structured_output": {{"labels": labels}}}}))
"""

FAKE_GH = f"""#!{sys.executable}
import json, os, subprocess, sys
log = os.environ.get("FAKE_GH_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\\n")
mode = os.environ.get("FAKE_GH_MODE", "ok")
if mode == "fail" or sys.argv[1:3] != ["pr", "view"] or sys.argv[4:] != ["--json", "headRefOid,baseRefName"]:
    print("boom", file=sys.stderr)
    sys.exit(1)
if mode == "junk":
    print("not json")
    sys.exit(0)
head = os.environ.get("FAKE_GH_HEAD") or subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True,
                                                       text=True, check=True).stdout.strip()
print(json.dumps({{"headRefOid": head, "baseRefName": os.environ.get("FAKE_GH_BASE", "main")}}))
"""

FILES = {
    "app.py": """\
        import os  # noqa: F401
        # increment the counter
        count = 0
        # The vendor drops the first request after idle, so send twice.
        send()
        x = "# not a comment"
        y = 1  # used to be 2 before the refactor
        """,
    "web.ts": """\
        // ===== helpers =====
        export function f() {
          // TODO fix this later
          let a = 1;
          // TODO(#12) drop once the API ships v2
          const url = "http://example.com";
          // eslint-disable-next-line no-console
          console.log(a, url);
        }
        /* SPDX-License-Identifier: MIT */
        """,
    "schema.sql": """\
        -- increment the version
        UPDATE meta SET v = v + 1;
        """,
    "vendor/lib.js": "// increment\nvar x = 1;\n",
    "types.d.ts": "// increment\nexport type X = number;\n",
}


def load_module():
    spec = importlib.util.spec_from_file_location("cc", SCRIPT)
    cc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cc)
    return cc


def git(cwd, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True, env=env)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="comment-check-"))
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "README.md").write_text("base\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "base")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        git(self.repo, "remote", "add", "origin", "https://github.com/acme/widget.git")
        git(self.repo, "checkout", "-q", "-b", "feature")
        for name, body in FILES.items():
            p = self.repo / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(textwrap.dedent(body))
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "feature")
        self.fake = self.tmp / "fake-claude"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o755)
        self.log = self.tmp / "claude.log"
        self.fake_gh = self.tmp / "fake-gh"
        self.fake_gh.write_text(FAKE_GH)
        self.fake_gh.chmod(0o755)
        self.gh_log = self.tmp / "gh.log"
        self.env = dict(os.environ, COMMENT_CHECK_CLAUDE=str(self.fake), FAKE_CLAUDE_LOG=str(self.log),
                        COMMENT_CHECK_GH=str(self.fake_gh), FAKE_GH_LOG=str(self.gh_log))
        for name in ("HOOK_DISABLED", "FAKE_GH_MODE", "FAKE_GH_HEAD", "FAKE_GH_BASE"):
            self.env.pop(name, None)

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)], check=False)

    def cli(self, *args, env=None, stdin=None):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], check=False, capture_output=True, text=True,
                              env=env or self.env, input=stdin, cwd=self.repo, timeout=60)

    def payload(self, command="gh pr create --fill", stdout="https://github.com/acme/widget/pull/7\n", cwd=None):
        return json.dumps({"tool_name": "Bash", "tool_input": {"command": command},
                           "tool_response": {"stdout": stdout, "stderr": "", "interrupted": False},
                           "cwd": str(cwd or self.repo)})

    def calls(self):
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []


class Extract(Base):
    def test_units_skip_paths_and_filter(self):
        p = self.cli("--extract-only")
        self.assertEqual(p.returncode, 0, p.stderr)
        r = json.loads(p.stdout)
        got = {(u["file"], u["line"], u["kind"]) for u in r["units_list"]}
        self.assertEqual(got, {
            ("app.py", 2, "block"), ("app.py", 4, "block"), ("app.py", 7, "trailing"),
            ("web.ts", 1, "block"), ("web.ts", 3, "block"), ("web.ts", 5, "block"), ("schema.sql", 1, "block")})
        # The three tool directives (noqa, eslint-disable, SPDX) are dropped; vendor/ and .d.ts are skipped.
        self.assertEqual((r["units"], r["tool_directives"], r["checked"]), (10, 3, 7))
        self.assertEqual(self.calls(), [], "extract-only must not call the model")
        unit = next(u for u in r["units_list"] if u["line"] == 4)
        self.assertIn("send()", unit["after"])
        self.assertIn("count = 0", unit["before"])

    def test_shebang_is_not_a_comment_and_coding_line_is_a_directive(self):
        cc = load_module()
        diff = textwrap.dedent("""\
            diff --git a/tool.py b/tool.py
            new file mode 100644
            --- /dev/null
            +++ b/tool.py
            @@ -0,0 +1,4 @@
            +#!/usr/bin/env python3
            +# -*- coding: utf-8 -*-
            +x = 1
            +# increment x
            """)
        units = cc.units_from_diff(diff)
        self.assertEqual([(u["line"], u["text"]) for u in units],
                         [(2, "# -*- coding: utf-8 -*-"), (4, "# increment x")])
        self.assertEqual([cc.tool_directive(u) for u in units], [True, False])

    def test_directive_filter_spares_prose(self):
        cc = load_module()
        directive = ["# noqa: E501", "# type: ignore[attr-defined]", "// @ts-expect-error untyped lib",
                     "# shellcheck disable=SC2086", "/* eslint-disable */", "// biome-ignore lint: x",
                     "//go:build linux", "# pragma: no cover", "# Copyright 2026 Example"]
        prose = ["# a pragmatic fallback for slow disks", "// eslint cannot see through this proxy",
                 "# the global lock is held here", "// generated ids are never reused"]
        for t in directive:
            self.assertTrue(cc.tool_directive({"kind": "block", "text": t, "file": "x.py"}), t)
        for t in prose:
            self.assertFalse(cc.tool_directive({"kind": "block", "text": t, "file": "x.py"}), t)
        trailing = {"kind": "trailing", "text": "import os  # noqa: F401", "file": "x.py"}
        self.assertTrue(cc.tool_directive(trailing))
        self.assertEqual(cc.comment_part(trailing), "# noqa: F401")


class Label(Base):
    def test_flags_follow_the_clutter_rule(self):
        p = self.cli("--json")
        self.assertEqual(p.returncode, 0, p.stderr)
        r = json.loads(p.stdout)
        got = {(f["file"], f["line"], f["kind"]) for f in r["flags"]}
        # Only T, S and X are flagged. The history comment (H), both TODOs (E, with and without a
        # ticket) and the reason (D) are labelled but not flagged.
        self.assertEqual(got, {("app.py", 2, "T"), ("web.ts", 1, "S"), ("schema.sql", 1, "T")})
        self.assertEqual(r["model"], "fake-model")

    def test_isolation_flags_and_env(self):
        self.cli("--json")
        (call,) = self.calls()
        a = call["args"]
        self.assertEqual(call["mds"], "1")
        self.assertEqual(a[a.index("--model") + 1], "haiku")
        self.assertEqual(a[a.index("--tools") + 1], "")
        self.assertEqual(a[a.index("--setting-sources") + 1], "")
        for flag in ("-p", "--strict-mcp-config", "--no-session-persistence"):
            self.assertIn(flag, a)
        self.assertEqual(json.loads(a[a.index("--settings") + 1]), {"disableAllHooks": True})
        schema = json.loads(a[a.index("--json-schema") + 1])
        self.assertEqual(schema["properties"]["labels"]["minItems"], 7)

    def test_missing_ids_are_unlabelled_not_flagged(self):
        env = dict(self.env, FAKE_CLAUDE_MODE="drop")
        r = json.loads(self.cli("--json", env=env).stdout)
        self.assertEqual(r["unlabelled"], 1)
        self.assertEqual(len(r["flags"]), 3)

    def test_labeller_failure_exits_3(self):
        env = dict(self.env, FAKE_CLAUDE_MODE="fail")
        p = self.cli(env=env)
        self.assertEqual(p.returncode, 3)
        self.assertIn("labeller exited 1", p.stderr)
        self.assertIn("nothing was checked", p.stderr)
        self.assertNotIn("no clutter flagged", p.stdout)

    def test_chunks_of_40_cover_every_unit(self):
        units = [{"id": f"U{i:03d}", "file": "a.py", "kind": "block", "text": f"# increment {i}", "before": "",
                  "after": "i += 1"} for i in range(85)]
        f = self.tmp / "units.json"
        f.write_text(json.dumps(units))
        p = self.cli("--label", str(f))
        self.assertEqual(p.returncode, 0, p.stderr)
        r = json.loads(p.stdout)
        self.assertEqual((len(r["labels"]), r["chunks"]), (85, 3))
        sizes = [json.loads(c["args"][c["args"].index("--json-schema") + 1])["properties"]["labels"]["minItems"]
                 for c in self.calls()]
        self.assertEqual(sorted(sizes), [5, 40, 40])


class Hook(Base):
    def hook(self, payload, env=None):
        p = self.cli("--hook", env=env, stdin=payload)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def test_pr_create_success_returns_context(self):
        out = json.loads(self.hook(self.payload()))
        ctx = out["hookSpecificOutput"]
        self.assertEqual(ctx["hookEventName"], "PostToolUse")
        self.assertIn("3 of the 7 comments", ctx["additionalContext"])
        self.assertIn("- web.ts:1 banner or separator: // ===== helpers =====", ctx["additionalContext"])
        self.assertNotIn("TODO", ctx["additionalContext"])
        self.assertIn("nothing was changed", ctx["additionalContext"])

    def test_pr_head_and_base_come_from_gh(self):
        self.hook(self.payload())
        self.assertEqual([json.loads(x) for x in self.gh_log.read_text().splitlines()],
                         [["pr", "view", "https://github.com/acme/widget/pull/7", "--json", "headRefOid,baseRefName"]])
        # A base at the head adds nothing, so the PR's base, not origin/HEAD, is what was diffed.
        git(self.repo, "update-ref", "refs/remotes/origin/release", "HEAD")
        self.assertEqual(self.hook(self.payload(), env=dict(self.env, FAKE_GH_BASE="release")), "")
        self.assertEqual(len(self.calls()), 1)

    def test_other_checkout_of_the_repo_reads_the_pr_head(self):
        # The payload's cwd is the session's folder, which a `cd` out of it does not change.
        feature = git(self.repo, "rev-parse", "HEAD").stdout.strip()
        other = self.tmp / "other"
        git(self.repo, "worktree", "add", "-q", "-b", "other", str(other), "main")
        (other / "o.py").write_text("x = 1\n# increment x in the other checkout\n")
        git(other, "add", "-A")
        git(other, "commit", "-q", "-m", "other")
        out = self.hook(self.payload(cwd=other), env=dict(self.env, FAKE_GH_HEAD=feature))
        ctx = json.loads(out)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("3 of the 7", ctx)
        self.assertNotIn("other checkout", ctx)

    def test_silent_paths(self):
        cases = {
            "other command": self.payload(command="git push -u origin feature"),
            "create failed": self.payload(stdout="pull request create failed: GraphQL error\n"),
            "other repo": self.payload(stdout="https://github.com/other/thing/pull/7\n"),
            "not json": "{",
            "other tool": json.dumps({"tool_name": "Read", "tool_input": {}}),
        }
        for name, payload in cases.items():
            self.assertEqual(self.hook(payload), "", name)
        self.assertFalse(self.gh_log.exists(), "these paths end before asking gh")
        gh_cases = {"gh fails": {"FAKE_GH_MODE": "fail"}, "gh answers junk": {"FAKE_GH_MODE": "junk"},
                    "head not here": {"FAKE_GH_HEAD": "0" * 40}, "base not here": {"FAKE_GH_BASE": "nowhere"}}
        for name, extra in gh_cases.items():
            self.assertEqual(self.hook(self.payload(), env=dict(self.env, **extra)), "", name)
        self.assertEqual(self.calls(), [], "no silent path may call the model")

    def test_disabled_failing_and_hanging_labeller_are_silent(self):
        self.assertEqual(self.hook(self.payload(), env=dict(self.env, HOOK_DISABLED="x,post:bash:comment-check")), "")
        self.assertEqual(self.hook(self.payload(), env=dict(self.env, FAKE_CLAUDE_MODE="fail")), "")
        env = dict(self.env, FAKE_CLAUDE_MODE="hang", COMMENT_CHECK_CALL_TIMEOUT="2")
        self.assertEqual(self.hook(self.payload(), env=env), "")

    def test_no_comments_is_silent(self):
        git(self.repo, "checkout", "-q", "-b", "plain", "main")
        (self.repo / "b.py").write_text("x = 1\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "plain")
        self.assertEqual(self.hook(self.payload()), "")
        self.assertEqual(self.calls(), [])


class Gate(Base):
    def gate(self, payload, path):
        env = dict(self.env, PATH=path)
        return subprocess.run(["sh", str(GATE)], check=False, input=payload, capture_output=True, text=True, env=env,
                              cwd=self.repo, timeout=60)

    def test_gate_skips_python_without_both_words(self):
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        marker = self.tmp / "python-started"
        fake_py = bin_dir / "python3"
        fake_py.write_text(f"#!/bin/sh\ncat >/dev/null\n: > '{marker}'\n")
        fake_py.chmod(0o755)
        path = f"{bin_dir}:/usr/bin:/bin"
        for payload in (self.payload(command="ls"), json.dumps({"tool_input": {"command": "gh issue create"}})):
            p = self.gate(payload, path)
            self.assertEqual((p.returncode, p.stdout), (0, ""))
            self.assertFalse(marker.exists())
        p = self.gate(self.payload(), path)
        self.assertEqual(p.returncode, 0)
        self.assertTrue(marker.exists(), "a pr create payload must reach Python")

    def test_gate_end_to_end_and_fails_open(self):
        path = f"{Path(sys.executable).parent}:/usr/bin:/bin"
        out = json.loads(self.gate(self.payload(), path).stdout)
        self.assertIn("3 of the 7", out["hookSpecificOutput"]["additionalContext"])
        bin_dir = self.tmp / "bin2"
        bin_dir.mkdir()
        broken = bin_dir / "python3"
        broken.write_text("#!/bin/sh\ncat >/dev/null\necho broken >&2\nexit 9\n")
        broken.chmod(0o755)
        p = self.gate(self.payload(), f"{bin_dir}:/usr/bin:/bin")
        self.assertEqual((p.returncode, p.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
