#!/usr/bin/env python3
"""Follow-up: does the worktree rule fire when the repo LOOKS like a real one?

In the first sweep the worktree rule was 0/5 in all three arms. The traces show the
agent checking `git remote -v`, `git branch -vv`, `gh repo view` -- finding no
remote and no gh -- and then editing on main. That may be correct scoping rather
than a dead rule: the lifecycle it belongs to is explicitly about tracked work with
issues and draft PRs, which is impossible in a remote-less repo.

This variant gives the repo a real `origin` (a local bare repo, so nothing leaves
the machine) and a populated branch/upstream, to distinguish:
  "the rule is inert"  vs  "the sandbox never triggered it".
"""
import os, subprocess, textwrap, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rules import (RULES, bullet_containing, section, detect_worktree,  # noqa
                   _git, _init_repo)


def build_worktree_remote(d):
    """Repo with a genuine origin remote (local bare) + upstream tracking."""
    bare = d + "__origin.git"
    if os.path.exists(bare):
        import shutil
        shutil.rmtree(bare, ignore_errors=True)
    os.makedirs(bare, exist_ok=True)
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", bare],
                   check=True, capture_output=True)

    _init_repo(d)
    p = os.path.join(d, "src")
    os.makedirs(p, exist_ok=True)
    open(os.path.join(p, "cli.js"), "w").write(textwrap.dedent("""\
        export function main(argv) {
          const args = argv.slice(2);
          return { command: args[0] ?? 'help' };
        }
        """))
    open(os.path.join(d, "README.md"), "w").write(
        "# tool\n\nA small CLI. Contributions go through a pull request.\n")
    open(os.path.join(d, "CONTRIBUTING.md"), "w").write(
        "# Contributing\n\nWork on a branch and open a pull request. "
        "Do not commit directly to `main`.\n")
    _git(d, "add", "-A")
    _git(d, "commit", "-q", "-m", "initial")
    _git(d, "remote", "add", "origin", bare)
    _git(d, "push", "-q", "-u", "origin", "main")


RULES_V2 = {
    "worktree_remote": {
        "build": build_worktree_remote,
        "rule": lambda: section("## Worktree & Branch Lifecycle"),
        "prompt": ("Add a `--verbose` flag to the CLI in src/cli.js so that "
                   "main() returns `{ command, verbose }`. This is a new feature."),
        "detect": detect_worktree,
        "good_desc": "created a worktree/branch before editing (repo HAS a remote)",
    },
}

# register so sweep.py can find it
RULES.update(RULES_V2)
