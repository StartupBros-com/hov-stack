"""Config paths in maintenance.repos.json use ~/ and must resolve under $HOME."""
import importlib.util
import io
import json
import os
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AGENT = ROOT / "harnesses" / "pi" / "agent"
CONFIG = AGENT / "maintenance.repos.json"


def load_script(name: str):
    # Scripts compute CONFIG_PATH from Path.home() at import, so HOME must be set first.
    path = str(AGENT / "bin" / name)
    loader = SourceFileLoader(name.replace("-", "_"), path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class TildePathTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name).resolve()
        old = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)

        def restore():
            if old is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old

        self.addCleanup(restore)

    def test_inspect_repo_expands_tilde(self):
        scan = load_script("pi-maintenance-scan")
        (self.home / "SITES" / "demo").mkdir(parents=True)
        info = scan.inspect_repo(
            {"name": "demo", "path": "~/SITES/demo", "policy": "owned-public"}, fetch=False
        )
        self.assertEqual(info["path"], str(self.home / "SITES" / "demo"))
        self.assertTrue(info["exists"])

    def test_compare_backup_expands_tilde(self):
        scan = load_script("pi-maintenance-scan")
        for d in ("local", "backup"):
            (self.home / d).mkdir()
            (self.home / d / "AGENTS.md").write_text("same\n")
        cfg = {"localAgentDir": "~/local", "backupPiAgentDir": "~/backup", "syncPaths": ["AGENTS.md"]}
        self.assertTrue(scan.compare_backup(cfg)["in_sync"])
        # Prove the file was actually seen on both sides, not just two empty trees.
        (self.home / "backup" / "AGENTS.md").write_text("different\n")
        self.assertEqual(scan.compare_backup(cfg)["changed"], ["AGENTS.md"])

    def test_sync_backup_expands_tilde(self):
        cfg_dir = self.home / ".pi" / "agent"
        cfg_dir.mkdir(parents=True)
        (cfg_dir / "AGENTS.md").write_text("hello\n")
        (cfg_dir / "maintenance.repos.json").write_text(
            json.dumps({
                "localAgentDir": "~/.pi/agent",
                "backupPiAgentDir": "~/backup/pi/agent",
                "syncPaths": ["AGENTS.md"],
            })
        )
        sync = load_script("pi-maintenance-sync-backup")
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = sync.main()
        self.assertEqual(rc, 0)
        copied = self.home / "backup" / "pi" / "agent" / "AGENTS.md"
        self.assertEqual(copied.read_text(), "hello\n")
        self.assertIn("SYNC_CHANGED=AGENTS.md", buf.getvalue())


class ShippedConfigTests(unittest.TestCase):
    def setUp(self):
        self.cfg = json.loads(CONFIG.read_text())

    def test_no_absolute_home_paths(self):
        pat = re.compile(r"^/(home|Users)/")

        def walk(o):
            if isinstance(o, dict):
                for v in o.values():
                    yield from walk(v)
            elif isinstance(o, list):
                for v in o:
                    yield from walk(v)
            elif isinstance(o, str):
                yield o

        self.assertEqual([s for s in walk(self.cfg) if pat.match(s)], [])

    def test_path_values_use_tilde(self):
        vals = [(k, v) for k, v in self.cfg.items() if k.endswith(("Dir", "Repo"))]
        vals += [(f"repos[{r['name']}].path", r["path"]) for r in self.cfg["repos"]]
        self.assertGreaterEqual(len(vals), 4)
        for key, v in vals:
            self.assertTrue(v.startswith("~/"), f"{key}={v}")


if __name__ == "__main__":
    unittest.main()
