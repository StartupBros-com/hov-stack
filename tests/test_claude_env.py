"""claude-env.sh is sourced before every Claude Code Bash call. Its GOFLAGS line
keeps Go module caches writable: Go fills them with 0555 dirs, and Claude
Code's session delete is a plain recursive rm, so one cache in a job's tmp
can leave that job undeletable (EACCES)."""

import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ENV_FILE = Path(__file__).resolve().parents[1] / "claude-env.sh"


def _env_without_goflags(**extra):
    env = {k: v for k, v in os.environ.items() if k != "GOFLAGS"}
    env.update(extra)
    return env


def _sourced(script, env, cwd=None):
    return subprocess.run(
        ["bash", "-c", f'set -u; source "$1"; {script}', "_", str(ENV_FILE)],
        env=env,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def _goflags(start=None, times=1):
    env = (
        _env_without_goflags() if start is None else _env_without_goflags(GOFLAGS=start)
    )
    sources = "; ".join(['source "$1"'] * (times - 1)) or ":"
    return _sourced(f'{sources}; printf "%s" "$GOFLAGS"', env)


class GoflagsTests(unittest.TestCase):
    def test_unset_gains_the_flag(self):
        self.assertEqual(_goflags(), "-modcacherw")

    def test_empty_gains_the_flag(self):
        self.assertEqual(_goflags(""), "-modcacherw")

    def test_flags_a_caller_set_are_kept(self):
        self.assertEqual(
            _goflags("-mod=mod -trimpath"), "-mod=mod -trimpath -modcacherw"
        )

    def test_a_flag_already_there_is_not_doubled(self):
        self.assertEqual(_goflags("-modcacherw"), "-modcacherw")
        self.assertEqual(_goflags("-mod=mod -modcacherw"), "-mod=mod -modcacherw")

    def test_sourcing_again_is_a_no_op(self):
        self.assertEqual(_goflags(times=3), "-modcacherw")

    def test_a_lookalike_flag_still_gains_it(self):
        self.assertEqual(_goflags("-modcacherwx"), "-modcacherwx -modcacherw")


def _read_only_dirs(root):
    return [d for d, _, _ in os.walk(root) if not os.access(d, os.W_OK)]


@unittest.skipUnless(shutil.which("go"), "needs a go toolchain")
class ModuleCacheTests(unittest.TestCase):
    """A real `go mod download` from a local file proxy, no network."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        v = self.d / "proxy" / "example.com" / "m" / "@v"
        v.mkdir(parents=True)
        (v / "list").write_text("v1.0.0\n")
        (v / "v1.0.0.info").write_text(
            '{"Version":"v1.0.0","Time":"2026-01-01T00:00:00Z"}\n'
        )
        (v / "v1.0.0.mod").write_text("module example.com/m\n")
        with zipfile.ZipFile(v / "v1.0.0.zip", "w") as z:
            z.writestr("example.com/m@v1.0.0/go.mod", "module example.com/m\n")
            z.writestr("example.com/m@v1.0.0/m.go", "package m\n")

    def tearDown(self):
        self.tmp.cleanup()  # resets the control cache's modes itself

    def _download(self, cache, source_env_file):
        env = _env_without_goflags(
            GOMODCACHE=str(cache),
            GOCACHE=str(self.d / "gocache"),
            GOENV="off",
            GOPROXY=f"file://{self.d / 'proxy'}",
            GOSUMDB="off",
            GOWORK="off",
            GOTOOLCHAIN="local",
        )
        cmd = "go mod download example.com/m@v1.0.0"
        if source_env_file:
            _sourced(cmd, env, cwd=self.d)
        else:
            subprocess.run(
                ["bash", "-c", cmd],
                env=env,
                cwd=self.d,
                capture_output=True,
                text=True,
                check=True,
            )
        self.assertTrue((cache / "example.com" / "m@v1.0.0" / "m.go").is_file())

    def test_without_the_env_file_go_leaves_the_cache_read_only(self):
        """The control: proves this test can see the failure it guards."""
        cache = self.d / "mc-plain"
        self._download(cache, source_env_file=False)
        self.assertNotEqual(_read_only_dirs(cache), [])
        with self.assertRaises(PermissionError):
            shutil.rmtree(cache)

    def test_after_sourcing_a_plain_recursive_rm_removes_the_cache(self):
        cache = self.d / "mc-sourced"
        self._download(cache, source_env_file=True)
        self.assertEqual(_read_only_dirs(cache), [])
        shutil.rmtree(cache)
        self.assertFalse(cache.exists())


if __name__ == "__main__":
    unittest.main()
