import json
import re
import unittest
from pathlib import Path

from memory_dream import __version__

REPO_ROOT = Path(__file__).resolve().parents[1]


class TestVersionSurfaces(unittest.TestCase):
    """A VERSION bump must move every surface that reports the version.

    hov-stack's plugin-ci.sh checks VERSION against plugin.json; this test also
    holds the Python package metadata and the CLI's __version__ to it.
    """

    def test_release_versions_agree(self):
        version = (REPO_ROOT / "VERSION").read_text(encoding="utf-8").strip()
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")
        manifest = json.loads(
            (REPO_ROOT / ".claude-plugin/plugin.json").read_text(encoding="utf-8")
        )
        # Keep the suite stdlib-only on Python 3.10, before tomllib existed.
        project = (REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8")
        project_section = project.split("[project]\n", 1)[1].split("\n[", 1)[0]
        package_version = re.search(r'^version = "([^"]+)"$', project_section, re.M)
        self.assertIsNotNone(package_version)
        for surface, actual in (
            ("plugin manifest", manifest["version"]),
            ("Python package metadata", package_version[1]),
            ("CLI package version", __version__),
        ):
            with self.subTest(surface=surface):
                self.assertEqual(actual, version)


if __name__ == "__main__":
    unittest.main()
