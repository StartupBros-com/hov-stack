#!/usr/bin/env python3
"""Hermetic settings-source and interactive job-control regressions; no providers."""
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]


class LauncherLifetimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ccflare-launcher-lifetime-")
        self.root = Path(self.tmp.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.config = self.root / "config"
        self.config.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.record = self.root / "child.json"
        source = (REPO / ".bashrc").read_text()
        source = source.split("# --- ccflare-launcher begin", 1)[1]
        source = source.split("\n", 1)[1].split("# --- ccflare-launcher end", 1)[0]
        self.assertEqual(source.count("local managed_settings_dir=/etc/claude-code"), 1)
        source = source.replace("local managed_settings_dir=/etc/claude-code", f"local managed_settings_dir={self.root}/policy")
        self.launcher = self.root / "launcher.sh"
        self.launcher.write_text(source)
        (self.config / "settings.json").write_text(json.dumps({"env": {
            "ANTHROPIC_BASE_URL": "http://fixture.invalid", "ANTHROPIC_CUSTOM_HEADERS": "x-api-key: btr-fixture"}}))
        self.env = {"PATH": f"{self.bin}:/usr/bin:/bin", "TERM": "dumb", "CLAUDE_CONFIG_DIR": str(self.config),
                    "XDG_STATE_HOME": str(self.root / "state"), "FIXTURE_RECORD": str(self.record),
                    "HISTFILE": str(self.root / "history"), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                    "FIXTURE_INLINE_ORIGIN": str(self.root / "cli-owned-temp-origin")}
        self.write_bin("curl", "#!/bin/sh\nprintf 401\n")
        self.write_bin("claude", r"""#!/usr/bin/python3
import json, os, signal, sys
from pathlib import Path
args=sys.argv[1:]
value=args[args.index('--settings')+1]
inline=value.startswith('{')
p=None if inline else Path(value)
data=json.loads(value if inline else p.read_text())
# Single-leading-slash permissions use the flags settings source directory.
# Characterized separately against the installed Linux CLI source.
origin=Path(os.environ['FIXTURE_INLINE_ORIGIN']) if inline else p.resolve().parent
result={'overlay':None if inline else str(p),'kind':'inline' if inline else 'file','mode':None if inline else p.stat().st_mode & 0o777,'cwd':os.getcwd(),
        'deny_target':str(origin / data.get('permissions',{}).get('deny',['Read(/secrets/**)'])[0][6:-1]),
        'permissions':data.get('permissions'),'pid':os.getpid(),'args':args,'alive_before':True if inline else p.exists()}
record=Path(os.environ['FIXTURE_RECORD'])
record.write_text(json.dumps(result))
mode=os.environ.get('FIXTURE_MODE','exit')
if mode=='self-stop': os.kill(os.getpid(), signal.SIGSTOP)
elif mode=='terminal-stop':
    # Delay the child's stop independently of the foreground supervisor.
    if os.environ.get('FIXTURE_DELAY_STOP')=='1':
        import threading, time
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTSTP})
        def delayed_stop():
            signal.sigwait({signal.SIGTSTP})
            time.sleep(.4)
            os.kill(os.getpid(), signal.SIGSTOP)
        threading.Thread(target=delayed_stop, daemon=True).start()
    # The PTY driver sends Ctrl-Z to the entire foreground job, then fg.
    sys.stdout.write('READY_FOR_CTRL_Z\n'); sys.stdout.flush()
    sys.stdin.readline()
elif mode=='terminal-stop-late':
    # A descheduled child: Bash reports the job stopped once the supervisor
    # shell stops, while this child still sits in a terminal read with SIGTSTP
    # pending for a second. A line typed at the prompt then reaches the child.
    class Late(Exception): pass
    def late(*_): raise Late
    signal.signal(signal.SIGALRM, late)
    signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGTSTP])
    sys.stdout.write('READY_FOR_CTRL_Z\n'); sys.stdout.flush()
    try:
        signal.setitimer(signal.ITIMER_REAL, 1)
        result['stolen']=os.read(0, 4096).decode()
        signal.setitimer(signal.ITIMER_REAL, 0)
    except Late: pass
    signal.pthread_sigmask(signal.SIG_UNBLOCK, [signal.SIGTSTP])
    sys.stdin.readline()
elif mode=='interrupt':
    sys.stdout.write('READY_FOR_INTERRUPT\n'); sys.stdout.flush()
    signal.pause()
result['alive_after']=True if inline else p.exists()
record.write_text(json.dumps(result))
sys.exit(int(os.environ.get('FIXTURE_EXIT','17')))
""")

    def write_bin(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_launcher(self, args):
        command = f"source {shlex.quote(str(self.launcher))}; claude " + shlex.join(args)
        return subprocess.run(["bash", "--noprofile", "--norc", "-c", command], cwd=self.project,
                              env=self.env, text=True, capture_output=True, timeout=8)

    def settings_file(self, directory, name="session.json"):
        directory.mkdir(parents=True, exist_ok=True)
        p = directory / name
        p.write_text(json.dumps({"permissions": {"deny": ["Read(/secrets/**)"]}, "env": {"KEEP_SETTING": "yes"}}))
        return p

    def assert_source_preserved(self, args, source_dir):
        result = self.run_launcher(args)
        self.assertEqual(result.returncode, 17, result.stderr)
        child = json.loads(self.record.read_text())
        self.assertEqual(Path(child['deny_target']), source_dir / 'secrets/**')
        if child['kind'] == 'file':
            self.assertEqual(child['mode'], 0o600)
            self.assertFalse(Path(child['overlay']).exists())
        self.assertEqual(child['cwd'], str(self.project))

    def test_file_permissions_keep_settings_directory(self):
        source = self.settings_file(self.root / "caller source")
        before = source.read_bytes()
        self.assert_source_preserved(['--settings', str(source)], source.parent)
        self.assertEqual(source.read_bytes(), before)

    def test_inline_permissions_keep_cli_inline_origin(self):
        self.assert_source_preserved(['--settings', '{"permissions":{"deny":["Read(/secrets/**)"]}}'], Path(self.env['FIXTURE_INLINE_ORIGIN']))
        self.assertEqual(json.loads(self.record.read_text())['kind'], 'inline')

    def test_last_settings_file_wins_with_relative_spaced_path(self):
        first = self.settings_file(self.root / "ignored")
        last = self.settings_file(self.project / "nested space")
        self.assert_source_preserved(['--settings', str(first), '--settings=nested space/session.json', '--continue'], last.parent)

    def test_symlinked_settings_file_keeps_resolved_directory(self):
        source = self.settings_file(self.root / "physical")
        link = self.project / "session.json"
        link.symlink_to(source)
        self.assert_source_preserved(['--settings', str(link)], source.parent)
        self.assertTrue(link.is_symlink())

    def test_symlinked_directory_keeps_resolved_directory(self):
        source = self.settings_file(self.root / "physical")
        link = self.project / "linked"
        link.symlink_to(source.parent, target_is_directory=True)
        self.assert_source_preserved(['--settings', str(link / source.name)], source.parent)

    def test_trailing_newline_file_and_symlink_keep_exact_permissions(self):
        for use_link in [False, True]:
            for sibling in [False, True]:
                with self.subTest(symlink=use_link, newline_free_sibling=sibling):
                    source = self.settings_file(self.root / f"source-{use_link}-{sibling}", "session.json\n")
                    before = source.read_bytes()
                    if sibling:
                        source.with_name("session.json").write_text('{}')
                    selected = source
                    if use_link:
                        selected = self.project / f"policy-{sibling}.json"
                        selected.symlink_to(source)
                    self.assert_source_preserved(['--settings', str(selected)], source.parent)
                    self.assertEqual(json.loads(self.record.read_text())['permissions'],
                                     {"deny": ["Read(/secrets/**)"]})
                    self.assertEqual(source.read_bytes(), before)
                    if sibling:
                        self.assertEqual(source.with_name("session.json").read_text(), '{}')

    def test_realpath_failure_cancels_before_launch(self):
        source = self.settings_file(self.root / "caller")
        # A failed resolver emits no NUL-terminated successful result.
        self.write_bin("realpath", "#!/bin/sh\nexit 1\n")
        result = self.run_launcher(['--settings', str(source)])
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.record.exists())

    def test_unwritable_source_directory_cancels_without_weakening(self):
        source = self.settings_file(self.root / "read-only-source")
        source.parent.chmod(0o500)
        try:
            result = self.run_launcher(['--settings', str(source)])
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.record.exists(), 'child launched with relocated permissions')
        finally:
            source.parent.chmod(0o700)

    def test_json_shaped_filename_retains_inline_precedence(self):
        source = self.settings_file(self.project, "{}")
        self.assert_source_preserved(['--settings', source.name], Path(self.env['FIXTURE_INLINE_ORIGIN']))
        self.assertEqual(json.loads(self.record.read_text())['kind'], 'inline')

    def test_malformed_json_shaped_filename_never_becomes_file_settings(self):
        source = self.settings_file(self.project, "{not-json}")
        result = self.run_launcher(['--settings', source.name])
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.record.exists())

    def test_ecmascript_whitespace_inline_precedes_same_named_file(self):
        # ECMAScript WhiteSpace + LineTerminator, not Python/POSIX whitespace.
        points = [*range(0x09, 0x0E), 0x20, 0xA0, 0x1680,
                  *range(0x2000, 0x200B), 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
        permissions = {"deny": ["Bash(rm *)"]}
        inline = json.dumps({"permissions": permissions}, separators=(',', ':'))
        for point in points:
            with self.subTest(codepoint=hex(point)):
                value = chr(point) + inline + chr(point)
                # Reading this file instead of inline JSON would erase the deny.
                (self.project / value).write_text('{}')
                result = self.run_launcher(['--settings', value])
                self.assertEqual(result.returncode, 17, result.stderr)
                child = json.loads(self.record.read_text())
                self.assertEqual(child['kind'], 'inline')
                self.assertEqual(child['permissions'], permissions)

    def test_non_ecmascript_whitespace_preserves_literal_file_path(self):
        for point in [0x85, 0x180E, 0x200B]:
            with self.subTest(codepoint=hex(point)):
                value = chr(point) + '{}' + chr(point)
                source = self.settings_file(self.project, value)
                before = source.read_bytes()
                self.assert_source_preserved(['--settings', value], self.project)
                self.assertEqual(json.loads(self.record.read_text())['kind'], 'file')
                self.assertEqual(source.read_bytes(), before)

    def wait_record(self, timeout=5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                return json.loads(self.record.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(.02)
        self.fail('owned child did not start')

    def wait_state(self, pid, state, timeout=6):
        # Bash reports the job stopped once the supervisor subshell stops,
        # while the native child can still sit in its terminal read. Type only
        # once the child is in the state the next keystroke needs, sleeping in
        # that read (S) or stopped (T), or the child and Bash take each
        # other's lines.
        end = time.monotonic() + timeout
        while True:
            try:
                status = Path(f'/proc/{pid}/status').read_text()
            except FileNotFoundError:
                self.fail(f'owned child exited before reaching state {state}')
            seen = next(line.split()[1] for line in status.splitlines() if line.startswith('State:'))
            if seen == state:
                return
            if time.monotonic() > end:
                self.fail(f'native child state {seen}, expected {state}')
            time.sleep(.01)

    def interactive(self, mode):
        self.env['FIXTURE_MODE'] = mode
        rc = self.root / "interactive.rc"
        rc.write_text(f"source {shlex.quote(str(self.launcher))}\nPS1='FIXTURE_PROMPT> '\n")
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(self.project)
            os.execve('/bin/bash', ['bash', '--noprofile', '--rcfile', str(rc), '-i'], self.env)
        transcript = bytearray()
        def read_until(marker, timeout=6):
            end = time.monotonic() + timeout
            while marker not in transcript:
                if time.monotonic() > end:
                    self.fail(f'PTY did not reach {marker!r}: {bytes(transcript)!r}')
                if select.select([fd], [], [], .05)[0]:
                    try: transcript.extend(os.read(fd, 65536))
                    except OSError: self.fail(f'PTY exited before {marker!r}')
        try:
            read_until(b'FIXTURE_PROMPT> ')
            transcript.clear()
            os.write(fd, b"claude\n")
            child = self.wait_record()
            overlay = Path(child['overlay'])
            if mode == 'self-stop':
                time.sleep(.15)
                survived = overlay.exists()
                os.kill(child['pid'], signal.SIGCONT)
                self.assertTrue(survived, 'overlay removed while the native child was SIGSTOPped')
            elif mode in ('terminal-stop', 'terminal-stop-late'):
                read_until(b'READY_FOR_CTRL_Z')
                self.wait_state(child['pid'], 'S')
                os.write(fd, b'\x1a')
                read_until(b'Stopped')
                read_until(b'FIXTURE_PROMPT> ')
                self.wait_state(child['pid'], 'T')
                self.assertTrue(overlay.exists(), 'overlay removed while the foreground job was suspended')
                transcript.clear()
                os.write(fd, b'fg\n')
                self.wait_state(child['pid'], 'S')
                os.write(fd, b'continue\n')
            elif mode == 'interrupt':
                read_until(b'READY_FOR_INTERRUPT')
                os.write(fd, b'\x03')
            read_until(b'FIXTURE_PROMPT> ')
            transcript.clear()
            os.write(fd, b"printf 'FIXTURE_EXIT:%s\\n' \"$?\"\n")
            read_until(b'FIXTURE_EXIT:130' if mode == 'interrupt' else b'FIXTURE_EXIT:17')
            self.assertFalse(overlay.exists(), 'overlay survives actual child exit')
            if mode != 'interrupt': self.assertTrue(json.loads(self.record.read_text())['alive_after'])
        finally:
            # Every fixture descendant belongs to this private PTY session.
            # Resume before terminating so stopped owned processes can exit.
            for sig in [signal.SIGCONT, signal.SIGTERM, signal.SIGKILL]:
                for proc in Path('/proc').iterdir():
                    if not proc.name.isdigit(): continue
                    candidate = int(proc.name)
                    try:
                        if os.getsid(candidate) == pid: os.kill(candidate, sig)
                    except (ProcessLookupError, PermissionError): pass
                time.sleep(.03)
            os.close(fd)
            try: os.waitpid(pid, 0)
            except ChildProcessError: pass

    def test_sigstop_overlay_survives_actual_child_lifetime(self):
        self.interactive('self-stop')

    def test_terminal_suspend_resume_preserves_overlay(self):
        self.interactive('terminal-stop')

    def test_terminal_suspend_resume_waits_for_delayed_child_stop(self):
        self.env['FIXTURE_DELAY_STOP'] = '1'
        self.interactive('terminal-stop')

    def test_terminal_suspend_waits_for_late_stopping_child_before_fg(self):
        # PR 1685 Pro round 1: python-suite-discovery failed when `fg`, typed
        # as soon as Bash reported the job stopped, went to the native child.
        self.interactive('terminal-stop-late')
        self.assertNotIn('stolen', json.loads(self.record.read_text()))

    def test_interrupt_cleans_overlay_and_preserves_status(self):
        self.interactive('interrupt')


if __name__ == '__main__':
    unittest.main(verbosity=2)
