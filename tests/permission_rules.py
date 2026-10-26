"""Shared settings-test helper: Claude Code's documented Bash permission-rule semantics."""
import re


def decide(command, permissions):
    """deny, ask, allow or prompt for one simple command under the documented rule semantics.

    Bash(prefix:*) is a prefix match and every other * matches any text; deny
    beats ask beats allow. This emulates the rules, it is not Claude Code's
    matcher: the PR's live claude -p probe is the evidence for that.
    """
    def matches(rule):
        if not (rule.startswith("Bash(") and rule.endswith(")")):
            return False
        body = rule[5:-1]
        if body.endswith(":*"):
            prefix = body[:-2]
            return command == prefix or command.startswith(prefix + " ")
        return re.fullmatch("".join(".*" if ch == "*" else re.escape(ch) for ch in body), command, re.S) is not None

    for kind in ("deny", "ask", "allow"):
        if any(matches(rule) for rule in permissions.get(kind, [])):
            return kind
    return "prompt"
