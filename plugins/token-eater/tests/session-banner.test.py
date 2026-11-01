#!/usr/bin/env python3
"""Exercise actual PR-body assembly with inert git/gh stubs, never a provider.

Optionally pass a baseline repository to compare byte-for-byte outputs and argv.
Only the publication section is evaluated, so no credentials, worktrees, service,
network or repository commands are used. Unexpected stub calls fail closed.
"""
import itertools
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BANNER = (
    '> [!WARNING]\n'
    '> **This project has no automated tests/typecheck, so token-eater could not '
    'machine-verify this change.** An AI review ran, but nothing here proves it '
    'was thorough. **Read the diff carefully before merging.**'
)
STUBS = r'''
set -euo pipefail
git() {
  case "$*" in
    *"--format=%s"*) printf '%s\n' 'Refactor a shared helper' ;;
    *"--format=- "*) printf '%s\n' '- `abc123` Refactor a shared helper' ;;
    *" push "*) : ;;
    *) echo "unexpected git call: $*" >&2; exit 99 ;;
  esac
}
gh() {
  case "$1 $2" in
    'pr list') [ "$EXISTING" = 0 ] || printf '%s\n' 'https://example.invalid/pr/1' ;;
    'pr view') [ "$EXISTING" != failed ] || return 1; cat "$CURRENT" ;;
    'pr create'|'pr edit')
      printf '%s\0' "$@" > "$LOG/args"
      [ "$2" != create ] || printf '%s\n' 'https://example.invalid/pr/1'
      ;;
    *) echo "unexpected gh call: $*" >&2; exit 99 ;;
  esac
}
'''


def exercise(root, tier, existing, narrative, current):
    source = (root / 'skills/token-eater/scripts/run-session.sh').read_text()
    start = source.index('# Assemble the PR body.')
    end = source.index('# Best-effort spend line', start)
    with tempfile.TemporaryDirectory(prefix='session-banner-') as folder:
        path = Path(folder)
        (path / 'narrative').write_bytes(narrative)
        (path / 'current').write_bytes(current)
        env = dict(os.environ, LOG=folder, WORKTREE=folder, BASE='main',
                   SKILL='dry', SERVICE='stub', GATE='test --all',
                   GATE_TIER=tier, ROUNDS='2', BRANCH='test-branch',
                   ORIGIN_SLUG='fixture/repo', SERVICE_PR_BODY=str(path/'narrative'),
                   CURRENT=str(path/'current'), EXISTING=existing)
        result = subprocess.run(['bash', '-c', STUBS + source[start:end] + '\n:'],
                                env=env, capture_output=True, check=True)
        body = (path / 'pr-body.md').read_bytes()
        args_path = path / 'args'
        args = args_path.read_bytes() if args_path.exists() else b''
        # Normalize temp paths only; preserve all body bytes and argument boundaries.
        return body, args.replace(folder.encode(), b'<tmp>'), result.stdout


def main():
    baseline = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
    cases = itertools.product(
        ['soft', 'explicit', 'detected'], ['0', '1', 'failed'],
        [b'', b'Human narrative\n', b'quotes " $ ` % \\ and Unicode: \xe2\x9c\x93\n\n'],
        [b'', b'Human-edited body\n\n', b'could not machine-verify this change', (BANNER + '\n\nExisting narrative').encode()])
    count = 0
    for tier, existing, narrative, current in cases:
        actual = exercise(ROOT, tier, existing, narrative, current)
        body, args, _ = actual
        if tier == 'soft':
            assert body.startswith((BANNER + '\n\n').encode())
        else:
            assert BANNER.encode() not in body
        if existing == '0':
            assert args.startswith(b'pr\0create\0') and b'--draft\0' in args
        elif tier != 'soft' or (existing != 'failed' and b'could not machine-verify this change' in current):
            assert args == b''
        else:
            expected_current = b'' if existing == 'failed' else current.rstrip(b'\n')
            expected = (BANNER + '\n\n').encode() + expected_current
            assert args.endswith(b'--body\0' + expected + b'\0')
        if narrative:
            assert narrative + b'\n---\n' in body
        if baseline:
            assert actual == exercise(baseline, tier, existing, narrative, current), (
                tier, existing, narrative, current)
        count += 1
    print(f'PASS: {count} session banner cases' + (' with exact baseline parity' if baseline else ''))


if __name__ == '__main__':
    main()
