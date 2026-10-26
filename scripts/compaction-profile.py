#!/usr/bin/env python3
"""Compaction profile for long Claude Code sessions.

Usage: compaction-profile.py [-h|--help] [DAYS] [MIN_REQUESTS]   (defaults: 14 days, sessions with >=1000 assistant requests)
Event-time census (JSON, main + subagents, no request floor or credential reads):
  compaction-profile.py --since ISO_TIME --until ISO_TIME [--split-at ISO_TIME ...]
Times require an explicit timezone. Each split makes half-open event cohorts for #1591;
all-session and requested-model/kind strata include denominators and unknown countermetrics.
Env: CLAUDE_PROJECTS_ROOT overrides the transcript root (default ~/.claude/projects); used by the test.

Reads ~/.claude/projects/*/*.jsonl (main sessions only) and reports: where auto-compaction fires (context before),
where it lands (context after), compactions per session, the context histogram, and how many >20k-token cache
re-writes are compaction-adjacent vs unexplained. Consumer: the autoCompactWindow decision (dotfiles PR #1255
follow-up, 2026-09-20). Re-run after changing the window to compare the "ctx BEFORE compaction" line and the
histogram; delete this script once the window is settled and the check has moved into harness-weekly or nowhere.
Baseline 2026-09-20 (window = CC default ~967k): before median 901k / p90 999k, after median 79k, 13.5% of
long-session requests above 800k, histogram flat ~12% per 100k band from 100k to 800k.
Re-baselined 2026-09-22 after #1313 (requests counted once per message.id; the 2026-09-20 line above counted records,
2.45x requests, so its "1000 requests" floor was ~410 real requests): same corpus and day, unpatched vs patched:
long sessions 83 vs 34, requests 253,384 vs 73,429; before-compaction median 577,997 vs 480,121,
after median 78,113; above 800k 11.6% vs 12.3%; compactions per long session median 2 vs 4.
A request's context is its last `type:"message"` usage iteration when `usage.iterations` is present (#1544): a
response that ran a server-side tool such as the advisor sums its top-level usage over its main-model message
iterations, each of which re-reads the same context.
Floor composition (A): for each automatic boundary (compact_boundary with compactMetadata.trigger == "auto") in a long
session, floor = context of the first request after the boundary, prefix = that session's own first assistant request,
summary = chars/4 (ESTIMATE) of the user message that begins "This session is being continued from a previous
conversation", tail = floor - prefix - summary (derived; negative values are kept). Boundaries with no such message
report "summary: n/a" and are left out of the summary and tail rows. Caveat: a resumed or background session's first
request can already carry earlier context, so its "prefix" overstates the fixed prefix; the alt row re-derives the tail
from the window's median first-request context across all main sessions.
Steered vs unsteered (B): hooks/PreCompact/compact-preserve.js writes its preserve list to the compaction request, not
to the transcript. In 1,595 boundaries (600 newest session files, 2026-10-12) no record within -6..+2 of a boundary holds
the list, and compactMetadata carries only trigger, token counts and preserved ids, so the status is not recoverable.
Prefix composition (C): ESTIMATES from files on this host against the measured median first-request context.
"""
import json, os, glob, time, collections, sys, math, re
if any(a in ('-h', '--help') for a in sys.argv[1:]):
    print(__doc__.strip()); sys.exit(0)
root = os.environ.get('CLAUDE_PROJECTS_ROOT') or os.path.expanduser('~/.claude/projects')
def pct(xs, p):
    if not xs: return 0
    xs = sorted(xs); return xs[int(round((len(xs) - 1) * p))]
COUNTERS = ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens')
def input_sum(u):
    return (u.get('input_tokens') or 0) + (u.get('cache_creation_input_tokens') or 0) + (u.get('cache_read_input_tokens') or 0)
def counted(v): return type(v) in (int, float) and math.isfinite(v) and v >= 0
def ctx_of(u):  # an incomplete last message iteration would read low, so the top-level sum stands in for it
    its = u.get('iterations')
    msgs = [i for i in its if isinstance(i, dict) and i.get('type') == 'message'] if isinstance(its, list) else []
    last = msgs[-1] if msgs and all(counted(msgs[-1].get(k)) for k in COUNTERS) else None
    return (input_sum(last) if last else 0) or input_sum(u)
events = []  # (ctx_before, ctx_after, turn_idx, turns_total)
SUMMARY_PREFIX = 'This session is being continued from a previous conversation'
floors = []  # automatic boundaries: dict(prefix, floor, summary_chars or None)
firsts = []  # first-request context of every main session in the window
def text_of(c):
    if isinstance(c, str): return c
    if isinstance(c, list): return ''.join(b.get('text', '') for b in c if isinstance(b, dict) and isinstance(b.get('text'), str))
    return ''
def trigger_of(md):
    if isinstance(md, str):
        try: md = json.loads(md)
        except Exception: return None
    return md.get('trigger') if isinstance(md, dict) else None
def event_cohorts(argv):
    """Event-time census for #1591, separate from the historical floor report.

    No request-count floor, mtime selection, settings or credential-store reads.
    Sessions may occur in multiple cohorts; dates are active UTC dates, not wall
    duration. A boundary inherits only the preceding request's recorded identity.
    Response model is recorded separately, never treated as a verified upstream.
    """
    import argparse
    import datetime as dt
    import statistics
    import sqlite3
    import tempfile

    started = time.monotonic()
    scratch = tempfile.TemporaryDirectory(prefix='compaction-cohorts-')
    db = sqlite3.connect(os.path.join(scratch.name, 'events.sqlite'))
    # Bound the page cache; keep raw transcript content out of the scratch store.
    db.execute('PRAGMA cache_size = -8192')
    db.execute('CREATE TABLE events (cohort INTEGER, kind TEXT, model_class TEXT, data TEXT)')
    db.execute('CREATE TABLE activity (key TEXT PRIMARY KEY, sid TEXT, stamp TEXT, data TEXT) WITHOUT ROWID')

    def retain(key, item, when):
        key = json.dumps(key)
        stamp = when.isoformat(timespec='microseconds')
        data = json.dumps(item, sort_keys=True)
        inserted = db.execute('INSERT OR IGNORE INTO activity VALUES (?, ?, ?, ?)',
                              (key, item['sid'], stamp, data)).rowcount
        if not inserted:
            # A streamed/relocated copy can have a later timestamp for the same
            # message. Earliest observation owns the cohort; ties are stable.
            db.execute('UPDATE activity SET stamp = ?, data = ? WHERE key = ? '
                       'AND (stamp > ? OR (stamp = ? AND data > ?))',
                       (stamp, data, key, stamp, stamp, data))
        return not inserted

    def timestamp(value):
        if not isinstance(value, str):
            return None
        try:
            value = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
            return value.astimezone(dt.timezone.utc) if value.tzinfo else None
        except ValueError:
            return None

    def argument_time(value):
        result = timestamp(value)
        if result is None:
            raise argparse.ArgumentTypeError('expected ISO timestamp with explicit timezone')
        return result

    parser = argparse.ArgumentParser(description=event_cohorts.__doc__)
    parser.add_argument('--since', required=True, type=argument_time)
    parser.add_argument('--until', required=True, type=argument_time)
    parser.add_argument('--split-at', action='append', default=[], type=argument_time)
    args = parser.parse_args(argv)
    cuts = [args.since, *sorted(set(args.split_at)), args.until]
    if any(a >= b for a, b in zip(cuts, cuts[1:])):
        parser.error('split points must be distinct and strictly inside since/until')
    named = {'claude-fable-5-1', 'claude-opus-5-5', 'claude-sonnet-5-5', 'claude-sonnet-5'}
    groups_seen = [set() for _ in cuts[:-1]]
    quality = collections.Counter()
    read_errors = collections.Counter()
    paths = sorted(glob.glob(root + '/*/*.jsonl') + glob.glob(root + '/*/*/subagents/*.jsonl'))
    for path in paths:
        subagent = '/subagents/' in path
        quality['files_scanned'] += 1
        try:
            fh = open(path, errors='replace')
        except OSError as exc:
            quality['unreadable_files'] += 1
            read_errors[(type(exc).__name__, exc.errno)] += 1
            continue
        with fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    quality['invalid_json_records'] += 1
                    continue
                if not isinstance(e, dict):
                    quality['non_object_records'] += 1
                    continue
                typ = e.get('type')
                boundary = e.get('subtype') == 'compact_boundary'
                if typ not in ('assistant', 'user') and not boundary:
                    continue
                when = timestamp(e.get('timestamp'))
                if when is None:
                    quality['untimed_activity_records'] += 1
                    continue
                if when >= args.until:
                    continue  # Do not break: relocated/appended records need not be time ordered.
                message = e.get('message') or {}
                usage = message.get('usage') or {}
                ci = ctx_of(usage) if typ == 'assistant' else 0
                if typ == 'assistant' and not ci and not e.get('interruptedMessageId'):
                    continue
                sid = e.get('sessionId') or os.path.basename(path)
                if subagent:
                    sid = str(sid) + '/' + os.path.basename(path)
                eid = message.get('id') if typ == 'assistant' else e.get('uuid')
                key = (sid, typ, eid or e.get('timestamp'), e.get('subtype'))
                md = e.get('compactMetadata') or {}
                if isinstance(md, str):
                    try:
                        md = json.loads(md)
                    except ValueError:
                        md = {}
                if not isinstance(md, dict):
                    md = {}
                text = text_of(message.get('content')) if typ == 'user' else ''
                item = {'sid': sid, 'day': when.date().isoformat(), 'context': ci,
                        'identity': [e.get('requestedModel'), message.get('model'), e.get('entrypoint'), e.get('sessionKind')],
                        'subagent': bool(subagent or e.get('isSidechain')), 'boundary': boundary,
                        'auto': boundary and md.get('trigger') == 'auto',
                        'manual': boundary and md.get('trigger') == 'manual',
                        'pre': md.get('preTokens') if boundary and counted(md.get('preTokens')) else None,
                        'post': md.get('postTokens') if boundary and counted(md.get('postTokens')) else None,
                        'next_context': None,
                        'typed': typ == 'user' and not e.get('isMeta') and not e.get('isCompactSummary') and
                                 text.lstrip().startswith('<command-name>/compact</command-name>'),
                        'interrupted': None}
                duplicate = False
                if typ != 'assistant' or ci:
                    duplicate = retain(key, item, when)
                if e.get('interruptedMessageId'):
                    # An interruption is a countermetric, not proof of a request
                    # with measured context. Preserve it even on a duplicate.
                    interruption = {**item, 'context': 0, 'boundary': False,
                                    'auto': False, 'manual': False, 'typed': False,
                                    'pre': None, 'post': None,
                                    'interrupted': e['interruptedMessageId']}
                    duplicate = retain((sid, 'interruption', e['interruptedMessageId']),
                                       interruption, when) or duplicate
                quality['duplicate_activity_records'] += duplicate
        db.commit()

    # File order is not session order: relocated copies may share only a prefix.
    # Deduplicate first, then carry adjacency/identity across the complete session.
    db.execute('CREATE INDEX activity_order ON activity (sid, stamp)')
    previous_sid = previous = None
    pending = []
    for sid, stamp, data in db.execute('SELECT sid, stamp, data FROM activity ORDER BY sid, stamp, key'):
        item = json.loads(data)
        when = timestamp(stamp)
        if sid != previous_sid:
            previous_sid, previous, pending = sid, None, []
        identity = item.pop('identity')
        boundary = item.pop('boundary')
        subagent = item.pop('subagent')
        if item['context']:
            for rowid, prior in pending:
                prior['next_context'] = item['context']
                db.execute('UPDATE events SET data = ? WHERE rowid = ?', (json.dumps(prior), rowid))
            pending = []
            previous = identity
        requested, response, entry, session_kind = previous or (None, None, identity[2], identity[3])
        item.update(requested=requested, response=response)
        kind = 'subagent' if subagent else (
            'background' if session_kind == 'bg' else 'sdk-cli' if entry == 'sdk-cli' else 'main-unknown')
        model_class = 'named' if requested in named else 'other' if requested else 'unknown'
        if boundary:
            pending = []  # A second compaction censors the first one's next context.
        if when < args.since:
            continue
        for i, (start, end) in enumerate(zip(cuts, cuts[1:])):
            if start <= when < end:
                row = db.execute('INSERT INTO events VALUES (?, ?, ?, ?)', (i, kind, model_class, json.dumps(item)))
                groups_seen[i].add((kind, model_class))
                if boundary:
                    pending = [(row.lastrowid, item)]
                break
    db.commit()

    def median(values):
        values = [v for v in values if v is not None]
        return statistics.median(values) if values else None

    def summarize(items):
        sessions, days, eligible, interrupted, requested, response = (set() for _ in range(6))
        auto = []  # Only boundary observations are retained for exact medians.
        requests = typed = manual = above800 = 0
        for r in items:
            sessions.add(r['sid'])
            days.add((r['sid'], r['day']))
            if r['context'] >= 300000 or (r['pre'] or 0) >= 300000:
                eligible.add(r['sid'])
            if r['auto']:
                auto.append(r)
            if r['interrupted']:
                interrupted.add((r['sid'], r['interrupted']))
            if r['requested']:
                requested.add(r['requested'])
            if r['response']:
                response.add(r['response'])
            requests += bool(r['context'])
            typed += r['typed']
            manual += r['manual']
            above800 += r['context'] > 800000
        eligible_auto = [r for r in auto if r['sid'] in eligible]
        return {'sessions': len(sessions), 'active_session_days_utc': len(days),
                'sessions_reaching_300k': len(eligible), 'requests': requests,
                'interrupted_messages': len(interrupted),
                'compaction_caused_interruptions': None, 'loop_fence_stops': None, 'loop_handoff_rotations': None,
                'automatic_boundaries': len(auto), 'automatic_in_eligible_sessions': len(eligible_auto),
                'automatic_per_eligible_session': len(eligible_auto) / len(eligible) if eligible else None,
                'eligible_sessions_with_auto': len({r['sid'] for r in eligible_auto}),
                'automatic_pre_tokens_median': median(r['pre'] for r in auto),
                'automatic_pre_tokens_n': sum(r['pre'] is not None for r in auto),
                'automatic_pre_tokens_below_300k': sum(r['pre'] is not None and r['pre'] < 300000 for r in auto),
                'automatic_post_tokens_median': median(r['post'] for r in auto),
                'automatic_next_context_median': median(r['next_context'] for r in auto),
                'automatic_without_next_request': sum(r['next_context'] is None for r in auto),
                'manual_boundaries': manual, 'typed_compact': typed,
                'typed_compact_per_session_day': typed / len(days) if days else None,
                'requests_above_800k': above800,
                'requested_models': sorted(requested),
                'response_models': sorted(response)}

    result = {'definition': 'Half-open event timestamps, distinct message.id per session; active UTC session-days; no minimum requests.',
              'limits': ['Requested identity is requestedModel, not live configuration or runtime inheritance.',
                         'Response message.model is not verified physical routing. Boundaries use preceding request identity.',
                         '300k eligibility also uses native preTokens; auto may fire below 300k, so all-auto totals are retained.',
                         'Background and SDK entrypoints are metadata, not proof of -p flags or environment precedence.',
                         'interruptedMessageId is all-cause; compaction attribution and loop counters require separate operational evidence.',
                         'Retained local transcripts only; missing/unreadable timestamps excluded. No raw text emitted.'],
              'quality': {**quality, 'read_errors': [
                  {'kind': kind, 'errno': number, 'files': count}
                  for (kind, number), count in sorted(read_errors.items())]}, 'cohorts': []}
    def rows(cohort, kind=None, model_class=None, subagents=None):
        query = 'SELECT data FROM events WHERE cohort = ?'
        params = [cohort]
        if kind is not None:
            query += ' AND kind = ? AND model_class = ?'
            params.extend([kind, model_class])
        if subagents is not None:
            query += ' AND kind ' + ('=' if subagents else '!=') + ' ?'
            params.append('subagent')
        return (json.loads(row[0]) for row in db.execute(query, params))

    db.execute('CREATE INDEX event_groups ON events (cohort, kind, model_class)')
    for i, groups in enumerate(groups_seen):
        result['cohorts'].append({'since': cuts[i].isoformat(), 'until': cuts[i + 1].isoformat(),
                                  'all': summarize(rows(i)),
                                  'main': summarize(rows(i, subagents=False)),
                                  'subagents': summarize(rows(i, subagents=True)),
                                  'groups': [{'kind': kind, 'model_class': model_class, **summarize(rows(i, kind, model_class))}
                                             for kind, model_class in sorted(groups)]})
    result['elapsed_seconds'] = round(time.monotonic() - started, 3)
    db.close()
    scratch.cleanup()
    print(json.dumps(result, indent=2))


if '--since' in sys.argv[1:]:
    event_cohorts(sys.argv[1:])
    sys.exit(0)
DAYS = int(sys.argv[1]) if len(sys.argv) > 1 else 14
MIN_REQ = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
cutoff = time.time() - DAYS * 86400
files = [f for f in glob.glob(root + '/*/*.jsonl') if os.path.getmtime(f) > cutoff]
busts_adj = busts_far = 0; long_sessions = 0
ctx_hist = collections.Counter(); above800 = 0; total_req = 0
pre_kinds = collections.Counter(); post_hook = 0
for f in files:
    seq = []  # per assistant request: ctx, cache_create (one entry per message id; records repeat per content block, #1313)
    seen_ids = set()
    binfo = {}  # seq index -> {'trigger':..., 'summary_chars':...}
    marks = []  # indices (in seq) where a compaction marker appeared just before
    kinds = collections.Counter()
    with open(f, errors='replace') as fh:
        for line in fh:
            try: e = json.loads(line)
            except Exception: continue
            t = e.get('type')
            if t == 'summary' or e.get('isCompactSummary') or (isinstance(e.get('subtype'), str) and 'compact' in e['subtype']):
                marks.append(len(seq)); kinds[t if t == 'summary' else ('isCompactSummary' if e.get('isCompactSummary') else e.get('subtype'))] += 1
                bi = binfo.setdefault(len(seq), {})
                if e.get('subtype') == 'compact_boundary': bi['trigger'] = trigger_of(e.get('compactMetadata'))
                if t == 'user':
                    txt = text_of((e.get('message') or {}).get('content'))
                    if txt.lstrip().startswith(SUMMARY_PREFIX): bi['summary_chars'] = len(txt)
                continue
            if t == 'attachment':
                a = e.get('attachment') or {}
                if a.get('hookEvent') in ('PreCompact', 'PostCompact') or 'compact' in str(a.get('type', '')).lower():
                    marks.append(len(seq)); kinds['attachment:' + str(a.get('hookEvent') or a.get('type'))] += 1
                continue
            if t == 'assistant':
                m = e.get('message') or {}; u = m.get('usage') or {}
                mid = m.get('id') or e.get('uuid')
                if mid in seen_ids: continue
                ci = ctx_of(u)
                if ci: seen_ids.add(mid); seq.append((ci, u.get('cache_creation_input_tokens') or 0))
    if seq: firsts.append(seq[0][0])
    if len(seq) < MIN_REQ: continue
    long_sessions += 1; total_req += len(seq)
    for ci, _ in seq:
        ctx_hist[min(ci // 100000, 10)] += 1
        if ci > 800000: above800 += 1
    for k, v in kinds.items(): pre_kinds[k] += v
    mset = set()
    for m in sorted(set(marks)):
        if 0 < m < len(seq):
            events.append((seq[m - 1][0], seq[m][0], m, len(seq))); mset.update(range(m - 2, m + 3))
            bi = binfo.get(m, {})
            if bi.get('trigger') == 'auto': floors.append({'prefix': seq[0][0], 'floor': seq[m][0], 'summary_chars': bi.get('summary_chars')})
    for i, (ci, cc) in enumerate(seq):
        if i and cc > 20000:
            if i in mset: busts_adj += 1
            else: busts_far += 1
print(f'window {DAYS}d; long sessions (>={MIN_REQ} req): {long_sessions}, requests: {total_req}')
print('compaction marker kinds:', dict(pre_kinds))
print(f'compaction events with before/after: {len(events)}')
if events:
    b = [e[0] for e in events]; a = [e[1] for e in events]; drop = [e[0] - e[1] for e in events]
    print(f'  ctx BEFORE compaction: p10={pct(b,.1):,} median={pct(b,.5):,} p90={pct(b,.9):,}')
    print(f'  ctx AFTER  compaction: p10={pct(a,.1):,} median={pct(a,.5):,} p90={pct(a,.9):,}')
    print(f'  drop: median={pct(drop,.5):,}  (after/before median ratio {pct(a,.5)/max(pct(b,.5),1):.2f})')
    per = collections.Counter()
    for e in events: per[e[3]] += 1
    print(f'  compactions per long session: median={pct(list(per.values()),.5)} max={max(per.values())}; sessions with 0 compactions: {long_sessions - len(per)}')
print(f'requests above 800k context: {above800} ({100*above800/max(total_req,1):.1f}%)')
print('context histogram (100k buckets, share of long-session requests):', ', '.join(f'{k*100}k-{(k+1)*100}k={100*v/total_req:.1f}%' for k, v in sorted(ctx_hist.items())))
print(f'cache busts >20k: adjacent to a compaction={busts_adj}, elsewhere={busts_far}')

# --- A: floor composition ---
def row(label, xs, note=''):
    print(f'  {label}: median={pct(xs,.5):,} p90={pct(xs,.9):,} (n={len(xs)}){note}' if xs else f'  {label}: n/a')
print(f'floor composition, automatic boundaries (compactMetadata.trigger=auto) in long sessions: n={len(floors)}')
if floors:
    withsum = [f for f in floors if f['summary_chars'] is not None]
    row('prefix (session first request, measured)', [f['prefix'] for f in floors])
    if withsum:
        sm = [f['summary_chars'] // 4 for f in withsum]
        row('summary (chars/4, ESTIMATE)', sm)
        row('tail (floor - prefix - summary, derived)', [f['floor'] - f['prefix'] - f['summary_chars'] // 4 for f in withsum],
            f'; negative: {sum(1 for f in withsum if f["floor"] - f["prefix"] - f["summary_chars"] // 4 < 0)}')
    else:
        print('  summary: n/a (no summary message follows any automatic boundary)')
        print('  tail: n/a')
    if len(withsum) < len(floors): print(f'  boundaries without a summary message: {len(floors) - len(withsum)} (excluded from summary and tail)')
    row('floor (first request after boundary, measured)', [f['floor'] for f in floors])
    if withsum:
        gm = pct(firsts, .5)
        row(f'tail alt (floor - window median first request {gm:,} - summary, derived)', [f['floor'] - gm - f['summary_chars'] // 4 for f in withsum])

# --- B: steered vs unsteered ---
print('steered/unsteered: not measurable from existing transcripts (the PreCompact preserve list is not recorded in the JSONL, '
      'and compactMetadata holds only trigger, token counts and preserved ids); no logging was added to change that.')

# --- C: prefix composition, estimates ---
def fbytes(p):
    try: return os.path.getsize(os.path.expanduser(p))
    except OSError: return None
def est(label, b, note=''):
    print(f'  {label}: ' + (f'{b // 4:,} tokens (estimate, bytes/4){note}' if b is not None else 'n/a (file not found)'))
    return (b // 4) if b is not None else 0
print('first-request prefix composition (main-session first assistant request)')
med = pct(firsts, .5)
print(f'  measured median first-request context: {med:,} (measured, n={len(firsts)} sessions in window)')
total = 0
total += est('~/.claude/CLAUDE.md', fbytes('~/.claude/CLAUDE.md'))
slug = os.environ.get('COMPACTION_PROFILE_PROJECT_SLUG') or re.sub(r'[^A-Za-z0-9]', '-', os.path.realpath(os.getcwd()))
total += est('project memory index (this checkout)', fbytes(f'~/.claude/projects/{slug}/memory/MEMORY.md'))
def plugin_skill_dirs(cache_root, manifest):
    """Skill dirs of one cached version per plugin: the version installed_plugins.json names, else the newest by mtime.
    The cache keeps every version ever installed (316 SKILL.md files for 47 skills on this host), and a session loads one."""
    installed = {}
    try:
        with open(manifest) as fh:
            for key, val in (json.load(fh).get('plugins') or {}).items():
                for v in (val if isinstance(val, list) else [val]):
                    if isinstance(v, dict) and isinstance(v.get('installPath'), str): installed[key] = os.path.realpath(v['installPath'])
    except Exception: pass
    active, newest = set(), {}
    for vdir in glob.glob(os.path.join(cache_root, '*', '*', '*')):
        parts = vdir.rstrip(os.sep).split(os.sep)
        key = f'{parts[-2]}@{parts[-3]}'  # <plugin>@<marketplace>, the manifest's key shape
        if key in installed:
            if os.path.realpath(vdir) == installed[key]: active.add(vdir)
            continue
        try: mt = os.path.getmtime(vdir)
        except OSError: continue
        if key not in newest or mt > newest[key][0]: newest[key] = (mt, vdir)
    active.update(v for _, v in newest.values())
    return [os.path.dirname(p) for vdir in active for p in glob.glob(os.path.join(vdir, 'skills', '*', 'SKILL.md'))]
def description_chars(skill_md):
    """Characters of the frontmatter description; a block scalar (`description: >`) counts its indented continuation lines."""
    try:
        with open(skill_md, errors='replace') as fh: head = fh.read(20000).split('\n')
    except OSError: return 0
    for i, ln in enumerate(head[1:60], 1):
        if ln.strip() == '---': return 0
        if not ln.startswith('description:'): continue
        val = ln[len('description:'):].strip()
        if val not in ('>', '|', '>-', '|-', '>+', '|+'): return len(val)
        parts = []
        for cont in head[i + 1:i + 60]:
            if not cont.startswith((' ', '\t')): break
            parts.append(cont.strip())
        return len(' '.join(parts))
    return 0
sk = sorted(set(os.path.dirname(p) for p in glob.glob(os.path.expanduser('~/.claude/skills/*/SKILL.md'))) |
            set(plugin_skill_dirs(os.path.expanduser('~/.claude/plugins/cache'), os.path.expanduser('~/.claude/plugins/installed_plugins.json'))))
dchars = sum(description_chars(os.path.join(d, 'SKILL.md')) for d in sk)
sk_tok = dchars // 4 + 10 * len(sk)
total += sk_tok
print(f'  skill listing: {sk_tok:,} tokens (estimate: {len(sk)} skill dirs, one cached version per plugin (the installed one, else the newest), '
      'description chars/4 with block-scalar continuation lines + 10 per name; the real listing is budget-capped)')
servers = []
try:
    with open(os.path.expanduser('~/.claude.json')) as fh: servers = sorted((json.load(fh).get('mcpServers') or {}).keys())
except Exception: pass
names = set()
recent = sorted(glob.glob(root + '/*/*.jsonl'), key=os.path.getmtime, reverse=True)[:40]
for f in recent:
    try:
        with open(f, errors='replace') as fh:
            for line in fh:
                if 'deferred_tools_delta' not in line: continue
                try: a = json.loads(line).get('attachment') or {}
                except Exception: continue
                for n in a.get('addedNames') or []:
                    if isinstance(n, str) and any(n.startswith(f'mcp__{s}__') for s in servers): names.add(n)
    except OSError: continue
mcp_tok = 200 * len(names); total += mcp_tok
per = collections.Counter(n.split('__')[1] for n in names)
print(f'  MCP tool schemas: {mcp_tok:,} tokens (estimate; ASSUMPTION 200 tokens/tool, no cached tool schemas found on disk; '
      f'{len(names)} tool names from deferred_tools_delta in the newest transcripts; servers in ~/.claude.json: '
      f'{", ".join(f"{s}={per.get(s, 0)}" for s in servers) or "none"}; upper bound if the tools are deferred)')
resid = med - total
print(f'  system prompt and built-in tool schemas (residual): {resid:,} tokens (estimate: measured median minus the rows above)')
