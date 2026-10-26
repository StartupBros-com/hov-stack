#!/usr/bin/env python3
"""Public CLI checks: real git objects, fixture gh API (not live GitHub proof)."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

from test_review_rounds import valid_record, marker_body

HELPER = Path(__file__).resolve().parents[1] / "scripts/review-prose-exemption.py"
WORKFLOW = HELPER.parents[1] / "workflows/review-adversarial-first.js"
LENSES = ("own-doctrine", "strongest-lever", "no-op-or-regression")


class ProseExemptionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Execute Collect's actual recipe against real Git; the public helper
        # independently regenerates it, so option drift breaks positive cases.
        source = (
            WORKFLOW.read_text()
            .split("// === ROUNDS:BEGIN ===", 1)[1]
            .split("// === ROUNDS:END ===", 1)[0]
        )
        command = subprocess.run(
            [
                "node",
                "--input-type=module",
                "-e",
                source + "\nprocess.stdout.write(CANONICAL_DIFF)",
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        argv = shlex.split(command)
        if argv[0] != "git":
            raise AssertionError("Collect must capture the canonical Git patch")
        cls.canonical_diff = argv[1:]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="prose-exemption-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.tree = self.root / "tree"
        self.tree.mkdir()
        self.env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        self.git("init", "-q")
        self.git("remote", "add", "origin", "https://github.com/owner/repo.git")
        self.put("README.md", "A human guide.\n")
        self.put("CLAUDE.md", "Operational instructions.\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.put("README.md", "A clearer human guide.\n")
        self.commit()
        self.fixture = self.root / "api.json"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['PROSE_API_FIXTURE'])
f = json.loads(p.read_text())
a = sys.argv[1:]
if a[:1] != ['api']:
    sys.exit('unexpected gh write or command: ' + repr(a))
if 'user' in a:
    print(7)
elif any('/comments' in x for x in a):
    if f.get('fail_comments'):
        sys.exit('fixture API unavailable')
    for c in f['comments']:
        print(json.dumps(c))
elif any('/pulls/' in x for x in a):
    count = p.with_suffix('.count')
    n = int(count.read_text()) if count.exists() else 0
    count.write_text(str(n + 1))
    print(json.dumps(f.get('after', f['metadata']) if n else f['metadata']))
else:
    sys.exit('unexpected gh read: ' + repr(a))
''')
        gh.chmod(0o755)
        self.env.update(PATH=str(bin_dir) + os.pathsep + self.env["PATH"],
                        PROSE_API_FIXTURE=str(self.fixture))

    def git(self, *args):
        p = subprocess.run(["git", "-C", str(self.tree), *args], env=self.env,
                           capture_output=True, text=True, check=True)
        return p.stdout

    def put(self, path, text):
        p = self.tree / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        return p

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "change")
        self.head = self.git("rev-parse", "HEAD").strip()

    def captured_patch(self, *options):
        # Hash the actual file bytes, without subprocess text/newline conversion.
        path = self.root / "diff.patch"
        with path.open("wb") as output:
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(self.tree),
                    *options,
                    self.base + "..." + self.head,
                    "--",
                ],
                env=self.env,
                stdout=output,
                stderr=subprocess.PIPE,
                check=True,
            )
        return path.read_bytes()

    def data(self, patch_sha256=None):
        digest = (
            patch_sha256
            or hashlib.sha256(self.captured_patch(*self.canonical_diff)).hexdigest()
        )
        record = valid_record(
            head=self.head,
            ordinary_prose={
                "base": self.base,
                "head": self.head,
                "patch_sha256": digest,
                # Authored CLEAN fixtures exercise the gate, not real model behavior.
                "evidence": [
                    {
                        "lens": lens,
                        "consumer_evidence": "Inspected repository tree and build inputs; README has human readers only. Reviewed patch SHA-256: "
                        + digest,
                    }
                    for lens in LENSES
                ],
            },
        )
        metadata = {
            "number": 12,
            "state": "open",
            "base": {"sha": self.base, "repo": {"full_name": "owner/repo", "id": 1}},
            "head": {"sha": self.head, "repo": {"full_name": "owner/repo", "id": 1}},
        }
        return {"metadata": metadata, "comments": [self.comment(record)]}

    def comment(self, record, cid=1):
        return {"id": cid, "created_at": f"2026-10-02T00:00:{cid:02d}Z", "user": {"id": 7},
                "body": marker_body(record)}

    def run_helper(self, data=None, extra=(), expected=1):
        self.fixture.write_text(json.dumps(data or self.data()))
        self.fixture.with_suffix('.count').write_text('0')
        p = subprocess.run([sys.executable, str(HELPER), "--tree", str(self.tree),
                            "--repo", "owner/repo", "--pr", "12", *extra],
                           env=self.env, capture_output=True, text=True)
        self.assertEqual(p.returncode, expected, (p.stdout, p.stderr))
        result = json.loads(p.stdout)
        self.assertEqual(result["status"], "exempt" if expected == 0 else "required")
        self.assertTrue(result["reason"])
        return result

    def test_real_git_prose_positive(self):
        result = self.run_helper(expected=0, extra=("--head", self.head))
        self.assertEqual((result["base"], result["head"], result["repo"], result["pr"]),
                         (self.base, self.head, "owner/repo", 12))

    def test_textconv_hidden_model_edit_is_not_exempt(self):
        self.put(".gitattributes", "*.md diff=visible\n")
        self.put("README.md", "A human guide.\nMODEL: Check all model outputs.\n")
        self.commit()
        self.base = self.head
        self.git("config", "diff.visible.textconv", "sed '/^MODEL:/d'")
        self.put(
            "README.md",
            "A clearer human guide.\nMODEL: All model review outputs are guaranteed correct.\n",
        )
        self.commit()
        transformed = self.captured_patch("diff", "--no-color")
        canonical = self.captured_patch(*self.canonical_diff)
        self.assertIn(b"+A clearer human guide.", transformed)
        self.assertNotIn(b"MODEL:", transformed)
        self.assertIn(
            b"+MODEL: All model review outputs are guaranteed correct.", canonical
        )
        self.assertEqual(
            self.git("diff", "--name-only", self.base + "..." + self.head),
            "README.md\n",
        )
        self.assertEqual(
            self.git(
                "diff", "--no-textconv", "--name-only", self.base + "..." + self.head
            ),
            "README.md\n",
        )
        transformed_digest = hashlib.sha256(transformed).hexdigest()
        self.assertNotEqual(transformed_digest, hashlib.sha256(canonical).hexdigest())
        result = self.run_helper(self.data(patch_sha256=transformed_digest))
        self.assertIn("patch", result["reason"])

    def test_digest_missing_malformed_or_mismatched(self):
        for digest in (
            None,
            "",
            "a" * 63,
            "A" * 64,
            "z" * 64,
            "a" * 64 + "\n",
            42,
            True,
            [],
            "0" * 64,
        ):
            with self.subTest(digest=digest):
                data = self.data()
                record = json.loads(
                    data["comments"][0]["body"].split("```json\n")[1].split("\n```")[0]
                )
                if digest is None:
                    del record["ordinary_prose"]["patch_sha256"]
                else:
                    record["ordinary_prose"]["patch_sha256"] = digest
                data["comments"] = [self.comment(record)]
                self.run_helper(data)

    def test_textconv_canonical_wording_patch_remains_eligible(self):
        self.put(".gitattributes", "*.md diff=visible\n")
        self.commit()
        self.base = self.head
        self.put("README.md", "An even clearer human guide.\n")
        self.commit()
        self.git("config", "diff.visible.textconv", "sed '/^MODEL:/d'")
        self.run_helper(expected=0)

    def test_replacement_blob_cannot_hide_model_edit(self):
        self.put("README.md", "A human guide.\nMODEL: Check all model outputs.\n")
        self.commit()
        self.base = self.head
        self.put(
            "README.md",
            "A clearer human guide.\nMODEL: All model outputs are guaranteed correct.\n",
        )
        self.commit()
        replacement = self.root / "replacement.txt"
        replacement.write_text(
            "A clearer human guide.\nMODEL: Check all model outputs.\n"
        )
        old = self.git("rev-parse", self.head + ":README.md").strip()
        new = self.git("hash-object", "-w", str(replacement)).strip()
        self.git("replace", old, new)
        transformed = self.captured_patch("diff", "--no-color")
        canonical = self.captured_patch(*self.canonical_diff)
        self.assertIn(b"+A clearer human guide.", transformed)
        self.assertNotIn(b"+MODEL:", transformed)
        self.assertIn(b"+MODEL:", canonical)
        self.assertNotEqual(transformed, canonical)
        result = self.run_helper(
            self.data(patch_sha256=hashlib.sha256(transformed).hexdigest())
        )
        self.assertIn("patch", result["reason"])

    def test_external_driver_is_disabled_for_patch_and_mechanical_checks(self):
        canonical = self.captured_patch(*self.canonical_diff)
        visible = self.root / "visible.patch"
        visible.write_bytes(canonical.replace(b"clearer", b"external"))
        marker = self.root / "driver-ran"
        driver = self.root / "diff-driver"
        driver.write_text(f"#!/bin/sh\n: > '{marker}'\ncat '{visible}'\n")
        driver.chmod(0o755)
        self.git("config", "diff.external", str(driver))
        transformed = self.captured_patch("diff", "--no-color")
        self.assertTrue(marker.exists())
        self.assertIn(b"+A external human guide.", transformed)
        self.assertNotEqual(transformed, canonical)
        marker.unlink()
        result = self.run_helper(
            self.data(patch_sha256=hashlib.sha256(transformed).hexdigest())
        )
        self.assertIn("patch", result["reason"])
        self.assertEqual(self.captured_patch(*self.canonical_diff), canonical)
        self.run_helper(expected=0)
        self.assertFalse(marker.exists())

    def test_canonical_patch_stable_across_formatting_config_and_subdirectory(self):
        self.put("docs/caf\u00e9.md", "A story.\n\n" + "Line of context.\n" * 12)
        self.commit()
        self.base = self.head
        self.put(
            "docs/caf\u00e9.md",
            "A clearer story.\n\n" + "Line of context.\n" * 11 + "A new ending.\n",
        )
        self.put("README.md", "An even clearer human guide.\n")
        self.commit()
        canonical = self.captured_patch(*self.canonical_diff)
        data = self.data()
        order = self.root / "order.txt"
        order.write_text("docs/*\nREADME.md\n")
        for key, value in {
            "color.ui": "always",
            "core.abbrev": "5",
            "core.quotePath": "false",
            "diff.noprefix": "true",
            "diff.mnemonicPrefix": "true",
            "diff.relative": "true",
            "diff.context": "0",
            "diff.interHunkContext": "20",
            "diff.algorithm": "histogram",
            "diff.indentHeuristic": "true",
            "diff.orderFile": str(order),
            "diff.renames": "copies",
            "diff.ignoreSubmodules": "all",
            "diff.submodule": "diff",
        }.items():
            self.git("config", key, value)
        self.assertNotEqual(self.captured_patch("diff", "--no-color"), canonical)
        self.assertEqual(self.captured_patch(*self.canonical_diff), canonical)
        self.run_helper(data, expected=0, extra=("--tree", str(self.tree / "docs")))

    def test_mixed_source(self):
        self.put("src/main.py", "print('behavior')\n")
        self.commit()
        self.run_helper()

    def test_operational_markdown(self):
        for path in ("docs/AGENTS.md", "docs/SKILL.md", "harness/topic.md", ".github/topic.md",
                     ".codex/topic.md", "skills/thing/note.md", "agents/note.md", "memory/note.md",
                     "tests/fixtures/guide.md", "docs/security.md", "docs/permission-guide.md"):
            with self.subTest(path=path):
                self.put(path, "Human-looking operational text.\n")
                self.commit()
                self.run_helper()
                (self.tree / path).unlink()

    def test_add_and_delete_regular_prose(self):
        self.put("docs/Story.MD", "A human story.\n")
        (self.tree / "README.md").unlink()
        self.commit()
        self.run_helper(expected=0)

    def test_binary_markdown(self):
        (self.tree / "README.md").write_bytes(b"human\0binary")
        self.commit()
        self.run_helper()

    def test_empty_diff(self):
        self.put("README.md", "A human guide.\n")
        self.commit()
        self.run_helper()

    def test_gitlink_is_not_hidden_by_local_diff_config(self):
        self.git("update-index", "--add", "--cacheinfo", "160000," + self.base + ",module.md")
        self.git("commit", "-qm", "gitlink")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.git("config", "diff.ignoreSubmodules", "all")
        self.run_helper()

    def test_untrusted_positive_record(self):
        data = self.data()
        data["comments"][0]["user"]["id"] = 99
        self.run_helper(data)

    def test_executable_markdown(self):
        (self.tree / "README.md").chmod(0o755)
        self.commit()
        self.run_helper()

    def test_symlink_markdown(self):
        (self.tree / "README.md").unlink()
        (self.tree / "README.md").symlink_to("CLAUDE.md")
        self.commit()
        self.run_helper()

    def test_operational_rename_checks_deleted_side(self):
        (self.tree / "CLAUDE.md").rename(self.tree / "manual.md")
        self.commit()
        self.run_helper()

    def test_semantic_missing_mismatched_or_invalid(self):
        for change in (None, {"base": "d" * 40}, {"head": "d" * 40}, {"evidence": []}):
            with self.subTest(change=change):
                data = self.data()
                record = json.loads(data["comments"][0]["body"].split("```json\n")[1].split("\n```")[0])
                if change is None:
                    del record["ordinary_prose"]
                else:
                    record["ordinary_prose"].update(change)
                data["comments"] = [self.comment(record)]
                self.run_helper(data)

    def test_latest_nonclean_overrides_prior_positive(self):
        data = self.data()
        data["comments"].append(self.comment(valid_record(head=self.head, round=2, verdict="DIRTY",
            underlying_verdict="DIRTY", live={"P1": 1, "P2": 0, "P3": 0}), 2))
        self.run_helper(data)

    def test_changed_or_missing_revisions(self):
        for side in ("base", "head"):
            with self.subTest(side=side):
                data = self.data()
                data["after"] = copy.deepcopy(data["metadata"])
                data["after"][side]["sha"] = "d" * 40
                self.run_helper(data)
                data = self.data()
                del data["metadata"][side]["sha"]
                self.run_helper(data)

    def test_removed_executable_side(self):
        (self.tree / "README.md").chmod(0o755)
        self.commit()
        self.base = self.head
        (self.tree / "README.md").unlink()
        self.commit()
        self.run_helper()

    def test_deleted_prose_only(self):
        (self.tree / "README.md").unlink()
        self.commit()
        self.run_helper(expected=0)

    def test_empty_history(self):
        data = self.data()
        data["comments"] = []
        self.run_helper(data)

    def test_ci_head_mismatch(self):
        self.run_helper(extra=("--head", "d" * 40))

    def test_truncated_or_broken_history(self):
        data = self.data()
        record = valid_record(head=self.head, round=2, ordinary_prose={"base": self.base, "head": self.head,
            "patch_sha256": hashlib.sha256(self.captured_patch(*self.canonical_diff)).hexdigest(),
            "evidence": [{"lens": lens, "consumer_evidence": "Inspected all build input lists."} for lens in LENSES]})
        data["comments"] = [self.comment(record)]
        self.run_helper(data)
        data = self.data()
        data["comments"].append({"id": 2, "user": {"id": 7}, "body": "<!-- review-adversarial-first:round:v1 -->\nbroken"})
        self.run_helper(data)

    def test_missing_git_object(self):
        data = self.data()
        missing = "d" * 40
        data["metadata"]["head"]["sha"] = missing
        record = valid_record(head=missing, ordinary_prose={
            "base": self.base, "head": missing, "patch_sha256": "a" * 64,
            "evidence": [{"lens": lens, "consumer_evidence": "Inspected repository consumers."}
                         for lens in LENSES]})
        data["comments"] = [self.comment(record)]
        result = self.run_helper(data)
        self.assertIn("git evidence unavailable", result["reason"])

    def test_wrong_repo_identity(self):
        data = self.data()
        data["metadata"]["base"]["repo"]["full_name"] = "other/repo"
        self.run_helper(data)

    def test_api_failure_is_operational_not_proof(self):
        data = self.data()
        data["fail_comments"] = True
        self.run_helper(data, expected=2)


if __name__ == "__main__":
    unittest.main()
