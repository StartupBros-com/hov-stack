#!/usr/bin/env python3
"""Check that the counts the README states are the tree's.

The README states counts of what this tree holds (permission entries, hooks,
skills, detail docs, suites) and lists the plugins the hov marketplace serves.
Each drifts with the next commit, and a stale count on the front page is a false
claim; the README this replaced said 40 detail docs and 16 pre-tool guards when
the tree held 35 and 12 (restructure plan U19, #69). Python suite discovery runs
this through tests/test_readme.py, so CI checks every push.

Legs, each reported by name:

- counts: every phrase in phrases(), rendered from the tree, appears in the README.
- unchecked numbers: no number is left in "What's here" or "What's not here" that
  a phrase did not account for, so a count is either recomputed here or gone.
- paths: every backticked repository path in those two sections exists, and so does
  every backticked file name (a dotfile, or a name with an extension) at the top level
  or under the directory its bullet names.
- hooks: every hook the hooks bullet names runs before a tool call.
- repositories: the only repository under the author's two GitHub owners, in any case,
  that the README, CONTRIBUTING.md and SECURITY.md name is StartupBros-com/hov-stack.
- plugin groups: the plugins section lists lib/default-plugins.txt under "Installed
  by ./setup" and /hov-setup's list under its own heading, in their order.
- plugin list: with a manifest, the plugin bullets are the manifest's plugins,
  leaving out the hov-stack pack's own entry. Without one this leg is reported as
  not run, never as passed.

This reads files. It does not run setup, resolve a URL, or show that an install
works. Retire it if the README stops stating tree counts.
"""
from __future__ import annotations

import argparse
import glob
import json
import re
import shlex
import string
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(".claude-plugin/marketplace.json")
DOCS = ("README.md", "CONTRIBUTING.md", "SECURITY.md")
OWNER = "StartupBros-com"
REPO_NAME = "hov-stack"
# The public owner and the private one; the docs may name only OWNER/REPO_NAME under either.
OWNERS = r"(?i)\b(startupbros(?:-com)?)/([A-Za-z0-9._-]+)"
PACK = "hov-stack"
COUNTED_SECTIONS = ("What's here", "What's not here")
PLUGINS_SECTION = "The plugins"
SETUP_GROUP = "Installed by `./setup`"
GUIDED_GROUP = "Set up through `/hov-setup`"
HOOKS_BULLET = "- `hooks/`"
# Paths those sections name that ./setup creates at install time, outside the tree.
INSTALL_TIME_PATHS = {
    "rules/": "the rules directory in the Claude Code config dir",
    "rules/hov-stack-overlay.md": "the import ./setup writes in the Claude Code config dir",
}
# File names those sections give for the private overlay, which is outside the tree.
OVERLAY_FILES = {
    "supabase-projects.json": "an overlay file; config/supabase-projects.example.json shows its shape",
    "migration-targets.json": "an overlay file; config/migration-targets.example.json shows its shape",
    "repo-routes.json": "an overlay file that replaces the tracked placeholder",
}
# A backticked name with no slash that reads as a file: a dotfile or a name with an extension.
FILE_NAME = re.compile(r"\.[A-Za-z][\w.-]*|[\w.-]+\.(?:sh|md|json|js|mjs|py|txt|toml|ya?ml)")
# Numbers in the counted sections that are not counts of anything in the tree.
NOT_COUNTS = {
    "exits 1": "an exit status",
}
NUMBER_WORDS = ("zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                "sixteen", "seventeen", "eighteen", "nineteen", "twenty")
# "one" reads as a pronoun far more often than as a count, so the scan skips it.
SCANNED_WORDS = NUMBER_WORDS[2:] + ("thirty", "forty", "fifty", "sixty", "seventy", "eighty",
                                    "ninety", "hundred", "thousand", "dozen")


def words(n: int) -> str:
    return NUMBER_WORDS[n] if 0 <= n < len(NUMBER_WORDS) else str(n)


def ticked(names: list[str], last: str = ", ") -> str:
    """`a`, `b` and `c` (last=" and ") or `a`, `b`, `c` (last=", ")."""
    quoted = [f"`{name}`" for name in names]
    if len(quoted) < 2:
        return "".join(quoted)
    return ", ".join(quoted[:-1]) + last + quoted[-1]


def hook_scripts(settings: dict, root: Path) -> dict[str, set[str]]:
    """Map each hook event to the in-tree scripts settings.json registers for it.

    A command names its script directly (node "$HOME/.claude/hooks/Event/x.js") or
    through run-with-flags.js, whose second argument is the script under hooks/.
    Commands that run nothing under hooks/, like dcg, are not counted here.
    """
    events: dict[str, set[str]] = {}
    for event, groups in settings.get("hooks", {}).items():
        scripts = events.setdefault(event, set())
        for group in groups:
            for hook in group.get("hooks", []):
                words_ = shlex.split(hook.get("command", ""))
                for i, word in enumerate(words_):
                    if word.endswith("/hooks/run-with-flags.js"):
                        if i + 2 < len(words_):
                            scripts.add(words_[i + 2])
                        break
                    _, found, rel = word.partition("/.claude/hooks/")
                    if found and rel.endswith(".js"):
                        scripts.add(rel)
                        break
        events[event] = {rel for rel in scripts if (root / "hooks" / rel).is_file()}
    return events


def slash_only(skill_md: Path) -> bool:
    """True when the SKILL.md frontmatter, not its body, sets disable-model-invocation."""
    lines = skill_md.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "---":
        return False
    for line in lines[1:]:
        if line.strip() == "---":
            return False
        key, _, value = line.partition(":")
        if key.strip() == "disable-model-invocation" and value.strip() == "true":
            return True
    return False


def listed(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def guided_plugins(detect: Path) -> list[str]:
    """The names in detect.mjs's PLUGINS array, in order."""
    text = detect.read_text(encoding="utf-8")
    _, found, rest = text.partition("export const PLUGINS = [")
    if not found:
        raise ValueError(f"{detect}: no PLUGINS array")
    body = rest.partition("];")[0]
    return re.findall(r'\bname: "([a-z0-9-]+)"', body)


def tree_facts(root: Path) -> dict:
    settings = json.loads((root / "settings.json").read_text(encoding="utf-8"))
    hooks = hook_scripts(settings, root)
    skills = sorted((root / "plugins/hov-stack/skills").glob("*/SKILL.md"))
    skips = [line.split("\t")[0] for line in listed(root / "tests/claude-tests.skips")]
    return {
        "allow": len(settings["permissions"]["allow"]),
        "ask": len(settings["permissions"]["ask"]),
        "deny": len(settings["permissions"]["deny"]),
        "hook_events": len(hooks),
        "hook_scripts": len(set().union(*hooks.values())),
        "pre_tool": len(hooks.get("PreToolUse", ())),
        "pre_tool_names": sorted(Path(rel).stem for rel in hooks.get("PreToolUse", ())),
        "hook_tests": len(list((root / "hooks/tests").glob("*.test.js"))),
        "harness_docs": len(list((root / "harness").glob("*.md"))),
        "claude_kb": round((root / "CLAUDE.md").stat().st_size / 1024),
        "skills": len(skills),
        "slash_only": sum(slash_only(path) for path in skills),
        "patches": len([p for p in (root / "skills-patches").iterdir() if p.is_dir()]),
        "stack_skills": len(list((root / "skills-stack").glob("*/SKILL.md"))),
        "repo_suites": len(list((root / "tests/repo").glob("*.test.sh"))),
        "skips": len(skips),
        "xfail": skips.count("xfail"),
        "skip": skips.count("skip"),
        "default_plugins": listed(root / "lib/default-plugins.txt"),
        "guided_plugins": guided_plugins(root / "plugins/hov-stack/skills/hov-setup/scripts/detect.mjs"),
    }


def phrases(f: dict) -> list[tuple[str, str, dict]]:
    """(what is counted, template, values). Each template ends in literal text."""
    perms = {"allow": f["allow"], "ask": f["ask"], "deny": f["deny"]}
    return [
        ("settings.json permission entries", "{allow} allow, {ask} ask and {deny} deny entries", perms),
        ("settings.json permission entries", "({allow} / {ask} / {deny} entries)", perms),
        ("PreToolUse hook scripts", "plus {n} hooks that run before a tool call lands", {"n": f["pre_tool"]}),
        ("hook scripts settings.json registers", "{n} hook scripts that `settings.json` registers",
         {"n": f["hook_scripts"]}),
        ("hook events", "across {n} hook events", {"n": f["hook_events"]}),
        ("PreToolUse hook scripts", "; {n} of them run before a tool call", {"n": f["pre_tool"]}),
        ("hook test files", "{n} test files in `hooks/tests/`", {"n": f["hook_tests"]}),
        ("CLAUDE.md size", "loads ({n} KB)", {"n": f["claude_kb"]}),
        ("detail docs in harness/", "{n} detail docs in `harness/`", {"n": f["harness_docs"]}),
        ("skills in plugins/hov-stack/skills", "{n} skills, ", {"n": f["skills"]}),
        ("slash-command-only skills", "{n} of them slash-command only", {"n": f["slash_only"]}),
        ("patched third-party skills", "patches to {n} third-party skills", {"n": f["patches"]}),
        ("skills-stack skills", "`skills-stack/`: {n} more slash-command skills", {"n": f["stack_skills"]}),
        ("tests/repo suites", "the {n} repository suites", {"n": words(f["repo_suites"])}),
        ("skipped suites", "names the {n} suites that cannot pass", {"n": f["skips"]}),
        ("xfail suites", ": {n} read the author's", {"n": f["xfail"]}),
        ("skip suites", ", {n} needs real Docker", {"n": f["skip"]}),
        ("xfail suites", "still runs the first {n}, ", {"n": f["xfail"]}),
        ("lib/default-plugins.txt", "installs the default plugins ({names}).",
         {"names": ticked(f["default_plugins"])}),
        ("/hov-setup plugins", "{n} plugins need what a script cannot do",
         {"n": words(len(f["guided_plugins"])).capitalize()}),
        ("/hov-setup plugins", "They are {names}.", {"names": ticked(f["guided_plugins"], " and ")}),
    ]


def what_readme_says(template: str, readme: str) -> list[str]:
    """The README's own values where the template's literal text matches."""
    pattern = ""
    for literal, field, _, _ in string.Formatter().parse(template):
        pattern += re.escape(literal)
        if field is not None:
            pattern += r"([^\n]+?)" if field == "names" else r"(\S+)"
    return [" / ".join(m) if isinstance(m, tuple) else m for m in re.findall(pattern, readme)]


def without_comments(text: str) -> str:
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def sections(markdown: str, level: str = "##") -> dict[str, str]:
    """Body text under each heading of exactly this level, outside fenced code."""
    out: dict[str, str] = {}
    current = None
    fence = False
    for line in markdown.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fence = not fence
        if not fence and line.startswith(level + " "):
            current = line[len(level) + 1:].strip()
            out[current] = ""
            continue
        if not fence and current is not None and re.match(r"#{1,%d} " % len(level), line):
            current = None
        if current is not None:
            out[current] += line + "\n"
    return out


def check_counts(readme: str, facts: dict) -> list[str]:
    problems = []
    for what, template, values in phrases(facts):
        rendered = template.format(**values)
        if rendered in readme:
            continue
        found = what_readme_says(template, readme)
        says = f"the README says {', '.join(repr(v) for v in found)}" if found else "the README does not state it"
        problems.append(f"counts: {what}: the tree gives {rendered!r}; {says}")
    return problems


def check_unchecked_numbers(readme: str, facts: dict) -> list[str]:
    problems = []
    body = sections(readme)
    for title in COUNTED_SECTIONS:
        if title not in body:
            problems.append(f"unchecked numbers: no {title!r} section")
            continue
        text = body[title]
        for _, template, values in phrases(facts):
            text = text.replace(template.format(**values), " ")
        for phrase in NOT_COUNTS:
            text = text.replace(phrase, " ")
        # A code span is a name unless it opens with a digit (`30 hooks` is a count).
        text = re.sub(r"`([^`\n]*)`", lambda span: span[1] if span[1][:1].isdigit() else " ", text)
        # A digit after a letter (WSL2) is part of a name; one before a hyphen or a
        # letter (12-15, 3x, 46-file) is still a count.
        number = r"(?<![A-Za-z_.])\d+(?:[.,]\d+)*"
        for match in re.finditer(number + r"|\b(?:%s)\b" % "|".join(SCANNED_WORDS), text, flags=re.I):
            start = max(0, match.start() - 30)
            context = " ".join(text[start:match.end() + 30].split())
            problems.append(f"unchecked numbers: {title!r} states {match.group()!r} that no count "
                            f"recomputes ({context!r}); add it to phrases() or drop it")
    return problems


def check_paths(readme: str, root: Path) -> list[str]:
    problems = []
    body = sections(readme)
    for title in COUNTED_SECTIONS:
        base = None  # the directory the current top-level bullet opens with, if any
        for line in body.get(title, "").splitlines():
            if line.startswith("- "):
                opening = re.match(r"- `([^`\n ]+/)`", line)
                base = opening[1] if opening else None
            elif line and not line[0].isspace():
                base = None
            for token in re.findall(r"`([^`\n]+)`", line):
                if " " in token or token.startswith(("~", "$", "/")):
                    continue
                if token in INSTALL_TIME_PATHS or token in OVERLAY_FILES:
                    continue
                if "/" not in token:
                    if not FILE_NAME.fullmatch(token):
                        continue
                    if (root / token).exists() or (base and (root / base / token).exists()):
                        continue
                    where = f"at the top level or under {base!r}" if base else "at the top level"
                    problems.append(f"paths: {title!r} names {token!r}, which is not in the tree {where}")
                    continue
                path = token[2:] if token.startswith("./") else token
                if any(char in path for char in "*?["):
                    if not glob.glob(str(root / path)):
                        problems.append(f"paths: {title!r} names {token!r}, which matches nothing in the tree")
                elif not (root / path).exists():
                    problems.append(f"paths: {title!r} names {token!r}, which is not in the tree")
    return problems


def check_hooks(readme: str, facts: dict) -> list[str]:
    bullets = [line for line in sections(readme).get("What's here", "").splitlines()
               if line.startswith(HOOKS_BULLET)]
    if len(bullets) != 1:
        return [f"hooks: expected one {HOOKS_BULLET!r} bullet in 'What's here', found {len(bullets)}"]
    named = re.findall(r"`([a-z0-9-]+)`", bullets[0])
    return [f"hooks: the hooks bullet names {name!r}, which settings.json does not run before a "
            f"tool call (PreToolUse runs {', '.join(facts['pre_tool_names'])})"
            for name in named if name != "dcg" and name not in facts["pre_tool_names"]]


def check_repositories(docs: dict[str, str]) -> list[str]:
    problems = []
    for name, text in docs.items():
        for owner, repo in re.findall(OWNERS, text):
            repo = repo.removesuffix(".git").rstrip(".")
            if (owner.lower(), repo.lower()) != (OWNER.lower(), REPO_NAME):
                problems.append(f"repositories: {name} names {owner}/{repo}; the only one it may name "
                                f"is {OWNER}/{REPO_NAME}")
    return problems


def plugin_groups(readme: str) -> dict[str, list[str]]:
    groups = sections(sections(readme).get(PLUGINS_SECTION, ""), "###")
    return {title: re.findall(r"^- `([a-z0-9-]+)`:", text, flags=re.M) for title, text in groups.items()}


def check_plugin_groups(readme: str, facts: dict) -> list[str]:
    problems = []
    groups = plugin_groups(readme)
    if not groups:
        return [f"plugin groups: no '### ' groups under '## {PLUGINS_SECTION}'"]
    for title, expected, source in ((SETUP_GROUP, facts["default_plugins"], "lib/default-plugins.txt"),
                                    (GUIDED_GROUP, facts["guided_plugins"], "detect.mjs PLUGINS")):
        if groups.get(title) != expected:
            problems.append(f"plugin groups: {title!r} lists {groups.get(title)}; {source} gives {expected}")
    names = [name for group in groups.values() for name in group]
    for name in sorted({n for n in names if names.count(n) > 1}):
        problems.append(f"plugin groups: {name!r} is listed more than once")
    return problems


def check_plugin_list(readme: str, manifest: dict) -> list[str]:
    plugins = manifest.get("plugins") if isinstance(manifest, dict) else None
    if not isinstance(plugins, list):
        return ['plugin list: the manifest has no "plugins" list']
    unnamed = [i for i, plugin in enumerate(plugins)
               if not (isinstance(plugin, dict) and isinstance(plugin.get("name"), str))]
    if unnamed:
        return [f"plugin list: the manifest's plugins[{i}] has no name" for i in unnamed]
    served = {plugin["name"] for plugin in plugins} - {PACK}
    bullets = {name for group in plugin_groups(readme).values() for name in group}
    problems = [f"plugin list: the manifest serves {name!r}, which the README does not list"
                for name in sorted(served - bullets)]
    problems += [f"plugin list: the README lists {name!r}, which the manifest does not serve"
                 for name in sorted(bullets - served)]
    return problems


def check(docs: dict[str, str], root: Path, manifest: dict | None) -> tuple[list[str], list[str]]:
    """Return (problems, legs not run). docs maps each file name in DOCS to its text."""
    readme = without_comments(docs["README.md"])
    facts = tree_facts(root)
    problems = (check_counts(readme, facts) + check_unchecked_numbers(readme, facts)
                + check_paths(readme, root) + check_hooks(readme, facts)
                + check_repositories(docs) + check_plugin_groups(readme, facts))
    not_run = []
    if manifest is None:
        not_run.append(f"plugin list: not run, {MANIFEST} is absent from this tree")
    else:
        problems += check_plugin_list(readme, manifest)
    return problems, not_run


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="the tree to count (default: this checkout)")
    parser.add_argument("--manifest", type=Path,
                        help=f"the marketplace manifest (default: <root>/{MANIFEST}, if present)")
    args = parser.parse_args()
    try:
        docs = {name: (args.root / name).read_text(encoding="utf-8") for name in DOCS}
        manifest_path = args.manifest or args.root / MANIFEST
        manifest = None
        if args.manifest or manifest_path.exists():
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        problems, not_run = check(docs, args.root, manifest)
    except (OSError, UnicodeError, ValueError, KeyError) as exc:
        print(f"check-readme-counts: {exc}", file=sys.stderr)
        return 1
    for line in not_run:
        print(line)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print("README counts, paths, hooks, repositories and plugin groups match the tree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
