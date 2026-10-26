#!/usr/bin/env python3
"""The skill pack is the hov-stack Claude Code plugin at plugins/hov-stack (#37, plan KTD11).

WHY: one directory ships two ways. ./setup links its skills one at a time, and the
plugin installs the whole pack. So the plugin's manifest, version file and licence copy
must agree, every entry under its skills/ must be a skill the plugin loader can read,
and the root `skills` link must keep resolving into the pack for anything that reads
the skills there.

Licences (#43, plan R22): every skill directory carries a licence file. A skill under the
root licence carries a byte-identical copy of the root LICENSE; any other licence text
marks third-party material, which has exactly one row in plugins/hov-stack/NOTICE.md whose
licence expression names every licence its files contain. An UPSTREAM.md alone is not a
licence.

Root paths (#47, plan U14): a plugin install holds only this pack, so a skill that reaches
the checkout through a home path (a stack script, the harness docs, or itself or a sibling
under the user's skills directory) works from a ./setup link and nowhere else.

The stack-only skills (#47 decision D1, plan R21's exception): a skill that runs the stack's
scripts lives in skills-stack/, which ./setup links and the plugin does not ship. Every skill
there must reach the checkout, or it belongs in the pack; none may share a pack skill's
name, since both link to the same place; and each carries the root licence, because no
NOTICE row covers that directory.
"""

import json
import os
import re
import unittest
from pathlib import Path

CLAUDE = Path(__file__).resolve().parents[1]
PLUGIN = CLAUDE / "plugins" / "hov-stack"
# A skill's `name:` is lowercase letters, digits and hyphens, and must equal its
# directory name (test_skill_frontmatter.py), so the directory name follows the same rule.
SKILL_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
LICENCE_FILE = re.compile(r"^(LICENSE(-.+)?|LICENSE\.(md|txt)|COPYING)$")
# A licence is recognised by phrases from its body, not its title line: ux-writing's
# LICENSE opens with a blank line, and an MIT text may lead with a copyright line.
LICENCE_PHRASES = {
    "Apache-2.0": ("Apache License", "Version 2.0"),
    "MIT": ("Permission is hereby granted, free of charge, to any person obtaining a copy",),
    "ISC": ("Permission to use, copy, modify, and/or distribute",),
}
NOTICE_ROW = re.compile(r"^\| `([^`]+)` \|([^|]+)\|([^|]+)\|([^|]+)\|$")
NOTICE_HEAD = ("| Skill | Source | Licence | Copyright holder |", "| --- | --- | --- | --- |")
# What ./setup links from the checkout and nothing else provides. agents/, commands/,
# workflows/ and CLAUDE.md are Claude Code's own user paths, so naming them is no proof.
STACK = {"scripts", "hooks", "bin", "lib", "mods", "claude-env.sh"}
# What ends a path word, in prose, shell and code alike: `join(homedir(), ".claude",
# "scripts")` reads as the same words as `~/.claude/scripts`, `$HOME/.claude/bin:$PATH`
# ends its path at the colon, and `**~/.claude/hooks**` drops its emphasis.
SEPARATORS = frozenset(" \t /\\,()[]{};:&|+=`<>*@%")
# A word that names the home directory itself, matched on its last dotted part, so
# process.env.HOME and os.homedir count and JAVA_HOME or $REPO_HOME do not.
HOME_NAMES = {"HOME", "$HOME", "USERPROFILE", "$USERPROFILE", "homedir", "home_dir", "UserHomeDir"}
# Top-level files a skill does not load: its record of where it came from, and its licence.
UNLOADED = {"README.md", "UPSTREAM.md", "PROVENANCE.md"}
# The skills that run a stack script, which a plugin install does not have (#47, D1).
STACK_SKILLS = CLAUDE / "skills-stack"


def skills():
    return sorted(p for p in (PLUGIN / "skills").iterdir() if p.is_dir())


def stack_skills():
    return sorted(STACK_SKILLS.iterdir())


def licence_files(skill):
    return sorted(p for p in skill.iterdir() if p.is_file() and LICENCE_FILE.match(p.name))


def third_party_licences(skill):
    root = (CLAUDE / "LICENSE").read_bytes()
    return [p for p in licence_files(skill) if p.read_bytes() != root]


def detected_licences(text):
    """SPDX ids whose phrases all appear in the first non-blank lines of a licence text."""
    head = " ".join([line.strip() for line in text.splitlines() if line.strip()][:12])
    return {spdx for spdx, phrases in LICENCE_PHRASES.items() if all(p in head for p in phrases)}


def notice_table_lines():
    """NOTICE.md's table lines, trailing whitespace removed."""
    lines = (PLUGIN / "NOTICE.md").read_text().splitlines()
    return [line.rstrip() for line in lines if line.lstrip().startswith("|")]


def notice_rows():
    """skill name -> list of (source, licence expression, holder), one entry per table row."""
    rows = {}
    for line in notice_table_lines():
        m = NOTICE_ROW.match(line)
        if m:
            rows.setdefault(m.group(1), []).append(tuple(c.strip() for c in m.groups()[1:]))
    return rows


def normalised(line):
    """The line with straight and curly quotes dropped and `${` read as `$`, so
    `"${HOME}"/.claude` reads as `$HOME}/.claude`, whose path words are `$HOME` and `.claude`."""
    for quote in "\"'‘’“”":
        line = line.replace(quote, "")
    return line.replace("${", "$")


def path_words(text):
    """(offset in text, word) for each path word of a normalised line: split on SEPARATORS,
    a leading `-` (as in `${X:-~/.claude}`) and trailing sentence punctuation dropped, and
    `.` and `..` skipped. A whole <placeholder> stays one word with its brackets; one that
    runs into more text, as in `<brand>-voice`, does not."""
    words, start = [], None
    for i, ch in enumerate(text + " "):
        if ch in SEPARATORS:
            if start is not None:
                raw = text[start:i]
                at = start + len(raw) - len(raw.lstrip("-"))
                word = raw.lstrip("-").rstrip(".!?…")
                if start and text[start - 1] == "<" and ch == ">" and text[i + 1:i + 2] in SEPARATORS | {""}:
                    at, word = start - 1, f"<{raw}>"
                if word:
                    words.append((at, word))
                start = None
        elif start is None:
            start = i
    return words


def names_home(word):
    """Whether a path word is the home directory itself: ~ or ~user, $HOME or a program's
    HOME lookup, USERPROFILE, homedir(), Path.home()."""
    head, _, last = word.rpartition(".")
    return word.startswith("~") or last in HOME_NAMES or (bool(head) and last == "home")


def starts_absolute(text, at):
    """Whether the path word at offset `at` is the first part of an absolute path, so
    /home/<user> counts and dotfiles/home/<user> or a URL's /Users/ does not."""
    return at >= 1 and text[at - 1] in "/\\" and (at < 2 or not (text[at - 2].isalnum() or text[at - 2] in "._-~$"))


def follows_home(text, words, i):
    """Whether the path words before words[i] spell the user's home directory: a word
    names_home() accepts, /root, or /home/<user>, /Users/<user> and C:\\Users\\<user>."""
    if i >= 1:
        at, before = words[i - 1]
        if names_home(before) or (before == "root" and starts_absolute(text, at)):
            return True
    return i >= 2 and words[i - 2][1] in ("home", "Users") and starts_absolute(text, words[i - 2][0])


def checkout_path_at(line, pack_names):
    """Offset in normalised(line) where it names a checkout path through the user's home
    directory, or None.

    Claude Code's user directory is `.claude` under the home directory, or what a word
    ending in CLAUDE_CONFIG_DIR names. It counts when the next path word is a stack name,
    or skills and then a pack skill's name, a whole <placeholder> or a $variable, any of
    which can name a pack skill. hov-stack under the home directory is the checkout itself.
    Words are compared whole, so ~/.claude/lib.md, ~/.claude/skills/verify-review.md and
    a skill outside the pack pass. `*` is a separator, so a glob such as ~/.claude/skills/*
    passes because no pack skill's name follows it.

    Out of reach: a directory carried through a variable set earlier (`CC=~/.claude;
    $CC/scripts`), a command substitution, a format string (`"%s/.claude/scripts" % home`),
    a shell escape inside a name (`.c\\laude`), and `..` hops. Prose that sets a home word, `.claude` and a stack name apart with spaces
    (`about ~ .claude hooks`), or a bare CLAUDE_CONFIG_DIR before a stack name, still counts.
    """
    text = normalised(line)
    words = path_words(text)
    names = [word for _, word in words]
    for i, (at, word) in enumerate(words):
        after = names[i + 1:i + 3]
        if word == "hov-stack" and follows_home(text, words, i):
            return words[i - 1][0]
        if (word == ".claude" and follows_home(text, words, i)) or word.endswith("CLAUDE_CONFIG_DIR"):
            if after[:1] and after[0] in STACK:
                return at
            if after[:1] == ["skills"] and len(after) == 2:
                name = after[1]
                if (
                    name in pack_names
                    or (name.startswith("$") and len(name) > 1)
                    or (name.startswith("<") and name.endswith(">"))
                ):
                    return at
    return None


def reaches_the_checkout(line, pack_names):
    return checkout_path_at(line, pack_names) is not None


def checkout_references(pack):
    """(skill name, "path:line: text") for every line a pack skill loads that reaches the checkout."""
    names = {p.name for p in pack.iterdir() if p.is_dir()}
    hits = []
    for skill in sorted(p for p in pack.iterdir() if p.is_dir()):
        for directory, subdirs, files in os.walk(skill):
            subdirs[:] = sorted(d for d in subdirs if d != "node_modules")
            for name in sorted(files):
                path = Path(directory) / name
                if path.parent == skill and (name in UNLOADED or LICENCE_FILE.match(name)):
                    continue
                text = path.read_bytes().decode("utf-8", errors="replace")
                for number, line in enumerate(text.splitlines(), 1):
                    at = checkout_path_at(line, names)
                    if at is not None:
                        # Quote the file's own text around the match: on a long line the
                        # start may not reach it. normalised() only drops characters, so
                        # the match sits between at and at + dropped in the line as written.
                        dropped = len(line) - len(normalised(line))
                        cut = max(0, at - 40)
                        quote = ("…" if cut else "") + line[cut:at + 100 + dropped].strip()
                        hits.append((skill.name, f"{path.relative_to(pack)}:{number}: {quote}"))
    return hits


class SkillPackTests(unittest.TestCase):
    def test_manifest_names_the_pack_and_agrees_with_the_version_file(self):
        manifest = json.loads((PLUGIN / ".claude-plugin" / "plugin.json").read_text())
        version = (PLUGIN / "VERSION").read_text().strip()
        self.assertEqual(manifest["name"], "hov-stack")
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")
        self.assertEqual(manifest["version"], version)
        self.assertEqual(manifest["license"], "MIT")

    def test_licence_copy_is_the_root_licence(self):
        self.assertEqual(
            (PLUGIN / "LICENSE").read_bytes(), (CLAUDE / "LICENSE").read_bytes()
        )

    def test_every_pack_entry_is_a_skill_reachable_from_the_root_path(self):
        entries = sorted((PLUGIN / "skills").iterdir())
        self.assertGreater(len(entries), 0)
        for entry in entries:
            with self.subTest(entry=entry.name):
                self.assertTrue(entry.is_dir(), "not a directory")
                self.assertTrue((entry / "SKILL.md").is_file(), "no SKILL.md")
                self.assertRegex(entry.name, SKILL_NAME)
                self.assertTrue(
                    (CLAUDE / "skills" / entry.name / "SKILL.md").is_file(),
                    "skills/<name>/SKILL.md does not resolve",
                )

    def test_root_skills_link_resolves_into_the_pack(self):
        link = CLAUDE / "skills"
        self.assertTrue(link.is_symlink(), "root skills is not a symlink")
        self.assertEqual(os.readlink(link), "plugins/hov-stack/skills")
        self.assertEqual(link.resolve(), (PLUGIN / "skills").resolve())

    def test_skill_name_pattern_rejects_a_planted_bad_name(self):
        # SKILL_NAME is the guard above; prove it refuses what it should.
        for bad in ("Verify", "-lead", "has space", "dot.ted"):
            with self.subTest(name=bad):
                self.assertIsNone(SKILL_NAME.match(bad))

    def test_every_skill_carries_a_licence_file(self):
        for skill in skills():
            with self.subTest(skill=skill.name):
                self.assertTrue(
                    licence_files(skill),
                    "no LICENSE, LICENSE-*, LICENSE.md, LICENSE.txt or COPYING "
                    "(an UPSTREAM.md alone is not a licence)",
                )

    def test_a_skill_without_a_notice_row_carries_the_root_licence(self):
        rows = notice_rows()
        for skill in skills():
            if skill.name in rows:
                continue
            with self.subTest(skill=skill.name):
                self.assertTrue((skill / "LICENSE").is_file(), "no LICENSE")
                self.assertEqual(
                    (skill / "LICENSE").read_bytes(),
                    (CLAUDE / "LICENSE").read_bytes(),
                    "LICENSE differs from the root LICENSE: re-copy from the root LICENSE, "
                    "or, for third-party text, add its row to plugins/hov-stack/NOTICE.md",
                )

    def test_every_notice_table_line_is_the_header_or_a_readable_row(self):
        # notice_rows() reads only the lines NOTICE_ROW matches; a row it cannot read
        # would drop out of every cross-check below without a word.
        unread = [l for l in notice_table_lines() if l not in NOTICE_HEAD and not NOTICE_ROW.match(l)]
        self.assertEqual(unread, [], "NOTICE.md table lines not of the form | `skill` | source | licence | holder |")

    def test_notice_has_one_row_per_skill_whose_licence_differs(self):
        rows = notice_rows()
        third_party = {s.name for s in skills() if third_party_licences(s)}
        existing = {s.name for s in skills()}
        self.assertEqual(sorted(n for n, r in rows.items() if len(r) > 1), [], "duplicate rows")
        self.assertEqual(sorted(set(rows) - existing), [], "rows naming no skill directory")
        self.assertEqual(
            sorted((set(rows) & existing) - third_party), [],
            "rows naming a skill whose only licence is the root LICENSE",
        )
        self.assertEqual(
            sorted(third_party - set(rows)), [],
            "skills with a third-party licence file but no NOTICE row",
        )

    def test_each_notice_row_names_every_licence_its_files_contain(self):
        rows = notice_rows()
        for skill in skills():
            files = third_party_licences(skill)
            if not files or skill.name not in rows:
                continue  # the row-set test above names these
            with self.subTest(skill=skill.name):
                found = set()
                for path in files:
                    ids = detected_licences(path.read_text())
                    self.assertTrue(ids, f"{path.name}: licence text not recognised")
                    found |= ids
                expression = rows[skill.name][0][1]
                named = set(re.findall(r"[A-Za-z0-9.-]+", expression)) - {"AND", "OR", "WITH"}
                self.assertEqual(sorted(named), sorted(found), f"NOTICE says {expression!r}")

    def test_licence_detection_reads_past_the_first_line(self):
        # detected_licences is the guard above; prove it reads a body, not a title.
        mit = "\nMIT License\n\nCopyright (c) 2026 A\n\nPermission is hereby granted, free of charge, to any person obtaining\na copy of this software\n"
        self.assertEqual(detected_licences(mit), {"MIT"})
        self.assertEqual(detected_licences("\n\n  Apache License\n  Version 2.0, January 2004\n"), {"Apache-2.0"})
        self.assertEqual(detected_licences("MIT License\n\nCopyright (c) 2026 A\n"), set())

    def test_no_pack_skill_reaches_the_checkout_through_a_home_path(self):
        hits = checkout_references(PLUGIN / "skills")
        self.assertEqual(
            sorted(h for _, h in hits), [],
            "reaches the checkout through a home path, which a plugin install does not have: "
            "anchor on the skill's own directory instead, or, for a skill that runs a stack "
            "script, move it to skills-stack/ (#47). A <placeholder> or $variable under "
            "skills/ counts, because it can name a pack skill",
        )

    def test_every_stack_skill_reaches_the_checkout(self):
        names = {p.name for p in stack_skills()}
        self.assertGreater(len(names), 0, "skills-stack/ is empty: remove it and its setup link")
        reaching = {s for s, _ in checkout_references(STACK_SKILLS)}
        self.assertEqual(
            sorted(names - reaching), [],
            "runs nothing a plugin install lacks, so it belongs in the pack, not skills-stack/",
        )

    def test_every_stack_skill_is_a_skill_apart_from_the_pack_under_the_root_licence(self):
        pack = {p.name for p in skills()}
        root = (CLAUDE / "LICENSE").read_bytes()
        for entry in stack_skills():
            with self.subTest(entry=entry.name):
                self.assertTrue(entry.is_dir(), "not a directory")
                self.assertTrue((entry / "SKILL.md").is_file(), "no SKILL.md")
                self.assertRegex(entry.name, SKILL_NAME)
                self.assertNotIn(entry.name, pack, "a pack skill has this name; setup links both to one path")
                self.assertEqual(
                    [p.read_bytes() == root for p in licence_files(entry)], [True],
                    "carries exactly one licence file, the root LICENSE (no NOTICE row covers skills-stack/)",
                )

    def test_checkout_path_matcher_flags_planted_lines(self):
        # reaches_the_checkout is the guard above; prove it flags what it should and no more.
        names = {"design-drift", "verify-review"}
        for line in (
            "python3 ~/.claude/scripts/x.py",
            'bash "$HOME/.claude/hooks/x.sh"',
            "${HOME}/.claude/bin/tool",
            "see ~/.claude/lib/link.sh",
            ". ~/.claude/claude-env.sh",
            "node ~/.claude/skills/design-drift/src/scan.mjs <repo>",
            "read `~/.claude/skills/<name>/SKILL.md`",
            "docs in `~/hov-stack/harness/`",
            "ok ~/.claude/skills/somebody-else/ then python3 ~/.claude/skills/verify-review/x.py",
            'bash "$HOME"/.claude/scripts/x.sh',
            'bash "$HOME/.claude"/scripts/x.sh',
            "bash '~/.claude/scripts/x.sh'",
            "bash $CLAUDE_CONFIG_DIR/scripts/x.sh",
            'node "${CLAUDE_CONFIG_DIR}/hooks/x.js"',
            'bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/x.sh"',
            "~/.claude//scripts/x.sh",
            "~/./.claude/hooks/x.sh",
            "~/.claude/./bin/tool",
            "ls ~/.claude/scripts",
            "the hooks in `~/.claude/hooks`.",
            "clone into ~/hov-stack",
            "~/.claude/mods/lookout/README.md",
            "~/.claude/skills/$name/SKILL.md",
            "~/.claude/skills/{design-drift,verify-review}/SKILL.md",
            "$CLAUDE_CONFIG_DIR/skills/design-drift/src/scan.mjs",
            'join(homedir(), ".claude", "scripts", "x.py")',
            'Path.home() / ".claude" / "hooks" / "x.sh"',
            'process.env.HOME + "/.claude/scripts/x.sh"',
            'os.environ["HOME"] + "/.claude/bin/x"',
            "const p = `${os.homedir()}/.claude/lib/x.sh`",
            'resolve(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "scripts")',
            'join(homedir(), "hov-stack", "harness")',
            "cd ~/.claude && ./scripts/x.sh",
            "ls ~/.claude/{scripts,hooks}/",
            "/home/<user>/.claude/scripts/x.sh",
            "/Users/<user>/.claude/hooks/x.sh",
            "~u/.claude/scripts/x.sh",
            'export PATH="$HOME/.claude/bin:$PATH"',
            "PATH=$PATH:~/.claude/bin",
            "bash ${CLAUDE_CONFIG_DIR:-~/.claude}/scripts/x.sh",
            "see **~/.claude/hooks/x.sh**",
            "@~/.claude/scripts/x.md",
            r"%USERPROFILE%\.claude\scripts\x.bat",
            r"$env:USERPROFILE\.claude\scripts\x.ps1",
            r"C:\Users\<user>\.claude\hooks\x.ps1",
            "/root/.claude/scripts/x.sh",
            "ls ~/.claude/scripts>out",
            "see ‘~/.claude/scripts/x.sh’",
            'f"{Path.home()}/.claude/scripts/x.py"',
        ):
            with self.subTest(line=line):
                self.assertTrue(reaches_the_checkout(line, names))
        for line in (
            "~/.claude/skills/e2e-testing-for-webapps/SKILL.md",
            "~/.claude/skills/design-drift-extra/SKILL.md",
            '`<checkout>/harness/cc-mcp-architecture.md`',
            'SKILL_DIR="<skill-dir>"; node "$SKILL_DIR/src/scan.mjs"',
            "~/.claude/settings.json and ~/.claude/projects/",
            "the user's ~/.claude/CLAUDE.md and ~/.claude/agents/x.md",
            "$CLAUDE_CONFIG_DIR/CLAUDE.md",
            "~/.claude/scripts-archive/x.sh and ~/.claude/binaries/",
            "~/hov-stack-notes/todo.md",
            "skills go in ~/.claude/skills",
            "https://example.com//scripts/x.sh",
            "~/.claude/lib.md and ~/.claude/hooks.json",
            "~/.claude/skills/verify-review.md",
            "~/.claude/skills/<brand>-brand-voice/SKILL.md",
            "your own skills in ~/.claude/skills/*",
            "https://x.com/a~/hov-stack and ~/hov-stack.md",
            "your project's .claude/hooks/x.sh",
            "[project]/.claude/skills/design-drift/SKILL.md",
            'resolve(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "CLAUDE.md")',
            "JAVA_HOME/.claude/scripts and $REPO_HOME/.claude/hooks/x.sh",
            "dotfiles/home/<user>/.claude/hooks/x.sh",
            "https://github.com/Users/<user>/.claude/hooks",
            "the repo root/.claude/scripts/x.sh",
        ):
            with self.subTest(line=line):
                self.assertFalse(reaches_the_checkout(line, names))

    def test_root_notice_links_the_pack_notice_and_names_only_real_paths(self):
        text = (CLAUDE / "NOTICE.md").read_text()
        links = re.findall(r"\]\(([^)\s]+)\)", text)
        self.assertIn("plugins/hov-stack/NOTICE.md", links)
        paths = [p for p in links if not p.startswith("http")]
        paths += [p for p in re.findall(r"`([^`\s]+)`", text) if "/" in p]
        for path in paths:
            with self.subTest(path=path):
                self.assertTrue((CLAUDE / path).exists(), "listed in NOTICE.md but absent")


if __name__ == "__main__":
    unittest.main()
