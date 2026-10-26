"""Retirement contracts: no live home, APIs or credentials."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

audit = load("retirement_audit", ROOT/"scripts/cli-supersedes-mcp-audit.py")
migration = load("retirement_migration", ROOT/"scripts/mcp-retirement.py")

class RetirementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, name, data):
        path = self.root/name
        path.write_text(json.dumps(data))
        return path

    def test_suffix_and_non_alias(self):
        prefix = "mcp__google-analytics__"
        self.assertTrue(audit.retired_permission("mcp__google-analytics-acme__run_report", "google-analytics", prefix))
        self.assertFalse(audit.retired_permission("mcp__google-analyticsfoo__run_report", "google-analytics", prefix))
        self.assertFalse(audit.retired_permission("Bash(ga4 report:*)", "google-analytics", prefix))

    def test_unconditional_shadcn_and_project_lists(self):
        settings = self.write("settings.json", {"permissions":{"allow":[]}})
        config = self.write("claude.json", {"mcpServers":{"shadcn":{"secret":"DO-NOT-PRINT"}},
            "projects":{"/fixture":{"enabledMcpjsonServers":["shadcn", "stripe"], "mcpServers":{"google-analytics-acme":{}}}}})
        local = self.write("local.json", {"permissions":{"allow":["mcp__google-analytics-acme__run_report"]},
            "disabledMcpjsonServers":["discord","discordish"]})
        out = io.StringIO()
        with patch.object(audit.shutil, "which", return_value="/fixture/cli"), contextlib.redirect_stdout(out):
            status = audit.main(["--settings",str(settings),"--claude-json",str(config),"--repo-settings-json",str(local),
                "--row","!|shadcn|mcp__shadcn__|","--row","ga4|google-analytics|mcp__google-analytics__|", "--row","discord-cli|discord|mcp__discord__|"])
        self.assertEqual(status,1)
        text = out.getvalue()
        self.assertEqual(text.count("WARN "),5)
        self.assertIn("retirement is unconditional",text)
        self.assertIn("google-analytics-acme__run_report",text)
        self.assertNotIn("DO-NOT-PRINT",text)
        self.assertNotIn("discordish",text)

    def test_invalid_approval_never_clean(self):
        path = self.write("bad.json", {"enabledMcpjsonServers":"discord"})
        with self.assertRaises(RuntimeError):
            audit.settings_surfaces(str(path), json.loads(path.read_text()))

    def fixture(self):
        return {"mcpServers":{"shadcn":{},"discord":{},"google-analytics-acme":{},"stripe":{"secret":"KEEP"}},
            "permissions":{"allow":["mcp__google-analytics-acme__run_report","Bash(gsc:*)"],"ask":["mcp__discord__discord_execute"],"deny":[]},
            "projects":{"/fixture":{"enabledMcpjsonServers":["discord","stripe"],"disabledMcpjsonServers":["shadcn"],"other":True}},
            "other":{"retain":[1,2,3]}}

    def test_preserves_unrelated_and_plan_no_write(self):
        data = self.fixture()
        path = self.write("config.json",data)
        original = path.read_bytes()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(migration.main(["--file",str(path)]),0)
        self.assertEqual(path.read_bytes(),original)
        self.assertNotIn("KEEP",out.getvalue())
        self.assertFalse((self.root/"backups").exists())
        changed, changes = migration.transform(copy.deepcopy(data))
        self.assertTrue(changes)
        self.assertEqual(changed["mcpServers"],{"stripe":{"secret":"KEEP"}})
        self.assertEqual(changed["permissions"]["allow"],["Bash(gsc:*)"])
        self.assertEqual(changed["projects"]["/fixture"]["enabledMcpjsonServers"],["stripe"])
        self.assertEqual(changed["other"],data["other"])

    def test_apply_backup_and_idempotence(self):
        path = self.write("config.json", self.fixture())
        original = path.read_bytes()
        backup = migration.apply([migration.prepare(path)], self.root/"backups")
        backups = list(backup.iterdir())
        self.assertEqual(len(backups),1)
        self.assertEqual(backups[0].read_bytes(),original)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode),0o600)
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode),0o700)
        self.assertIsNone(migration.apply([migration.prepare(path)],self.root/"backups"))

    def test_malformed_all_preflight_before_write(self):
        path = self.write("good.json", self.fixture())
        bad = self.root/"bad.json"; bad.write_text('{"password":"DO-NOT-PRINT" invalid')
        before = path.read_bytes()
        out = io.StringIO()
        with contextlib.redirect_stderr(out),patch.object(migration.shutil,"which",return_value="/fixture/cli"):
            status = migration.main(["--file",str(path),"--file",str(bad),"--apply","--quiescent","--backup-dir",str(self.root/"backups")])
        self.assertEqual(status,2)
        self.assertEqual(path.read_bytes(),before)
        self.assertNotIn("DO-NOT-PRINT",out.getvalue())
        self.assertFalse((self.root/"backups").exists())

    def test_observed_concurrent_edit_and_symlink_refused(self):
        path = self.write("config.json", self.fixture())
        item = migration.prepare(path)
        path.write_text('{"newWriter":true}')
        with self.assertRaises(ValueError):
            migration.apply([item], self.root/"backups")
        self.assertEqual(path.read_text(),'{"newWriter":true}')
        link = self.root/"link.json"; link.symlink_to(path)
        with self.assertRaises(ValueError):migration.prepare(link)

    def test_ambiguous_or_nonfinite_json_refused(self):
        for number, text in enumerate(['{"mcpServers":{"discord":{}},"mcpServers":{}}', '{"unrelated":NaN}']):
            path = self.root/f"invalid-{number}.json"; path.write_text(text)
            with self.assertRaises(ValueError):migration.prepare(path)
            self.assertEqual(path.read_text(), text)
        with self.assertRaises(RuntimeError):audit.settings_surfaces("fixture", {"permissions":{"allow":[42]}})

    def test_unrepresentable_numbers_refuse_all_targets_before_backups_or_writes(self):
        good = self.write("good-numbers.json", self.fixture())
        original = good.read_bytes()
        for number in ("1e400", "-1e400", "1e-400", "1.000000000000000000001"):
            with self.subTest(number=number):
                bad = self.root/"bad-number.json"
                text = '{"mcpServers":{"shadcn":{}},"unrelated":' + number + '}'
                bad.write_text(text)
                for mode in ([], ["--apply", "--quiescent"]):
                    with contextlib.redirect_stderr(io.StringIO()), patch.object(migration.shutil, "which", return_value="/fixture/cli"):
                        status = migration.main(["--file", str(good), "--file", str(bad),
                            "--backup-dir", str(self.root/"backups"), *mode])
                    self.assertEqual(status, 2)
                    self.assertEqual(good.read_bytes(), original)
                    self.assertEqual(bad.read_text(), text)
                    self.assertFalse((self.root/"backups").exists())
        # Ordinary finite decimals and exponent notation remain supported.
        finite = self.root/"finite.json"
        finite.write_text('{"mcpServers":{"shadcn":{}},"unrelated":[0.1,1.25,1e20]}')
        prepared = migration.prepare(finite)
        self.assertEqual(json.loads(prepared[2])["unrelated"], [0.1, 1.25, 1e20])

    def test_unconditional_shadcn_warns_when_replacement_clis_are_absent(self):
        settings = self.write("offline-settings.json", {"permissions":{"allow":[]}})
        config = self.write("offline-config.json", {"mcpServers":{"shadcn":{},"discord":{}}})
        out = io.StringIO()
        with patch.object(audit.shutil, "which", return_value=None), contextlib.redirect_stdout(out):
            status = audit.main(["--settings", str(settings), "--claude-json", str(config),
                "--row", "!|shadcn|mcp__shadcn__|", "--row", "discord-cli|discord|mcp__discord__|"])
        self.assertEqual(status, 1)
        self.assertEqual(out.getvalue().count("WARN "), 1)
        self.assertIn("mcpServers.shadcn is still registered", out.getvalue())
        self.assertIn("discord row dormant", out.getvalue())

    def test_late_second_target_edit_preserves_writer_backups_and_partial_apply_guidance(self):
        first = self.write("first.json", self.fixture())
        second = self.write("second.json", self.fixture())
        originals = [first.read_bytes(), second.read_bytes()]
        real_replace = migration.os.replace
        writer = b'{"newWriter":true}'
        def replace_then_edit(source, destination):
            real_replace(source, destination)
            if destination == first:
                second.write_bytes(writer)
        err = io.StringIO()
        backups = self.root/"backups"
        with patch.object(migration.os, "replace", side_effect=replace_then_edit), patch.object(migration.shutil, "which", return_value="/fixture/cli"), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            status = migration.main(["--file", str(first), "--file", str(second), "--apply", "--quiescent", "--backup-dir", str(backups)])
        self.assertEqual(status, 2)
        self.assertEqual(json.loads(first.read_bytes())["mcpServers"], {"stripe":{"secret":"KEEP"}})
        self.assertEqual(second.read_bytes(), writer)
        self.assertIn("earlier targets may be applied", err.getvalue())
        self.assertIn(str(backups), err.getvalue())
        directories = list(backups.iterdir())
        self.assertEqual(len(directories), 1)
        saved = sorted(directories[0].iterdir())
        self.assertEqual([entry.read_bytes() for entry in saved], originals)
        self.assertTrue(all(stat.S_IMODE(entry.stat().st_mode) == 0o600 for entry in saved))
        self.assertFalse(list(self.root.glob(".mcp-retirement-*")))

    def test_project_that_still_registers_a_retired_server_keeps_its_entries(self):
        repo = self.root/"opted-in"; (repo/".claude").mkdir(parents=True)
        (repo/".mcp.json").write_text(json.dumps({"mcpServers":{"discord":{"env":{"DISCORD_BOT_TOKEN":"DO-NOT-PRINT"}},"google-analytics-acme":{}}}))
        broken = self.root/"broken"; broken.mkdir(); (broken/".mcp.json").write_text('{"token":"DO-NOT-PRINT" invalid')
        gone = str(self.root/"deleted-worktree")
        held = {"enabledMcpjsonServers":["discord","google-analytics-acme","shadcn","stripe"],
            "permissions":{"allow":["mcp__discord__discord_discover","mcp__google-analytics-acme__run_report","mcp__shadcn__list"],
                "ask":["mcp__discord__discord_execute"]}}
        config = self.write("claude.json", {"mcpServers":{"discord":{}},
            "projects":{str(repo):copy.deepcopy(held),str(broken):copy.deepcopy(held),gone:copy.deepcopy(held)}})
        local = repo/".claude"/"settings.local.json"; local.write_text(json.dumps(held))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(migration.main(["--file",str(config),"--file",str(local)]),0)
        text = out.getvalue()
        self.assertNotIn("DO-NOT-PRINT",text)
        self.assertIn(f"kept projects[{repo}]: discord, google-analytics (registered in {repo/'.mcp.json'})",text)
        self.assertIn(f"kept projects[{broken}]: discord, google-analytics, shadcn ({broken/'.mcp.json'} is unreadable)",text)
        self.assertIn(f"kept top level: discord, google-analytics (registered in {repo/'.mcp.json'})",text)
        projects = migration.prepare(config.absolute())
        changed = json.loads(projects[2])
        # The global registration and a deleted project's entries go; the opted-in project keeps its servers but not shadcn.
        self.assertEqual(changed["mcpServers"],{})
        self.assertEqual(changed["projects"][gone],{"enabledMcpjsonServers":["stripe"],"permissions":{"allow":[],"ask":[]}})
        self.assertEqual(changed["projects"][str(broken)],held)
        kept = {"enabledMcpjsonServers":["discord","google-analytics-acme","stripe"],
            "permissions":{"allow":["mcp__discord__discord_discover","mcp__google-analytics-acme__run_report"],"ask":["mcp__discord__discord_execute"]}}
        self.assertEqual(changed["projects"][str(repo)],kept)
        self.assertEqual(json.loads(migration.prepare(local)[2]),kept)
        # The registration file itself is never shielded by its own content.
        mcp = migration.prepare(repo/".mcp.json")
        self.assertEqual(json.loads(mcp[2])["mcpServers"],{})
        self.assertEqual(mcp[6],[])
        # ~/.claude/settings.json is global even though its parent is named .claude.
        home = self.root/"home"; (home/".claude").mkdir(parents=True)
        (home/".mcp.json").write_text(json.dumps({"mcpServers":{"discord":{}}}))
        user = home/".claude"/"settings.json"; user.write_text(json.dumps(held))
        with patch.object(migration.Path,"home",return_value=home):
            self.assertEqual(json.loads(migration.prepare(user)[2])["permissions"],{"allow":[],"ask":[]})

    def test_apply_requires_quiet_window_and_clis(self):
        path = self.write("config.json", self.fixture())
        original = path.read_bytes()
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(migration.main(["--file",str(path),"--apply"]),2)
            with patch.object(migration.shutil,"which",return_value=None):
                self.assertEqual(migration.main(["--file",str(path),"--apply","--quiescent"]),2)
        self.assertEqual(path.read_bytes(),original)

if __name__ == "__main__":unittest.main()
