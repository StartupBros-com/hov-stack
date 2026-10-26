#!/usr/bin/env python3
"""Re-vendor kill-ai-slop from upstream at a pinned commit, re-applying the local changes.
Usage: repin-kill-ai-slop.py <commit-sha>   (run from anywhere; writes plugins/hov-stack/skills/kill-ai-slop)
Fetches every blob under skill/ plus the repo LICENSE via the GitHub contents API, writes them
into the skill directory, re-applies the two frontmatter changes UPSTREAM.md lists (the
modification-notice comment as the first line, `disable-model-invocation: true`), and prints a
summary. UPSTREAM.md is left for a human edit (it records the pin, date, and the change list)."""
import base64, hashlib, json, os, subprocess, sys

SKILL_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         'plugins', 'hov-stack', 'skills', 'kill-ai-slop')
REPO = 'yetone/kill-ai-slop'
# Apache-2.0 section 4(b): a modified file carries a notice that it was changed.
NOTICE = '# Modified from yetone/kill-ai-slop skill/SKILL.md (Apache-2.0); the changes are listed in UPSTREAM.md.'
POSTURE = 'disable-model-invocation: true'


def apply_local_changes(text):
    """SKILL.md text with the notice as the first frontmatter line and the on-demand posture
    as the last; either already present is left as is."""
    head, fm, rest = text.split('---', 2)
    lines = fm.strip('\n').split('\n')
    if NOTICE not in lines:
        lines.insert(0, NOTICE)
    if POSTURE not in lines:
        lines.append(POSTURE)
    return head + '---\n' + '\n'.join(lines) + '\n---' + rest


def api(path, jq=None):
    cmd = ['gh', 'api', '--method', 'GET', path] + (['--jq', jq] if jq else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'gh api failed for {path}: {(r.stderr or r.stdout)[:200]}')
    return r.stdout


def main(sha):
    tree = json.loads(api(f'repos/{REPO}/git/trees/{sha}?recursive=1'))
    blobs = [t for t in tree['tree'] if t['type'] == 'blob' and (t['path'].startswith('skill/') or t['path'] == 'LICENSE')]
    written = []
    for t in blobs:
        content = api(f'repos/{REPO}/contents/{t["path"]}?ref={sha}', '.content')
        data = base64.b64decode(content)
        rel = t['path'][len('skill/'):] if t['path'].startswith('skill/') else t['path']
        dest = os.path.join(SKILL_DIR, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        old = open(dest, 'rb').read() if os.path.exists(dest) else None
        with open(dest, 'wb') as f:
            f.write(data)
        written.append((rel, len(data), 'new' if old is None else ('changed' if old != data else 'same'), hashlib.sha256(data).hexdigest()[:12]))

    skill = os.path.join(SKILL_DIR, 'SKILL.md')
    text = open(skill, encoding='utf-8').read()
    local = apply_local_changes(text)
    if local != text:
        open(skill, 'w', encoding='utf-8').write(local)
        written.append(('SKILL.md', len(local), 'local-changes-applied', ''))
    else:
        written.append(('SKILL.md', len(local), 'local-changes-already-present', ''))
    for w in written:
        print(f'{w[2]:30} {w[1]:7d}  {w[0]}  {w[3]}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: repin-kill-ai-slop.py <commit-sha>')
    main(sys.argv[1])
