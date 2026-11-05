#!/usr/bin/env python3
"""The README's install line and counts, held to the tree (restructure plan U19, #69).

WHY: the README is the public repository's front page. Its install line is the
command the clean-machine run executes as written, and its counts (permission
entries, hooks, skills, suites) and plugin list drift with every commit; the README
this replaced said 40 detail docs and 16 pre-tool guards when the tree held 35 and
12. scripts/check-readme-clone.py and scripts/check-readme-counts.py hold the text
to the tree. This module runs both on the real README and plants a failure for
each leg, so a check that stops catching its defect fails here.

The plugin-list leg needs .claude-plugin/marketplace.json, which this tree gains at
the public flip; until then the real-manifest test skips and says why, and the
fixture manifests below exercise the leg.
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
SCRIPTS = CLAUDE / "scripts"
MANIFEST = CLAUDE / ".claude-plugin" / "marketplace.json"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


counts = load("check-readme-counts")
clone = load("check-readme-clone")
README = (CLAUDE / "README.md").read_text(encoding="utf-8")
FACTS = counts.tree_facts(CLAUDE)
LISTED = [name for group in counts.plugin_groups(README).values() for name in group]


def manifest(*names):
    return {"name": "hov", "plugins": [{"name": name} for name in names]}


def problems(changes=None, served=None):
    docs = {name: (CLAUDE / name).read_text(encoding="utf-8") for name in counts.DOCS}
    docs.update(changes or {})
    return counts.check(docs, CLAUDE, served)[0]


class RealReadme(unittest.TestCase):
    def run_check(self, name):
        result = subprocess.run([sys.executable, "-I", str(SCRIPTS / f"{name}.py")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_install_line_is_the_one_the_clean_machine_run_executes(self):
        self.assertIn("install line matches", self.run_check("check-readme-clone"))

    def test_counts_match_and_the_manifest_leg_is_named_when_not_run(self):
        out = self.run_check("check-readme-counts")
        if not MANIFEST.exists():
            self.assertIn("plugin list: not run", out)

    def test_plugin_bullets_are_the_real_manifests_plugins(self):
        if not MANIFEST.exists():
            self.skipTest(f"{MANIFEST.relative_to(CLAUDE)} is absent; this tree gains it at the public flip")
        self.assertEqual(problems(served=json.loads(MANIFEST.read_text(encoding="utf-8"))), [])

    def test_a_hook_registered_through_run_with_flags_is_counted(self):
        # git-guard is registered only as run-with-flags.js's argument; dcg runs nothing under hooks/.
        self.assertIn("git-guard", FACTS["pre_tool_names"])
        self.assertNotIn("dcg", FACTS["pre_tool_names"])


class PlantedFailures(unittest.TestCase):
    def changed(self, old, new, text=README):
        self.assertIn(old, text)
        return text.replace(old, new)

    def assertNamed(self, found, *parts):
        self.assertTrue(any(all(part in line for part in parts) for line in found),
                        f"no problem names {parts}: {found}")

    def test_a_count_off_by_one_fails_naming_the_count(self):
        n = FACTS["harness_docs"]
        found = problems({"README.md": self.changed(f"{n} detail docs", f"{n + 1} detail docs")})
        self.assertNamed(found, "counts: detail docs in harness/", repr(str(n + 1)))
        allow = FACTS["allow"]
        found = problems({"README.md": self.changed(f"{allow} allow,", f"{allow + 1} allow,")})
        self.assertNamed(found, "counts: settings.json permission entries")

    def test_an_install_line_cloning_into_dotfiles_fails(self):
        readme = self.changed("~/hov-stack && cd ~/hov-stack", "~/dotfiles && cd ~/dotfiles")
        with self.assertRaisesRegex(ValueError, "must open with"):
            clone.check_clone(readme)

    def test_a_second_clone_in_the_install_block_fails(self):
        readme = self.changed(clone.INSTALL_LINE + "\n", clone.INSTALL_LINE + "\ngit clone https://example.invalid/x\n")
        with self.assertRaisesRegex(ValueError, "exactly one git clone"):
            clone.check_clone(readme)

    def test_a_plugin_the_readme_does_not_list_fails(self):
        self.assertNamed(problems(served=manifest(*LISTED, "brand-new")), "plugin list", "'brand-new'")

    def test_the_packs_own_entry_is_left_out(self):
        self.assertEqual(problems(served=manifest(*LISTED, counts.PACK)), [])

    def test_a_listed_plugin_the_manifest_does_not_serve_fails(self):
        self.assertNamed(problems(served=manifest(*LISTED[1:])), "plugin list", repr(LISTED[0]))

    def test_a_malformed_manifest_is_named_not_a_traceback(self):
        unnamed = manifest(*LISTED)
        unnamed["plugins"].append({"source": "./plugins/x"})
        self.assertNamed(problems(served=unnamed), "plugin list", f"plugins[{len(LISTED)}] has no name")
        self.assertNamed(problems(served={"name": "hov", "plugins": None}), "plugin list", '"plugins" list')
        self.assertNamed(problems(served=[]), "plugin list", '"plugins" list')

    def test_a_setup_group_out_of_step_with_default_plugins_fails(self):
        first = FACTS["default_plugins"][0]
        line = next(line for line in README.splitlines() if line.startswith(f"- `{first}`:"))
        self.assertNamed(problems({"README.md": self.changed(line + "\n", "")}), "plugin groups")

    def test_another_startupbros_repository_fails(self):
        contributing = (CLAUDE / "CONTRIBUTING.md").read_text(encoding="utf-8")
        changed = self.changed("`StartupBros-com/hov-stack`", "`StartupBros-com/hov-marketplace`", contributing)
        self.assertNamed(problems({"CONTRIBUTING.md": changed}), "repositories", "hov-marketplace")

    def test_a_repository_under_the_private_owner_fails_in_any_case(self):
        # Built from parts so the public-safety scan does not read the test itself as a citation.
        security = (CLAUDE / "SECURITY.md").read_text(encoding="utf-8")
        for owner in ("StartupBros", "startupbros", "STARTUPBROS-COM"):
            with self.subTest(owner=owner):
                cited = security + "\nSee https://github.com/" + owner + "/" + "not-listed.\n"
                self.assertNamed(problems({"SECURITY.md": cited}), "repositories", owner + "/not-listed")

    def test_a_path_not_in_the_tree_fails(self):
        readme = self.changed("`systemd/README.md`", "`systemd/MISSING.md`")
        self.assertNamed(problems({"README.md": readme}), "paths", "systemd/MISSING.md")

    def test_a_file_name_without_a_slash_not_in_the_tree_fails(self):
        readme = self.changed("`sync.sh`", "`sink.sh`")
        self.assertNamed(problems({"README.md": readme}), "paths", "'sink.sh'", "at the top level")

    def test_an_overlay_file_passes_only_when_listed(self):
        # stripe-accounts.json lives in the overlay, outside the tree; OVERLAY_FILES lists it.
        self.assertFalse([p for p in problems() if "stripe-accounts.json" in p])
        readme = self.changed("`stripe-accounts.json`", "`stripe-account.json`")
        self.assertNamed(problems({"README.md": readme}), "paths", "'stripe-account.json'", "at the top level")

    def test_a_dotfile_is_looked_up_under_its_bullets_directory(self):
        # .wslconfig is under windows/, not the top level; moved to a bullet with no directory it fails.
        line = next(line for line in README.splitlines() if line.startswith("- `install.sh`"))
        readme = self.changed(line, line + " See `.wslconfig`.")
        self.assertNamed(problems({"README.md": readme}), "paths", "'.wslconfig'", "at the top level")
        self.assertFalse([p for p in problems() if ".wslconfig" in p])

    def test_a_hook_that_does_not_run_before_a_tool_call_fails(self):
        readme = self.changed("`loop-guard`", "`verify-on-stop`")
        self.assertNamed(problems({"README.md": readme}), "hooks", "verify-on-stop")

    def test_a_number_no_count_recomputes_fails(self):
        for added, named in (("in five places", "'five'"), ("in 12-15 places", "'12'"), ("3x faster", "'3'"),
                             ("in twenty places", "'twenty'"), ("in `30` places", "'30'")):
            with self.subTest(added=added):
                readme = self.changed("each with a note of its upstream", f"each with a note of its upstream {added}")
                self.assertNamed(problems({"README.md": readme}), "unchecked numbers", named)


OFFERS_JSON = {
    "offers": [
        {"name": "alpha", "kind": "plugin", "group": "everyday", "publisher": "hov-stack"},
        {"name": "beta", "kind": "other-plugin", "group": "code", "publisher": "Acme"},
        {"name": "gamma", "kind": "tool", "group": "code", "publisher": "Globex"},
        {"name": "delta", "kind": "plugin", "group": "tuning", "publisher": "hov-stack"},
        {"name": "eps", "kind": "paid-skills", "group": "code", "publisher": "Initech"},
        {"name": "zeta", "kind": "plugin", "group": "code", "publisher": "hov-stack"},
    ],
}


def readme_with(more=(), tuning=("delta",), guided=("alpha", "zeta"), more_title=None):
    """A small README holding the plugin groups and the more-offers section."""
    title = more_title or counts.MORE_OFFERS_SECTION
    lines = ["## The plugins", "", f"### {counts.SETUP_GROUP}", "",
             f"### {counts.GUIDED_GROUP}", ""]
    lines += [f"- `{name}`: x." for name in guided]
    lines += ["", f"### {counts.TUNING_GROUP}", ""]
    lines += [f"- `{name}`: x." for name in tuning]
    lines += ["", f"## {title}", ""]
    lines += [f"- `{name}` ({publisher}): x." for name, publisher in more]
    return "\n".join(lines) + "\n"


class OffersFacts(unittest.TestCase):
    def facts(self, data=OFFERS_JSON):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "offers.json"
            path.write_text(json.dumps(data), encoding="utf-8")
            return counts.offer_facts(path)

    def test_facts_come_from_offers_json(self):
        facts = self.facts()
        self.assertEqual(facts["guided_plugins"], ["alpha", "zeta"])
        self.assertEqual(facts["tuning_plugins"], ["delta"])
        self.assertEqual(facts["more_offers"], [("beta", "Acme"), ("gamma", "Globex"), ("eps", "Initech")])

    def test_the_real_tree_reads_the_real_offers_json(self):
        real = json.loads((CLAUDE / counts.OFFERS).read_text(encoding="utf-8"))["offers"]
        self.assertEqual(FACTS["guided_plugins"], [o["name"] for o in real if o["kind"] == "plugin" and o["group"] != "tuning"])
        self.assertEqual(FACTS["tuning_plugins"], [o["name"] for o in real if o["kind"] == "plugin" and o["group"] == "tuning"])
        self.assertEqual(FACTS["more_offers"], [(o["name"], o["publisher"]) for o in real if o["kind"] != "plugin"])
        self.assertTrue(FACTS["guided_plugins"] and FACTS["tuning_plugins"] and FACTS["more_offers"])

    def test_a_malformed_offers_json_is_named(self):
        with self.assertRaisesRegex(ValueError, "no 'offers' list"):
            self.facts({"offers": None})
        with self.assertRaisesRegex(ValueError, "no 'publisher'"):
            self.facts({"offers": [{"name": "x", "kind": "tool", "group": "code"}]})


class MoreOffers(unittest.TestCase):
    MORE = (("beta", "Acme"), ("gamma", "Globex"), ("eps", "Initech"))

    def run_leg(self, readme):
        facts = {"more_offers": list(self.MORE)}
        return counts.check_more_offers(readme, facts)

    def test_a_matching_section_passes(self):
        self.assertEqual(self.run_leg(readme_with(self.MORE)), [])

    def test_a_missing_section_is_named(self):
        found = self.run_leg(readme_with(self.MORE, more_title="Something else"))
        self.assertEqual(len(found), 1)
        self.assertIn("more offers: no '## More that `/hov-setup` offers' section", found[0])

    def test_wrong_order_names_the_first_difference(self):
        found = self.run_leg(readme_with((self.MORE[1], self.MORE[0], self.MORE[2])))
        self.assertEqual(len(found), 1)
        self.assertIn("more offers: bullet 1", found[0])
        self.assertIn("('gamma', 'Globex')", found[0])
        self.assertIn("('beta', 'Acme')", found[0])

    def test_wrong_publisher_is_named(self):
        found = self.run_leg(readme_with((self.MORE[0], ("gamma", "Hooli"), self.MORE[2])))
        self.assertEqual(len(found), 1)
        self.assertIn("bullet 2", found[0])
        self.assertIn("('gamma', 'Hooli')", found[0])

    def test_an_extra_bullet_is_named(self):
        found = self.run_leg(readme_with(self.MORE + (("extra", "Umbrella"),)))
        self.assertEqual(len(found), 1)
        self.assertIn("bullet 4", found[0])
        self.assertIn("('extra', 'Umbrella')", found[0])
        self.assertIn("None", found[0])

    def test_a_missing_bullet_is_named(self):
        found = self.run_leg(readme_with(self.MORE[:2]))
        self.assertEqual(len(found), 1)
        self.assertIn("bullet 3", found[0])
        self.assertIn("is None", found[0])

    def test_check_runs_the_leg_on_the_real_readme(self):
        # Holds before and after the README gains the section: either way the leg is wired in.
        real = problems()
        if "## More that `/hov-setup` offers" in README:
            self.assertEqual([p for p in real if p.startswith("more offers")], [])
        else:
            self.assertTrue(any(p.startswith("more offers: no ") for p in real), real)


class TuningGroup(unittest.TestCase):
    FACTS = {"default_plugins": [], "guided_plugins": ["alpha", "zeta"], "tuning_plugins": ["delta"]}

    def test_a_matching_tuning_group_passes(self):
        self.assertEqual(counts.check_plugin_groups(readme_with(), self.FACTS), [])

    def test_a_tuning_group_out_of_step_with_offers_json_fails(self):
        found = counts.check_plugin_groups(readme_with(tuning=("delta", "stray")), self.FACTS)
        self.assertEqual(len(found), 1)
        self.assertIn(counts.TUNING_GROUP, found[0])
        self.assertIn("offers.json gives ['delta']", found[0])

    def test_the_guided_group_names_offers_json_as_its_source(self):
        found = counts.check_plugin_groups(readme_with(guided=("alpha",)), self.FACTS)
        self.assertEqual(len(found), 1)
        self.assertIn("offers.json gives ['alpha', 'zeta']", found[0])


if __name__ == "__main__":
    unittest.main()
