#!/usr/bin/env python3
"""Offline adapter/scope regressions; only synthetic git repos and CLI stubs.

Optional --baseline ROOT compares complete normalized envelopes and exit codes
against an unmodified checkout. --bash PATH also exercises an installed Bash 3.2.
No installed provider executable is reachable from the restricted test PATH.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
ADAPTERS = ("grok", "codex", "claude")
SCRIPT_DIR = Path("skills/token-eater/scripts")


def run(args, env, cwd=None):
    return subprocess.run(args, env=env, cwd=cwd, text=True,
                          capture_output=True, timeout=20)


def checked(args, env, cwd=None):
    result = run(args, env, cwd)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result.stdout


def make_repo(path, env):
    path.mkdir()
    checked(["git", "init", "-q", str(path)], env)
    (path / ".gitignore").write_text("ignored\n")
    for name in ("tracked", "staged", "deleted", "with space", "a.txt"):
        (path / name).write_text("original\n")
    (path / "tracked-link").symlink_to("tracked")
    checked(["git", "add", "."], env, path)
    checked(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
             "commit", "-qm", "fixture", "--no-gpg-sign"], env, path)


def edit_repo(path, kind, env):
    if kind in ("unstaged", "mixed", "deduplicated"):
        (path / "tracked").write_text("changed\n")
    if kind in ("staged", "mixed"):
        (path / "staged").write_text("staged change\n")
        checked(["git", "add", "staged"], env, path)
    if kind == "deduplicated":
        checked(["git", "add", "tracked"], env, path)
        (path / "tracked").write_text("changed again\n")
    if kind in ("deleted", "mixed"):
        (path / "deleted").unlink()
    if kind in ("untracked", "mixed"):
        (path / "new file").write_text("new\n")
    if kind in ("ignored", "mixed"):
        (path / "ignored").write_text("ignored\n")
    if kind in ("symlink", "mixed"):
        (path / "new-link").symlink_to("tracked")
        (path / "dangling-link").symlink_to("absent")
        (path / "tracked-link").unlink()
        (path / "tracked-link").symlink_to("staged")
    if kind in ("spaces", "mixed"):
        (path / "with space").write_text("space change\n")
    if kind == "literal":
        (path / "a.txt").write_text("literal match\n")


EXPECTED = {
    "clean": [], "unstaged": ["tracked"], "staged": ["staged"],
    "deleted": ["deleted"], "untracked": ["new file"], "ignored": [],
    "symlink": [], "spaces": ["with space"], "deduplicated": ["tracked"],
    "literal": ["a.txt"],
    "mixed": ["deleted", "new file", "staged", "tracked", "with space"],
}


STUB = r'''#!/usr/bin/env bash
set -euo pipefail
result=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then result="$2"; shift; fi
  shift
done
case "$STUB_MODE" in
  circuit) printf 'rate limit reached\n' >&2; exit 7 ;;
  nonzero) exit 7 ;;
esac
if [ "$STUB_MODE" = malformed ]; then payload='{invalid'; else payload='{}'; fi
if [ -n "$result" ]; then printf '%s\n' "$payload" > "$result"; fi
printf '%s\n' "$payload"
if [ "$STUB_MODE" = nonzero_result ]; then exit 7; fi
'''


def normalized(result):
    # Only mktemp-generated directory names differ between invocations.
    def paths(text):
        return re.sub(r"te-(?:grok|codex|claude)-[A-Za-z0-9]+", "te-RUN", text)
    return (result.returncode, json.loads(paths(result.stdout)), paths(result.stderr))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--bash", default=shutil.which("bash"))
    args = parser.parse_args()
    bash = str(Path(args.bash).resolve())
    baseline = args.baseline.resolve() if args.baseline else None
    with tempfile.TemporaryDirectory(prefix="delegate-scope-") as temp:
        tmp = Path(temp)
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        # Allow only the tools the wrappers need. In particular, no curl, ssh,
        # package managers, actual providers, or user-specific startup files.
        for tool in ("dirname", "mktemp", "git", "sort", "grep", "awk", "cat", "jq", "tail"):
            executable = shutil.which(tool)
            assert executable, f"required test tool missing: {tool}"
            (bin_dir / tool).symlink_to(executable)
        (bin_dir / "bash").symlink_to(bash)
        for adapter in ADAPTERS:
            stub = bin_dir / adapter
            stub.write_text(STUB)
            stub.chmod(0o755)
        home = tmp / "home"
        home.mkdir()
        env = {"PATH": str(bin_dir), "HOME": str(home), "TMPDIR": str(tmp),
               "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": os.devnull, "GIT_TERMINAL_PROMPT": "0",
               "GIT_ALLOW_PROTOCOL": "", "STUB_MODE": "ok"}
        prompt = tmp / "prompt"
        prompt.write_text("Offline fixture only.\n")
        schema = tmp / "schema.json"
        schema.write_text('{"type":"object"}\n')
        count = 0

        def exercise(repo, allowed, mode, files, offenders, use_schema=False):
            nonlocal count
            for adapter in ADAPTERS:
                call_env = dict(env, STUB_MODE=mode)
                arguments = [str(repo), str(prompt), str(schema) if use_schema else "", allowed]
                current = run([bash, str(ROOT / SCRIPT_DIR / f"delegate-{adapter}.sh"),
                               *arguments], call_env)
                actual = normalized(current)
                if baseline:
                    old = run([bash, str(baseline / SCRIPT_DIR / f"delegate-{adapter}.sh"),
                               *arguments], call_env)
                    assert actual == normalized(old), (adapter, mode, arguments, actual, normalized(old))
                if mode == "circuit":
                    expected_exit = 3
                    assert actual[1]["circuit_breaker"] is True
                elif (adapter == "codex" and mode == "nonzero") or (
                        adapter == "claude" and mode in ("malformed", "nonzero")):
                    expected_exit = 2
                    assert actual[1]["ok"] is False
                else:
                    expected_exit = 4 if offenders else 0
                    assert actual[1]["files_modified"] == files, actual
                    assert actual[1]["scope_offenders"] == offenders, actual
                    assert actual[1]["scope_violation"] == bool(offenders), actual
                    assert actual[1]["made_changes"] == bool(files), actual
                    assert actual[1]["ok"] is True, actual
                assert current.returncode == expected_exit, (adapter, mode, actual)
                assert not current.stderr, current.stderr
                count += 1

        for kind, files in EXPECTED.items():
            repo = tmp / kind
            make_repo(repo, env)
            edit_repo(repo, kind, env)
            for allow_kind in ("omitted", "missing", "empty", "exact", "partial", "substring"):
                allow = tmp / f"allow-{kind}-{allow_kind}"
                lines = []
                if allow_kind == "exact":
                    lines = files
                elif allow_kind == "partial":
                    lines = files[:1]
                elif allow_kind == "substring":
                    lines = ["prefix-" + f + "-suffix" for f in files]
                if allow_kind not in ("omitted", "missing"):
                    allow.write_text("".join(f + "\n" for f in lines))
                offenders = [] if allow_kind in ("omitted", "missing") else [f for f in files if f not in lines]
                exercise(repo, "" if allow_kind == "omitted" else str(allow), "ok", files, offenders)
            # Keep optional schema invocation covered for all three providers.
            exercise(repo, "", "ok", files, [], use_schema=True)
        # A regex-like filename must not match a different literal allowlist line.
        allow = tmp / "literal-allow"
        allow.write_text("aXtxt\n")
        exercise(tmp / "literal", str(allow), "ok", ["a.txt"], ["a.txt"])
        for kind in ("clean", "mixed"):
            allow.write_text("")
            for mode in ("circuit", "nonzero", "malformed", "nonzero_result"):
                exercise(tmp / kind, str(allow), mode, EXPECTED[kind], EXPECTED[kind])

        # Repeated calls must reset all four outputs, return success under -e,
        # and leave caller cwd unchanged (including after a violation).
        helper = ROOT / SCRIPT_DIR / "lib/delegate-common.sh"
        helper_check = r'''
set -euo pipefail
source "$1"
start="$PWD"
delegate_collect_changes_and_scope "$2" "$4"
[ "$MADE_CHANGES" = true ]
[ "$SCOPE_VIOLATION" = true ]
[ "${#CHANGED[@]}" -eq 5 ]
[ "${#OFFENDERS[@]}" -eq 5 ]
delegate_collect_changes_and_scope "$3"
[ "$MADE_CHANGES" = false ]
[ "$SCOPE_VIOLATION" = false ]
[ "${#CHANGED[@]}" -eq 0 ]
[ "${#OFFENDERS[@]}" -eq 0 ]
delegate_collect_changes_and_scope "$2" "$5"
[ "$MADE_CHANGES" = true ]
[ "$SCOPE_VIOLATION" = false ]
[ "${#CHANGED[@]}" -eq 5 ]
[ "${#OFFENDERS[@]}" -eq 0 ]
[ "$PWD" = "$start" ]
printf 'helper resets: PASS\n'
'''
        allow.write_text("")
        checked([bash, "-c", helper_check, "helper-check", str(helper),
                 str(tmp / "mixed"), str(tmp / "clean"), str(allow),
                 str(tmp / "allow-mixed-exact")], env)
        print(f"delegate-scope: PASS ({count} adapter cases; repeated helper calls; "
              f"baseline parity {'enabled' if baseline else 'not requested'})")


if __name__ == "__main__":
    main()
