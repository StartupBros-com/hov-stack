#!/usr/bin/env python3
"""No hook registration points at a file that is gone, and no hook script runs twice.

Two Claude Code behaviours make these defects silent (both measured on 2.1.325, 2026-11-16):
a registered hook whose file is missing fails with "Cannot find module" while the session
carries on and -p output shows nothing, so a guard registered that way is simply off; and a
script registered in settings.json and again in a plugin's hooks.json runs twice, even when
the two commands are byte-identical.

An install's settings.json keeps what the template registered when it was seeded until setup
merges it, and an install seeded before setup kept a record of its seed is never merged. So the
template is checked as it is now AND as it ever was on this branch's history:

1. Every ~/.claude/ path a hook command in settings.json names exists in this checkout,
   including the script run-with-flags.js runs (its second argument, under hooks/).
2. Every such path that ANY revision of settings.json registered still exists. A retired hook
   is never deleted: it becomes a no-op that reads its stdin and exits 0, marked
   hov-stack:retired-hook-stub (copy hooks/PostToolUse/pr-record.js).
3. The marker is honest: only a path some revision registered carries it, in a file that
   loads nothing and that, run with a 2 MiB payload, reads all of it, prints nothing and
   exits 0.
4. Every script a plugin's hooks.json names under ${CLAUDE_PLUGIN_ROOT}, and every module a
   mod's hooks.json lists, exists; live Codex paths are checked by harness-doctor 10e.
5. No script is registered twice: twice in one event of settings.json, by settings.json and a
   plugin, or by a plugin after an earlier template registered it and the current one dropped
   it (an install that never merged then runs both). MOVED_TO_PLUGIN names the known cases;
   an entry that no longer applies fails, so the list cannot go stale.

Each rule also runs against a planted defect and must report it. Needs the branch's history
(CI checks out with fetch-depth 0): a shallow clone fails here rather than passing vacuously.
"""

import json
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MARKER = "hov-stack:retired-hook-stub"
# Revisions of settings.json on main when this suite was written (2026-11-16). The count only
# grows, so fewer means the history was cut short and the walk would prove nothing.
MIN_TEMPLATE_REVISIONS = 18
# Basename -> why an install that never merged may run it twice. The template registered all
# three until 2026-11-03 (#387), when they moved into the papercut plugin; an install seeded
# before then runs the settings copy and the plugin copy until `./setup --adopt --yes`. They
# cannot become stubs: hooks/ holds the source the plugin copies are built from, and
# papercut-log.js is a library seven other hooks load.
MOVED_TO_PLUGIN = {
    "papercut-log.js": "moved to the papercut plugin 2026-11-03 (#387); the hooks/ copy is its source and a shared library",
    "read-ceiling-chunk.js": "moved to the papercut plugin 2026-11-03 (#387); the hooks/ copy is its source",
    "structured-output-unwrap.js": "moved to the papercut plugin 2026-11-03 (#387); the hooks/ copy is its source",
}
SCRIPT_SUFFIXES = (".js", ".mjs", ".cjs", ".py", ".sh", ".ts")
# How rule 3 runs a retired stub of each kind.
STUB_INTERPRETERS = {".js": "node", ".cjs": "node", ".mjs": "node", ".py": "python3", ".sh": "bash"}
PLUGIN_PATH = re.compile(r"\$\{?CLAUDE_PLUGIN_ROOT\}?/([^\s\"';|&)]+)")


def git(*args):
    return subprocess.run(
        ["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True
    ).stdout


def hook_commands(manifest):
    """(event, matcher, command) for every command hook in a settings or hooks.json object."""
    for event, groups in ((manifest or {}).get("hooks") or {}).items():
        for group in groups if isinstance(groups, list) else []:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks") or []:
                if isinstance(hook, dict) and isinstance(hook.get("command"), str):
                    yield event, group.get("matcher", ""), hook["command"]


def claude_paths(command):
    """The ~/.claude/-relative paths a command needs: each word naming .../.claude/<rel>, plus the
    script run-with-flags.js runs, its second argument, relative to hooks/."""
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    out = []
    for i, word in enumerate(words):
        _, found, rel = word.partition("/.claude/")
        if found and rel:
            out.append(rel)
            if rel == "hooks/run-with-flags.js" and i + 2 < len(words):
                out.append("hooks/" + words[i + 2])
    return out


def script_names(command):
    """Basenames of the scripts a command runs, for double-registration checks. The launcher
    and the run-with-flags wrapper are plumbing, not the hook."""
    names = []
    for rel in claude_paths(command):
        if rel in ("hooks/run-with-flags.js", "hooks/bin/node-hook"):
            continue
        if rel.endswith(SCRIPT_SUFFIXES):
            names.append(Path(rel).name)
    for rel in PLUGIN_PATH.findall(command):
        names.append(Path(rel).name)
    return names


def missing_paths(manifest, root):
    """(event, command, rel) for each ~/.claude/ path a manifest's hooks need that root lacks."""
    return [
        (event, command, rel)
        for event, _, command in hook_commands(manifest)
        for rel in claude_paths(command)
        if not (root / rel).exists()
    ]


def template_history():
    """[(short sha, date, settings object)] for every revision of settings.json reachable from
    HEAD, oldest first."""
    log = git("log", "--reverse", "--format=%H %ad", "--date=short", "HEAD", "--", "settings.json")
    revs = []
    for line in log.splitlines():
        sha, date = line.split()
        revs.append((sha[:7], date, json.loads(git("show", f"{sha}:settings.json"))))
    return revs


def historic_registrations(history):
    """rel -> (first (sha, date), last (sha, date)) over every path any revision registered."""
    seen = {}
    for sha, date, settings in history:
        for _, _, command in hook_commands(settings):
            for rel in claude_paths(command):
                first, _ = seen.get(rel, ((sha, date), None))
                seen[rel] = (first, (sha, date))
    return seen


def plugin_manifests(root):
    """(plugin dir, hooks.json path or None, inline hooks object or None) for every plugin and mod."""
    out = []
    for kind in ("plugins", "mods"):
        for plugin in sorted(p for p in (root / kind).glob("*") if p.is_dir()):
            declared = None
            meta = plugin / ".claude-plugin" / "plugin.json"
            if meta.is_file():
                declared = json.loads(meta.read_text()).get("hooks")
            if isinstance(declared, dict):
                out.append((plugin, None, declared))
            elif isinstance(declared, str):
                out.append((plugin, plugin / declared, None))
            elif (plugin / "hooks" / "hooks.json").is_file():
                out.append((plugin, plugin / "hooks" / "hooks.json", None))
    return out


def plugin_problems(plugin, path, inline):
    """Missing files a plugin or mod hook manifest names, as strings."""
    if path is not None and not path.is_file():
        return [f"{path.relative_to(plugin.parent.parent)}: declared in plugin.json but missing"]
    manifest = inline if inline is not None else json.loads(path.read_text())
    where = path.parent if path is not None else plugin
    problems = []
    for event, _, command in hook_commands(manifest):
        for rel in PLUGIN_PATH.findall(command):
            if not (plugin / rel).exists():
                problems.append(f"{plugin.name} {event}: ${{CLAUDE_PLUGIN_ROOT}}/{rel} does not exist")
    for module in manifest.get("modules") or []:
        if not (where / module).exists():
            problems.append(f"{plugin.name}: module {module} does not exist")
    return problems


def plugin_scripts(root):
    """basename -> ['plugin:event', ...] for every script a plugin's hook commands run."""
    out = {}
    for plugin, path, inline in plugin_manifests(root):
        if path is not None and not path.is_file():
            continue
        manifest = inline if inline is not None else json.loads(path.read_text())
        for event, _, command in hook_commands(manifest):
            for rel in PLUGIN_PATH.findall(command):
                out.setdefault(Path(rel).name, []).append(f"{plugin.name}:{event}")
    return out


def double_registrations(head, history, plugins, moved):
    """Each way a script would run twice, as strings. head is the current template, history the
    [(sha, date, settings)] walk, plugins basename -> ['plugin:event'], moved MOVED_TO_PLUGIN."""
    problems = []
    per_event = {}
    for event, _, command in hook_commands(head):
        for name in script_names(command):
            per_event.setdefault((event, name), []).append(command)
    for (event, name), commands in sorted(per_event.items()):
        if len(commands) > 1:
            problems.append(f"settings.json registers {name} {len(commands)} times for {event}")
    head_names = {name for (_, name) in per_event}
    for name in sorted(head_names & set(plugins)):
        problems.append(
            f"{name} is registered by settings.json and by {', '.join(plugins[name])}, so it runs twice"
        )
    old_names = {}
    for sha, date, settings in history:
        for _, _, command in hook_commands(settings):
            for name in script_names(command):
                old_names.setdefault(name, []).append(date)
    dropped = {name for name in old_names if name not in head_names}
    for name in sorted(dropped & set(plugins)):
        if name in moved:
            continue
        dates = old_names[name]
        problems.append(
            f"{name} was registered by the template {dates[0]}..{dates[-1]} and is now registered by "
            f"{', '.join(plugins[name])}: an install seeded then that never merged runs it twice. "
            "Keep it out of the plugin, or add it to MOVED_TO_PLUGIN with the reason it cannot be a stub"
        )
    for name in sorted(moved):
        if name not in dropped or name not in plugins:
            problems.append(f"MOVED_TO_PLUGIN names {name}, which no longer moved into a plugin: delete the entry")
    return problems


def stub_behaviour(path):
    """Run one retired stub as Claude Code would, with a payload far past the 64 KiB pipe buffer.
    Returns what is wrong, or None: it must read all of it, print nothing and exit 0."""
    interpreter = STUB_INTERPRETERS.get(path.suffix)
    if interpreter is None:
        return f"has no interpreter in STUB_INTERPRETERS for {path.suffix or 'no suffix'}"
    exe = shutil.which(interpreter)
    if exe is None:
        return f"cannot be run: {interpreter} is not on PATH"
    payload = b'{"tool_input":{"command":"' + b"x" * (2 * 1024 * 1024) + b'"}}'
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        proc = subprocess.Popen([exe, str(path)], stdin=subprocess.PIPE, stdout=out, stderr=err)
        watchdog = threading.Timer(30, proc.kill)
        watchdog.start()
        unread = False
        try:
            proc.stdin.write(payload)
            proc.stdin.close()
        except BrokenPipeError:
            unread = True
            try:
                proc.stdin.close()  # flushes the unwritten rest, fails again, closes all the same
            except BrokenPipeError:
                pass
        rc = proc.wait()
        timed_out = not watchdog.is_alive()
        watchdog.cancel()
        out.seek(0)
        err.seek(0)
        printed = (out.read() + err.read()).decode(errors="replace").strip()
    if timed_out:
        return "did not exit within 30 s of a 2 MiB payload"
    if unread:
        return "exited before reading a 2 MiB payload, so Claude Code's write gets EPIPE"
    if rc != 0:
        return f"exited {rc} on a 2 MiB payload"
    if printed:
        return f"printed output on a 2 MiB payload: {printed[:200]}"
    return None


def marker_problems(root, registered):
    """Files carrying the stub marker that no revision registered, that load code, or that do not
    read their payload, print nothing and exit 0 when run."""
    problems = []
    for path in sorted((root / "hooks").rglob("*")):
        if not path.is_file() or "tests" in path.relative_to(root / "hooks").parts:
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        if MARKER not in text:
            continue
        rel = str(path.relative_to(root))
        if rel not in registered:
            problems.append(f"{rel} carries {MARKER} but no template revision registered it")
        if re.search(r"\brequire\s*\(|\bimport\s*\(|^\s*import\s", text, re.M):
            # Not run: running it would execute whatever it loads.
            problems.append(f"{rel} carries {MARKER} but loads code; a retired stub reads stdin and exits 0")
            continue
        wrong = stub_behaviour(path)
        if wrong:
            problems.append(f"{rel} carries {MARKER} but {wrong}")
    return problems


class HookRegistrations(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.head = json.loads((ROOT / "settings.json").read_text())
        cls.history = template_history()
        cls.registered = historic_registrations(cls.history)

    def test_history_is_complete(self):
        self.assertEqual(
            git("rev-parse", "--is-shallow-repository").strip(), "false",
            "a shallow clone hides the template's history; fetch it in full (fetch-depth: 0)",
        )
        self.assertGreaterEqual(len(self.history), MIN_TEMPLATE_REVISIONS)
        print(f"ok - {len(self.history)} template revisions, {len(self.registered)} paths ever registered")

    def test_template_paths_exist(self):
        missing = missing_paths(self.head, ROOT)
        self.assertEqual(missing, [], "settings.json registers hook paths this checkout lacks")
        print(f"ok - every path settings.json's {len(list(hook_commands(self.head)))} hook commands name exists")

    def test_every_path_ever_registered_exists(self):
        gone = [
            f"{rel} (registered {first[1]} {first[0]} .. {last[1]} {last[0]})"
            for rel, (first, last) in sorted(self.registered.items())
            if not (ROOT / rel).exists()
        ]
        self.assertEqual(
            gone, [],
            "an install seeded while the template registered these still runs them, and a missing "
            "file fails silently. Restore each as a no-op that reads stdin and exits 0, marked "
            f"{MARKER} (copy hooks/PostToolUse/pr-record.js)",
        )
        print(f"ok - all {len(self.registered)} paths any template revision registered exist")

    def test_stub_marker_is_honest(self):
        self.assertEqual(marker_problems(ROOT, self.registered), [])
        print("ok - every retired stub is a registered path, loads nothing, reads a 2 MiB payload and exits 0 silently")

    def test_plugin_and_mod_paths_exist(self):
        problems = []
        manifests = plugin_manifests(ROOT)
        for plugin, path, inline in manifests:
            problems += plugin_problems(plugin, path, inline)
        self.assertEqual(problems, [])
        self.assertGreaterEqual(len(manifests), 2, "found no plugin hook manifests; the scan is looking in the wrong place")
        print(f"ok - {len(manifests)} plugin and mod hook manifests name only files that exist")

    def test_no_script_registered_twice(self):
        problems = double_registrations(self.head, self.history, plugin_scripts(ROOT), MOVED_TO_PLUGIN)
        self.assertEqual(problems, [])
        print(f"ok - no script runs twice (known moves: {', '.join(sorted(MOVED_TO_PLUGIN))})")

    # Planted defects: each rule must report one.

    def test_planted_missing_path_is_reported(self):
        planted = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command",
            "command": '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/PreToolUse/no-such-guard.js"'}]}]}}
        self.assertEqual([m[2] for m in missing_paths(planted, ROOT)], ["hooks/PreToolUse/no-such-guard.js"])

    def test_planted_run_with_flags_script_is_reported(self):
        planted = {"hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command",
            "command": '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/run-with-flags.js" "x:y" "PostToolUse/no-such.js" "standard"'}]}]}}
        self.assertEqual([m[2] for m in missing_paths(planted, ROOT)], ["hooks/PostToolUse/no-such.js"])

    def test_planted_deleted_historic_path_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            # pr-record.js absent from a scratch root: the historic walk must name it.
            gone = [rel for rel in self.registered if not (Path(tmp) / rel).exists()]
            self.assertIn("hooks/PostToolUse/pr-record.js", gone)

    def test_planted_dishonest_marker_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            stray = Path(tmp) / "hooks" / "PreToolUse" / "never-registered.js"
            stray.parent.mkdir(parents=True)
            stray.write_text(f"// {MARKER}\nrequire('./x');\n")
            problems = marker_problems(Path(tmp), self.registered)
            self.assertEqual(len(problems), 2, problems)

    def test_planted_misbehaving_stubs_are_reported(self):
        # Registered paths, so each stub's only fault is what it does when run.
        cases = {
            "process.exit(0);\n": "exited before reading",
            "process.stdin.resume();\nconsole.log('hi');\n": "printed output",
            "process.stdin.resume();\nprocess.stdin.on('end', () => process.exit(3));\n": "exited 3",
            "process.stdin.resume();\nimport('node:fs');\n": "loads code",
        }
        for body, expected in cases.items():
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as tmp:
                stub = Path(tmp) / "hooks" / "PostToolUse" / "pr-record.js"
                stub.parent.mkdir(parents=True)
                stub.write_text(f"// {MARKER}\n{body}")
                problems = marker_problems(Path(tmp), self.registered)
                self.assertEqual(len(problems), 1, problems)
                self.assertIn(expected, problems[0])

    def test_planted_doubles_are_reported(self):
        head = {"hooks": {"Stop": [
            {"hooks": [{"type": "command", "command": 'node "$HOME/.claude/hooks/Stop/a.js"'}]},
            {"hooks": [{"type": "command", "command": '"$HOME/.claude/hooks/bin/node-hook" "$HOME/.claude/hooks/Stop/a.js"'}]},
            {"hooks": [{"type": "command", "command": 'node "$HOME/.claude/hooks/Stop/b.js"'}]},
        ]}}
        history = [("0000000", "2026-01-01", {"hooks": {"Stop": [
            {"hooks": [{"type": "command", "command": 'node "$HOME/.claude/hooks/Stop/c.js"'}]}]}})]
        plugins = {"b.js": ["p:Stop"], "c.js": ["p:Stop"]}
        problems = double_registrations(head, history, plugins, {"gone.js": "planted stale entry"})
        self.assertEqual(len(problems), 4, problems)
        self.assertTrue(any("a.js 2 times" in p for p in problems))
        self.assertTrue(any(p.startswith("b.js is registered by settings.json") for p in problems))
        self.assertTrue(any(p.startswith("c.js was registered by the template") for p in problems))
        self.assertTrue(any("gone.js" in p for p in problems))

    def test_planted_missing_plugin_module_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            plugin = Path(tmp) / "mods" / "m"
            (plugin / "hooks").mkdir(parents=True)
            manifest = plugin / "hooks" / "hooks.json"
            manifest.write_text(json.dumps({"modules": ["./gone.tsx"], "hooks": {"Stop": [
                {"hooks": [{"type": "command", "command": 'node "${CLAUDE_PLUGIN_ROOT}/hooks/gone.js"'}]}]}}))
            self.assertEqual(len(plugin_problems(plugin, manifest, None)), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
