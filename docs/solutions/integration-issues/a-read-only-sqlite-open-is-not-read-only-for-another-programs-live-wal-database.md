---
title: "A read-only SQLite open is not read-only for another program's live WAL database"
date: "2026-10-01"
category: integration-issues
module: cass-archive-readers
problem_type: integration_issue
component: development_workflow
severity: high
symptoms:
  - "`cass status` flips from healthy to unhealthy minutes after an agent runs `sqlite3 -readonly` aggregates on cass's archive"
  - "Every cass read, `cass search`, and the nightly search-health probe fail with `strict readonly open failed`"
  - "One stock `mode=ro` open turns cass's 64 KB `-shm` into a 32 KB stock WAL-index header"
  - "An unguarded `immutable=1` reader returns row counts no commit ever produced while a writer checkpoints"
root_cause: wrong_api
resolution_type: code_fix
framework_version: "cass 0.9.0 (fsqlite 0.4.4)"
related_components:
  - "cass-vec"
  - "dcg config (cass archive overrides)"
  - "lean-collector"
  - "cass-search-health"
tags:
  - sqlite
  - wal
  - read-only
  - immutable
  - cass
  - lean-collector
  - sidecar-files
  - cross-implementation
---

# A read-only SQLite open is not read-only for another program's live WAL database

## Problem

On 2026-09-29 this harness's own workflow agents ran `sqlite3 -readonly` aggregates on cass's live archive, `~/.local/share/coding-agent-search/agent_search.db`, and locked cass out of its own database. A stock SQLite reader in read-only mode still writes the WAL index (`-shm`). cass reads through its own SQLite implementation (fsqlite 0.4.4 in cass v0.9.0), which refuses the header stock SQLite writes, so every cass read failed until the sidecars were cleared.

## Symptoms

- `cass status` was healthy at 03:07 and unhealthy by 03:16, after the agents' `sqlite3 -readonly` reads (auto memory [claude]).
- Every read failed with `strict readonly open failed`: `cass search`, `cass status`, and the `ExecStartPost` search-health probe.
- On a byte-identical copy, one Python `sqlite3.connect("file:…?mode=ro", uri=True)` rewrote cass's 64 KB `-shm` as a 32 KB stock one (PR #1477). The new WAL-index header had a page-size field of 0 and zero salts, and cass also failed with a WAL present and no `-shm` at all (auto memory [claude]).
- The second half surfaced while fixing the first. Three `immutable=1` readers against a stock writer (100-row batches, `TRUNCATE` checkpoints, two 15 s runs) returned 340 counts no commit ever had (`conv:20900:msg:20837`) and about 9,700 `database disk image is malformed` errors (PR #1477).

## What Didn't Work

**Trusting `-readonly` / `mode=ro` to mean "touches nothing".** The flag is about the database file. A WAL-mode reader coordinates with writers through `-shm`, and a stock reader that finds a `-shm` it does not recognise, or none at all, rebuilds it. That rebuild is the write that broke cass. `tests/test_cass_vec_readonly.py:123` pins it as a precondition: a plain `mode=ro` open rewrites the fixture's `-shm`.

**`immutable=1` on its own.** It touches neither sidecar, so it cannot do what the stock open did. But it also skips locking and ignores uncheckpointed WAL frames. A read that overlaps a checkpoint sees a half-written file and returns wrong numbers, not only errors (the 340 phantom counts above). No sidecar writes does not mean coherent data.

**Protecting the canonical path string.** A denylist of `~/.local/share/coding-agent-search/agent_search.db` misses the other ways to name the same file. PR #1483's lean-collector hook had to screen canonical HOME/XDG paths, inherited `CASS_DB_PATH` and `CASS_DATA_DIR`, and the macOS default. It also parsed `file:` URIs and compared by real path or device and inode, which caught symlinks and hardlinks. That hook grew to 1,539 lines plus a 3,052-line test and was retired on 2026-10-17. In replay, its dedicated archive rule never fired: all 28 recorded sqlite3-on-archive commands were refused by other rules first. The dcg rule that replaced it matches text only (see Solution).

**Restarting cass or waiting.** The broken `-shm` stays on disk, so nothing self-heals. What cleared it twice on 2026-09-29 was a stock read-write checkpoint, run after copying `-wal` and `-shm` to `/tmp` as evidence (auto memory [claude]):

```bash
sqlite3 ~/.local/share/coding-agent-search/agent_search.db 'PRAGMA wal_checkpoint(TRUNCATE);'
# prints 0|0|0 and removes both sidecars; cass opens the DB again
```

dcg refuses this command from an agent, since it is the same stock open the archive rule exists to stop. Run the checkpoint from an operator terminal.

## Solution

Two readers that used to open the archive with stock SQLite were changed: `cass-vec` now reads with a guarded `immutable=1`, and dcg refuses agents' stock sqlite3 opens of the archive and points them at cass's own CLI.

**`cass-vec` reads with a guarded `immutable=1`** (PR #1477, `scripts/cass-vec:82-124`). It counts only while the WAL holds no frames and the file is unchanged across the read. Otherwise the fingerprint is unknown, never a guess:

```python
def _quiescent_stat(db_path):
    wal = db_path.with_name(db_path.name + "-wal")
    with contextlib.suppress(FileNotFoundError):
        if wal.stat().st_size > 32:      # frames present: commits not yet in the main file
            return None
    st = db_path.stat()
    return (st.st_ino, st.st_size, st.st_mtime_ns)

def _corpus_fingerprint(db_path):
    before = _quiescent_stat(db_path)
    if before is None:
        return None
    conn = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro&immutable=1", uri=True)
    ...                                  # count, then:
    if _quiescent_stat(db_path) != before:
        return None
```

`cass-vec status` then reports `corpus_stale: null` while cass is writing. The guarded version returned about 10,600 numbers in the same torn-read harness, with 0 wrong and 0 raised. Building the URI with `Path.resolve().as_uri()` also fixed paths containing `#` or `?`, which the old `file:{path}?…` form cut short.

**dcg refuses stock SQLite opens of the archive for every agent** (two `[overrides] block` entries in `config/dcg/config.toml`). This rule was first added to lean-collector's Bash hook (PR #1483, issue #1479) and moved to dcg on 2026-10-17. The first entry denies `sqlite3` and `agent_search.db` in one command, which also covers Python's `sqlite3.connect(...)` and `immutable=1` URIs; an arbitrary live immutable read can still be torn. The second denies a variable assigned to the archive path followed by sqlite3 (`DB=...agent_search.db; sqlite3 -readonly $DB`). Together they deny all 28 recorded sqlite3-on-archive commands, and `sqlite3` on any other database stays allowed. The refusal names the replacement:

```text
query it with `CASS_AUTO_REFRESH=0 cass search QUERY --no-maintenance --mode lexical --json`,
or copy the db with its -wal and -shm to /tmp under another name and open the copy
```

The match is on text, so a symlink, `cd` into the directory, or a copy kept under the same name goes by name only. `agents/lean-collector.md` gives the agent the same rule, so it does not discover it only by being refused. `tests/dcg-override-segment-bound.test.sh` proves both entries by asking dcg.

## Why This Works

The fault sits where two SQLite implementations share one WAL index. Stock SQLite and fsqlite 0.4.4 disagree about which `-shm` header is valid. Any stock open, however "read-only", can leave a header that cass's strict read-only open rejects. Each approach below removes stock SQLite from that shared state:

- **cass's own CLI** reads with cass's implementation and locking, so no foreign header ever appears.
- **Guarded `immutable=1`** never opens the sidecars. The quiescence check covers what `immutable=1` gives up: with no WAL frames, every commit is in the main file, and an unchanged inode, size and mtime show no checkpoint rewrote it mid-read.
- **Copying the database together with its `-wal` and `-shm`**, then opening the copy, keeps any rebuild off the live files. A private evals repository's cass session export already works this way (#1477).

Upstream fsqlite e85717e0a (0.4.6, "accept stock's unindexed empty WAL index") makes cass tolerate the stock header. cass `main` adopted it in e69c1414, but as of 2026-10-01 no cass release includes it (latest v0.9.0). Even after it ships, the torn-read half and the rule against unscoped live reads still stand.

## Prevention

1. **Read another program's live SQLite database through that program's own interface.** For cass, that is `CASS_AUTO_REFRESH=0 cass search … --no-maintenance --mode lexical --json`, or `cass status --json` from an operator shell, never `sqlite3`.
2. **If you must read the file, read a copy.** Copy the database together with its `-wal` and `-shm`, then open the copy. Otherwise use `immutable=1` with a quiescence guard, and return "unknown" when the guard fails.
3. **Do not classify `sqlite3 -readonly` as a pure reader in a sandbox or allowlist** when the target is a WAL database another process owns. Before #1483, the read-only hook's own test suite approved `sqlite3 -readonly <path>` as a read (issue #1479), and that approval is the hole the agents walked through. This session verified the hazard only against cass's fsqlite. It did not test databases owned by stock SQLite, such as better-ccflare's, which another session read with `sqlite3 -readonly` on 2026-09-27 without incident (session history).
4. **Guard by file identity, not by path string.** Aliases, environment overrides and URIs all reach the same inode.
5. **Make the regression test prove it can see the defect.** `test_cass_vec_readonly.py:123` asserts that a plain `mode=ro` open rewrites the fixture's `-shm`, which is what gives the tests asserting the fix leaves it alone (`:133`, `:144`) their meaning. Without that precondition, a fixture that never builds a WAL index would pass every "untouched" assertion against the broken code too.

## Related

- Issues: #1479 (hook gap), #1235 (cass retrieval umbrella), upstream `Dicklesworthstone/coding_agent_session_search#494` (v0.9.0 retest, including the BusyRecovery data point).
- PRs: #1477 (guarded `immutable=1` in `cass-vec`), #1483 (hook archive protection, retired 2026-10-17 for the dcg rule).
- `fail-closed-gate-on-monotonically-degrading-input-becomes-a-permanent-latch.md` (logic-errors): the same rule one layer up. Its fix points the release-promotion smoke at a scratch `--db` and asserts the isolation held, so the check never touches the live archive.
- `routing-metadata-that-says-the-alternative-is-broken-outlives-the-outage.md` (best-practices): the same archive, a different failure. There, a stale description misrouted agents; here, a "read-only" probe broke the archive it was inspecting.
- Memory `stock-sqlite-open-wedges-cass-archive` (auto memory [claude]): incident timeline and recovery steps.
