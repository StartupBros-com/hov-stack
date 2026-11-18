"""Tests for scripts/plugin-delivery-report.py against real temporary git repositories.

Each case builds a repository with a marketplace manifest whose cards pin
commits of that repository, then moves main and checks what the report says.
No git call is mocked: the report's answer is only as good as its reading of a
real history.
"""
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location(
    "plugin_delivery_report", REPO_ROOT / "scripts" / "plugin-delivery-report.py")
PDR = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(PDR)

URL = "https://github.com/acme/stack.git"
GIT_ENV = {
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
}


class Repo:
    def __init__(self, root: Path):
        self.root = root
        self.git("init", "-q", "-b", "main")
        self.git("remote", "add", "origin", "git@github.com:acme/stack.git")

    def git(self, *args: str) -> str:
        r = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True,
                           env={**os.environ, **GIT_ENV}, check=True)
        return r.stdout.strip()

    def write(self, rel: str, text: str) -> None:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")

    def commit(self, msg: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)
        return self.git("rev-parse", "HEAD")

    def manifest(self, cards: list) -> None:
        self.write(".claude-plugin/marketplace.json", json.dumps({"name": "m", "plugins": cards}))


def card(name: str, sha, url: str = URL, path=None, source: str = "git-subdir") -> dict:
    return {"name": name, "source": {"source": source, "url": url,
                                     "path": f"plugins/{name}" if path is None else path, "sha": sha}}


def run(repo: Repo, ref: str = "HEAD") -> tuple[int, str]:
    out = io.StringIO()
    rc = PDR.report(repo.root, ref, out=out)
    return rc, out.getvalue()


def warns(text: str) -> list[str]:
    return [line for line in text.splitlines() if line.startswith("WARN")]


class TestDeliveryReport(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self._tmp.name))
        self.repo.write("plugins/alpha/bin/run.sh", "echo 1\n")
        self.repo.write("plugins/alpha/VERSION", "0.1.0\n")
        self.repo.write("plugins/beta/lib/x.py", "x = 1\n")
        self.pin = self.repo.commit("feat: alpha and beta 0.1.0")

    def tearDown(self):
        self._tmp.cleanup()

    def test_a_card_pinned_at_main_is_delivered(self):
        self.repo.manifest([card("alpha", self.pin), card("beta", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 0, out)
        self.assertEqual(warns(out), [], out)
        self.assertIn("2 current, 0 ahead of their pin, 0 could not be compared", out)

    def test_a_shipped_change_after_the_pin_is_behind_and_named(self):
        self.repo.write("plugins/alpha/bin/run.sh", "echo 2\n")
        fix = self.repo.commit("fix(alpha): echo 2")
        self.repo.manifest([card("alpha", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 1, out)
        self.assertEqual(len(warns(out)), 1, out)
        self.assertIn("alpha ships files that changed since its pin", warns(out)[0])
        self.assertIn(self.pin[:8], warns(out)[0])
        self.assertIn("\n  bin/run.sh\n", out)
        self.assertIn(f"    {fix[:7]} fix(alpha): echo 2", out)

    def test_test_doc_and_readme_changes_are_not_shipping_drift(self):
        for rel in ("tests/t.sh", "test/u.py", "docs/notes.md", "README.md", "CHANGELOG.md",
                    "src/fixtures/sample.json", "skills/x/README.md"):
            self.repo.write(f"plugins/alpha/{rel}", "changed\n")
        self.repo.commit("test(alpha): fixtures and docs")
        self.repo.manifest([card("alpha", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual((rc, warns(out)), (0, []), out)

    def test_a_test_named_file_outside_a_test_directory_still_ships(self):
        self.repo.write("plugins/alpha/src/contracts.test.ts", "it()\n")
        self.repo.commit("test(alpha): colocated test")
        self.repo.manifest([card("alpha", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 1, out)
        self.assertIn("\n  src/contracts.test.ts\n", out)

    def test_a_non_ascii_file_name_is_still_compared(self):
        # git quotes such a name in --name-only output unless told not to; a
        # quoted name fails the plugin-prefix match and the card read as current.
        self.repo.write("plugins/alpha/bin/café.sh", "a\n")
        pin = self.repo.commit("feat(alpha): café")
        self.repo.write("plugins/alpha/bin/café.sh", "b\n")
        self.repo.commit("fix(alpha): café b")
        self.repo.manifest([card("alpha", pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 1, out)
        self.assertIn("\n  bin/café.sh\n", out)

    def test_a_change_in_another_plugin_does_not_move_this_card(self):
        self.repo.write("plugins/beta/lib/x.py", "x = 2\n")
        self.repo.write("plugins/alphabet/lib/y.py", "y = 1\n")
        self.repo.commit("fix(beta): x = 2")
        self.repo.manifest([card("alpha", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual((rc, warns(out)), (0, []), out)

    def test_every_card_is_compared_not_only_the_first(self):
        self.repo.write("plugins/beta/lib/x.py", "x = 2\n")
        self.repo.commit("fix(beta): x = 2")
        self.repo.manifest([card("alpha", self.pin), card("beta", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 1, out)
        self.assertEqual(len(warns(out)), 1, out)
        self.assertIn("beta ships files", warns(out)[0])

    def test_a_pin_this_checkout_lacks_is_unknown_not_current(self):
        self.repo.manifest([card("alpha", "0" * 40)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(warns(out)), 1, out)
        self.assertIn("UNKNOWN for alpha", warns(out)[0])
        self.assertIn("not in this checkout", warns(out)[0])

    def test_a_pin_that_is_not_an_ancestor_is_unknown(self):
        self.repo.git("checkout", "-q", "-b", "side")
        self.repo.write("plugins/alpha/bin/run.sh", "echo side\n")
        side = self.repo.commit("side")
        self.repo.git("checkout", "-q", "main")
        self.repo.manifest([card("alpha", side)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertIn("not an ancestor of HEAD", warns(out)[0])

    def test_when_every_card_pins_another_repository_one_line_names_both(self):
        self.repo.manifest([card("alpha", self.pin, url="https://github.com/acme/other.git")])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(warns(out)), 1, out)
        self.assertIn("UNKNOWN for every card", warns(out)[0])
        self.assertIn("origin is github.com/acme/stack", warns(out)[0])
        self.assertIn("they pin github.com/acme/other", warns(out)[0])

    def test_a_card_that_is_not_a_git_subdir_pin_is_unknown(self):
        self.repo.manifest([card("alpha", self.pin, source="github")])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertIn("not a git-subdir pin", warns(out)[0])

    def test_a_short_or_missing_sha_is_unknown(self):
        self.repo.manifest([card("alpha", self.pin[:8]), card("beta", None)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(warns(out)), 2, out)
        self.assertTrue(all("not a full commit id" in w for w in warns(out)), out)

    def test_a_path_missing_at_the_pin_is_unknown(self):
        self.repo.manifest([card("gamma", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertIn("plugins/gamma does not exist at the pin", warns(out)[0])

    def test_a_path_that_climbs_out_of_the_repository_is_unknown(self):
        self.repo.manifest([card("alpha", self.pin, path="../elsewhere")])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertIn("not a relative path inside this repository", warns(out)[0])

    def test_unknown_outranks_ahead_in_the_exit_code(self):
        self.repo.write("plugins/beta/lib/x.py", "x = 2\n")
        self.repo.commit("fix(beta): x = 2")
        self.repo.manifest([card("alpha", "f" * 40), card("beta", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(warns(out)), 2, out)

    def test_an_unreadable_manifest_is_one_warn_line(self):
        self.repo.write(".claude-plugin/marketplace.json", "{not json")
        self.repo.commit("chore: broken manifest")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(warns(out)), 1, out)
        self.assertIn("cannot read a plugins list", warns(out)[0])

    def test_a_missing_manifest_and_a_ref_that_does_not_resolve_are_unknown(self):
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertIn("cannot read a plugins list", warns(out)[0])
        rc, out = run(self.repo, ref="no-such-ref")
        self.assertEqual(rc, 2, out)
        self.assertIn("no-such-ref does not resolve", warns(out)[0])

    def test_without_an_origin_remote_every_card_is_one_unknown_line(self):
        self.repo.git("remote", "remove", "origin")
        self.repo.manifest([card("alpha", self.pin), card("beta", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(warns(out)), 1, out)
        self.assertIn("UNKNOWN for every card", warns(out)[0])
        self.assertIn("has no origin remote", warns(out)[0])

    def test_a_fork_clone_is_one_unknown_line_not_one_per_card(self):
        # A clone whose origin is a fork has the pinned history but compares it
        # with the fork's main, so no card can be answered; one line says why.
        self.repo.git("remote", "set-url", "origin", "https://github.com/someone/stack.git")
        self.repo.manifest([card("alpha", self.pin), card("beta", self.pin)])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(warns(out)), 1, out)
        self.assertIn("UNKNOWN for every card", warns(out)[0])
        self.assertIn("github.com/someone/stack", warns(out)[0])

    def test_one_card_from_another_repository_among_matching_cards_is_its_own_line(self):
        self.repo.manifest([card("alpha", self.pin),
                            card("beta", self.pin, url="https://github.com/acme/other.git")])
        self.repo.commit("chore: cards")
        rc, out = run(self.repo)
        self.assertEqual(rc, 2, out)
        self.assertEqual(len(warns(out)), 1, out)
        self.assertIn("UNKNOWN for beta", warns(out)[0])
        self.assertIn("1 current, 0 ahead of their pin, 1 could not be compared", out)

    def test_the_command_line_compares_the_named_repository(self):
        self.repo.write("plugins/alpha/bin/run.sh", "echo 2\n")
        self.repo.commit("fix(alpha): echo 2")
        self.repo.manifest([card("alpha", self.pin)])
        self.repo.commit("chore: cards")
        r = subprocess.run(["python3", str(REPO_ROOT / "scripts" / "plugin-delivery-report.py"),
                            "--repo", str(self.repo.root)], capture_output=True, text=True, check=False)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertEqual(r.stderr, "")
        self.assertIn("against HEAD", r.stdout)
        self.assertIn("WARN plugin delivery: alpha ships files", r.stdout)


class TestRepoKey(unittest.TestCase):
    def test_https_ssh_and_scp_forms_name_one_repository(self):
        keys = {PDR.repo_key(u) for u in (
            "https://github.com/StartupBros-com/hov-stack.git",
            "https://github.com/StartupBros-com/hov-stack",
            "git@github.com:StartupBros-com/hov-stack.git",
            "ssh://git@github.com/StartupBros-com/hov-stack.git",
            "ssh://git@github.com:22/StartupBros-com/hov-stack/",
        )}
        self.assertEqual(keys, {"github.com/startupbros-com/hov-stack"})

    def test_another_owner_or_name_is_another_repository(self):
        base = PDR.repo_key("https://github.com/acme/stack.git")
        self.assertNotEqual(base, PDR.repo_key("https://github.com/acme/stack2.git"))
        self.assertNotEqual(base, PDR.repo_key("https://github.com/other/stack.git"))


if __name__ == "__main__":
    unittest.main()
