---
name: worktree-command-shapes
description: "Measured accept/deny table for CC's worktree-isolation command verifier — which Bash shapes pass, which are refused as 'too complex to verify', and the tool substitutions that stay inside the guard"
metadata:
  node_type: memory
  type: project
  originSessionId: 337cfbcf-8a18-4ae7-9179-80cb79e2a743
---

# Worktree-isolated command shapes

In a worktree-isolated session (a background job after EnterWorktree), Claude Code
statically verifies every Bash and Monitor command before running it. Shapes it cannot
verify are refused. This was the fleet's **#1 bash-denial family: 7,109 events / 192
sessions / 449 worktree CWD slugs over the 30 days ending 2026-08-27** (papercut rollup).
Siblings in the family: git redirected via `-C`/`-c` (299 ev/72 sess), cwd resolved to the
shared checkout (183/13), `cd` to the shared checkout (29/16), and the same too-complex
message via the Monitor tool (27/13).

The verifier ships inside the Claude Code binary (confirmed v2.1.243: the message string
exists only in the CLI bundle — not in dcg v0.13.2, not in any dotfiles hook). The docs
say outright "You can't turn this check off", and a maintainer confirmed on
anthropics/claude-code#84258 that PreToolUse `permissionDecision: "allow"` hooks and
`--dangerously-skip-permissions` do not bypass it (see "Documented semantics" below). The
remedy is writing commands in verifiable shapes.

## Quick rules (full text; `CLAUDE.md` Global Rules carries the short form)

The always-loaded file keeps one line ("put multi-step work in a script file and
run `bash <file>`") and points here for the rest:

- Shell scratch lives in `/tmp/<unique-dir>/`: point redirects (`>`, `2>`) and
  scratch deletion there, and start a fresh uniquely-named dir instead of
  `rm -rf` + recreate. dcg guards every `$HOME` path, including
  `$CLAUDE_JOB_DIR/tmp`, which is for Write-tool files only.
- The check applies to every worktree-isolated session (background jobs,
  subagents, resumed sessions), and nothing from inside the session relaxes it.
- Refused: `$( )`/backticks in argument position, `${VAR:-…}` modifiers,
  unquoted heredoc delimiters, loop-var use, package-manager operands
  (`pnpm typecheck`, `npx tsc`), a bare `hash` token.
- Fine: `&&`/`;`/pipe chains; `<<'EOF'`, except when the body has a quote
  inside `{}` (JSON, a Python dict) or a redirect precedes `<<` after
  `&&`/`||`, as in `mkdir -p d && cat > d/f <<'EOF'`. shape-rewrite runs both
  as a script when the heredoc only feeds `cat`/`tee` into the worktree,
  `/tmp`, or `~/.claude/jobs`; otherwise write that file with the Write tool
  (anthropics/claude-code#96253).
- A plain `$VAR` passes in an output-only command like `echo $HOME`. Elsewhere a
  `$VAR` where an option may stand is refused: spell the value out or put `--`
  before it.
- `bash <script-file>` and worktree-targeted git pass. Never smuggle a command
  through a `bash -c` string.

## The denial messages, verbatim (grep for these words → this doc)

Too-complex (the 7.1k-event message; also emitted by the Monitor tool):

> This session is isolated in the worktree `<worktree>`, but this command is **too
> complex to verify that it stays inside the worktree**. Refusing to run it — a
> worktree-isolated session's git operations must target its own worktree. Split it into
> plain, separate commands and run them from `<worktree>`.

Git redirected out of the worktree:

> This session is isolated in the worktree `<worktree>`, but this command **redirects git
> to the shared checkout via -C**. Refusing to run it — a worktree-isolated session's git
> operations must target its own worktree. Run the equivalent from `<worktree>` without
> the redirect.

`cd` out before git:

> This session is isolated in the worktree `<worktree>`, but this command **changes
> directory to the shared checkout** (`<shared checkout>`) before running git. Refusing to
> run it — a worktree-isolated session's git operations must target its own worktree. Run
> the equivalent from `<worktree>` without the redirect.

A bare `hash` token anywhere in the argv (its own message — the verifier models the shell
builtin, which can rewrite command lookup):

> This session is isolated in the worktree `<worktree>`, but this command **runs a string
> through hash**, which can't be verified to stay inside the worktree. Refusing to run it
> — a worktree-isolated session's git operations must target its own worktree. Run git
> directly with literal arguments from `<worktree>`.

Working directory escaped (sibling, from papercut samples — not probed; probing it risks
wedging the session's cwd):

> …this command's working directory resolved to the shared checkout (`<path>`)…

## Probe matrix

Every row was executed live from `/home/user/hov-stack/.claude/worktrees/worktree-command-shapes`
in an isolated session (session `337cfbcf-8a18-4ae7-9179-80cb79e2a743`, CC **2.1.243**,
**2026-08-27**) — nothing here is inferred from reading the bundle. **32 accept rows** (a
few list several equivalent commands), **15 refusals** across three distinct denial
messages. Each row's shape claim is only as broad as the command(s) beside it; a row
label is shorthand for "observed with these commands", not a proven category. Treat
untested neighbours as unknown rather than allowed — where a boundary is actually
discriminated (substitution position, package-manager operands, the `hash` token), the
prose below says so explicitly and names the paired probes that establish it.

### PASS — verifiable shapes

| Shape | Probe |
|---|---|
| Plain command | `echo p1-ok` |
| `&&` chain | `echo p2a && echo p2b` |
| `;` list | `echo p16a; echo p16b` |
| Pipe | `echo p4 \| wc -l` |
| Relative `cd` inside worktree + chain | `cd claude && echo p3-ok` |
| Quoted-delimiter heredoc | `cat <<'EOF'` … `EOF` |
| Redirect to `/tmp` scratch file | `echo p7 > /tmp/wtverifier-337cfbcf/p7.txt` |
| Relative append inside worktree | `echo p22 >> p22-probe.txt` |
| Input redirect | `wc -l < <worktree>/README.md` |
| Plain `$VAR` expansion | `echo $HOME` |
| Env-prefix assignment, literal value | `FOO=bar printenv FOO` |
| `for` loop, loop var unused in body | `for i in 1 2; do echo p9b-fixed; done` |
| `if` statement | `if true; then echo p23-ok; fi` |
| Bare git | `git status --short` |
| Git pinned to the worktree | `git -C <worktree> status --short` |
| Git piped | `git log --oneline -3 \| head -2` |
| Chained git (worktree-targeted) | `git status --short && git log --oneline -1` |
| Direct relative script path | `./scripts/work-spec-check.sh --help` |
| Package manager, flags only | `pnpm --version`, `pnpm --filter startupbros --version`, `npx --version`, `node --version` |
| Flag text as plain argument | `echo --filter startupbros` |
| Search with a quoted pattern | `rg -n "too complex" <file>` |
| `grep` with a pattern that merely contains "hash" | `grep -rn "hashish" <file>`, `grep -c "payload-hash" <file>`, `echo "the hash value"`, `echo hashes` — only the standalone token `hash` denies (below) |
| `sed` with a quoted script | `sed -n '1,2p' <file>` |
| `find` with a quoted glob, piped | `find harness -name "*.md" \| head -2` |
| `gh` CLI with JSON flags | `gh pr view 535 --json number,state,isDraft` |
| `python3 -c` inline program | `python3 -c "print('p39-ok')"` |
| Staging and committing | `git add <paths>`, `git commit -F <abs path>` (message file may live outside the worktree) |
| Running a script file by absolute path | `bash /home/user/.claude/jobs/<id>/tmp/run-suites.sh` (its internal loops/`$( )` are never parsed — only the invoking command is) |
| Package-manager operand **carried as an argument** to a script | `bash /tmp/wt-probe/run.sh 'pnpm typecheck'`, `bash /tmp/wt-probe/run.sh pnpm typecheck`, `CLAUDE_HEAVY_CMD='pnpm typecheck' bash /tmp/wt-probe/run.sh` — the operand denies only when it is the command itself (below); as a quoted or positional argument, or an env-prefix value, it passes. Probed 2026-09-02 (CC 2.1.257, isolated session; receipts on dotfiles#864). This is what lets `heavy-job-admission.js` hand the original command to `hooks/lib/heavy-job-admission-run.sh` instead of inlining a preamble whose own `$( )` the verifier refused. |
| Launcher, non-git payload | `bash -c "echo p15b-ok"` |
| Command substitution **in an env-prefix assignment value** | `V=$(date) printenv V`, `P=$(pwd) printenv P` — assignment values are not analyzed. The discriminator is **position**, not the variable's name or the inner command: a path-producing `$(pwd)` still passes here, while the same substitution in argument position denies (below). **Do not build on this**; prefer no substitution at all. |
| Interpreter running a script file | `python3 /abs/path/count-rows.py` |
| Combined stdout+stderr redirect to `/tmp` scratch | `ls harness > /tmp/<unique-dir>/out.txt 2>&1` |

### DENY — "too complex to verify"

| Shape | Probe |
|---|---|
| Command substitution **in argument position** | `echo $(echo p5)`, `echo $(date)` — the same `$(date)` passes as an assignment value (above), so the refusal is about where the substitution sits, not what it runs |
| Backticks | `` echo `echo p24` `` |
| Parameter-expansion modifier | `echo ${HOME:-x}` |
| Unquoted-delimiter heredoc | `cat <<EOF` … `EOF` |
| Quoted-delimiter heredoc whose body has a quote inside `{}` (e.g. JSON) | `cat <<'EOF'` … `{"name": "x"}` … `EOF` — refused even though the delimiter is quoted, and `{'name': 'x'}` is refused too; `x = {a: 1}`, `'a' {b}`, `print("a")`, `x = dict(a=1)` bodies pass (single-command probes, CC 2.1.280, 2026-09-23). Filed upstream: anthropics/claude-code#96253. `shape-rewrite.js` detects both quotes (the double quote since dotfiles#1348, the single quote since dotfiles#1365) and runs the command as `bash <script>` when the heredoc only feeds `cat`/`tee` into the worktree, `/tmp`, or `~/.claude/jobs`; a heredoc fed to a shell or interpreter (`bash`, `python3 -`) or redirected outside those roots is still refused, so write the file with the Write tool. Share (7 days to 2026-09-23, `scripts/shape-refusal-mine.js`): 1,042 of 2,124 refusals (49.1%) had this body, 400 of them (18.8%) with only single quotes inside the braces; #1348's same-window before/after moved rewritable refusals from 104 to 515 of 2,057. Re-measured without the session that built dotfiles#1365, whose own probes and review subagents were a third of the window's refusals: 543 of 1,402 had this body, 175 of them (12.5%) with only single quotes. |
| Quoted-delimiter heredoc after `&&`/`\|\|` with a redirect before `<<` | `mkdir -p d && cat > d/f <<'EOF'` … `hello` … `EOF` — refused with a plain body, as are `false \|\| cat > f <<'EOF'` and, after `true &&`, `cat` with `>>`, `>\|`, `2>`, `2>&1`, `<`, or `&>` before `<<'EOF'`; `true && cat <<'EOF' > f` (redirect after `<<`), `true && tee f <<'EOF'`, `echo hi; cat > f <<'EOF'`, `echo hi > f && cat <<'EOF'` (redirect in the command before `&&`), a pipe, a lone `cat > f <<'EOF'` or `cat >\| f <<'EOF'`, and quoted operator text such as `true && echo '>' <<'EOF'` run (single-command probes, CC 2.1.280, 2026-09-23). Since dotfiles#1365 `shape-rewrite.js` detects it (`hasListRedirectHeredoc`, over the quote-aware `reachWords` tokens since dotfiles#1370) under the same reach check as the row above. Share (7 days to 2026-09-23, without the session that built this row): the trigger newly detects 119 of 1,402 refusals, 68 of them rewritable; with both rows detected, rewritable refusals went from 289 to 453 in the same window. `cat <<'EOF' && echo after` is a separate refusal ("uses a command after a here-document") and is not rewritten. |
| `for` loop using the loop var | `for i in 1 2; do echo p9-$i; done` |
| Package-manager script, shorthand | `pnpm typecheck` |
| Package-manager script, `run` form | `pnpm run typecheck` |
| Package-manager script + flags | `pnpm --filter startupbros typecheck` |
| Package-manager `exec` form | `pnpm exec tsc --version` |
| `npx` with a tool operand | `npx tsc --version` |
| Interpreter fed via bare `-` from a heredoc, program on stdin (mined, not part of the 2026-08-27 session — see caveat below) | `python3 - <<'EOF'` … `EOF` |

**Provenance caveat on the `interp` row**: unlike the rest of this table, that row is not
from the 2026-08-27 live-probe session — it is derived from 470 mined fleet refusals for
dotfiles#1273, of which 80 matched `python3`/`python`/`node`/`perl`/`ruby` run with a bare
`-` and a heredoc feeding the program on stdin, historically refused as this family. A
re-probe attempted in this session (CC **2.1.278**, 2026-09-21) could **not** reproduce a
raw refusal for either a plain `python3 - <<EOF … EOF` (unquoted delimiter, two `print`
lines) or a `cat <<EOF … EOF` body containing `$(date +%s)` — both ran to completion with
no denial. The git-`-C`-to-shared-checkout refusal was reconfirmed live in the same
session in the same few minutes (still fires, verbatim message, but now says "This agent
is isolated…" where the 2.1.243 baseline says "This session is isolated…"), so the
verifier itself is active; only the generic heredoc-shape bailout looks different between
2.1.243 and 2.1.278.

This is a two-sample re-probe, not enough on its own to correct the dated row above, so
it is recorded as an open discrepancy rather than a correction — with the fields that
make it actionable rather than speculative: **consumer** — the next person who touches
either this row or `shape-rewrite.js`'s `INLINE_INTERPRETERS`/`hasInterpStdinShape()`
family (the code that exists specifically to work around this refusal); **what it
gates** — whether that family is still defending against a refusal the live verifier
actually produces on the currently-running CC version, since if the verifier has
stopped refusing this shape, the rewrite it offers is solving an already-solved
problem, not a new risk; **defect class** — a version-dependent behavior change in the
verifier itself (CC 2.1.243 refused this shape, CC 2.1.278 did not, in otherwise
identical single-session conditions) rather than a bug in this repo's own code;
**deletion condition** — delete this caveat the next time this row is live re-probed
(≥3 independent samples, matching the bar a two-sample result explicitly does not
clear) and either fold the result into the row directly (refusal reconfirmed) or
retire the row and re-assess the `interp` family's live necessity (refusal gone for
good).

### DENY — the `hash` token (its own message)

| Shape | Probe |
|---|---|
| Quoted `hash` as a grep pattern | `grep -rn "hash" <file>` |
| Unquoted `hash` as a grep pattern | `grep -rn hash <file>` |
| `hash` as an argument to anything | `echo hash` |

Discriminated to **exact argv-token equality**: `echo hash` denies, while `echo hashes`,
`echo "the hash value"`, `grep -rn "hashish" …` and `grep -c "payload-hash" …` all pass.
The verifier is modelling the shell builtin `hash` (which rewrites command lookup), so any
argument that happens to *be* the word triggers it. Practical effect: **never grep for the
bare word `hash` in an isolated session** — search for a longer token (`payload-hash`,
`hash_`, `hashes`) instead. This confirms, and sharpens to token level, the field report in
memory note `pnpm-is-blocked-in-worktree-isolated-sessions`.

The package-manager rows discriminate cleanly and across three runners: `pnpm --version`,
`pnpm --filter startupbros --version` and `npx --version` all pass, and
`echo --filter startupbros` passes, while `pnpm typecheck`, `pnpm run typecheck`,
`pnpm --filter startupbros typecheck`, `pnpm exec tsc --version` and `npx tsc --version`
all deny. The trigger is a **program or script operand** — a non-flag argument naming
something to execute — not pnpm itself, not `--filter`, and not workspace or store
resolution. `tsc --version` is as harmless a payload as exists, and it still denies, so
this is about the shape, not the work. (Probed for pnpm and npx; `pnpx`, `yarn`, `bun` and
`npm run` are untested — assume they behave like their siblings, but that is inference.)

### DENY — redirect siblings (verifier armed, as designed)

| Shape | Probe | Message |
|---|---|---|
| Git `-C` to the shared checkout | `git -C /home/user/hov-stack status --short` | "redirects git to the shared checkout via -C" |
| `cd` to the shared checkout before git | `cd /home/user/hov-stack && git status --short` | "changes directory to the shared checkout … before running git" |

### `shape-rewrite.js` reach-check refinements (dotfiles#1273, #1271)

These four narrow the hook's own `reaches()` check — whether a detected shape can be
proven to stay inside the worktree/scratch roots and is therefore safe to rewrite into
`bash <script>` — not the raw verifier's PASS/DENY behavior above. Measured against 470
mined refusals: before this change, 5/470 were rewritable; the interp and gh-read-verb
buckets alone account for 172 of the remaining refusals (80 + 92).

- **`interp` shape — interpreter-on-stdin — carve-out REVERTED (round 6, dotfiles#1295).**
  `python3`/`python`/`node`/`perl`/`ruby` invoked with a bare `-` as the program
  argument, fed by a heredoc whose delimiter is **quoted** (`<<'EOF'`, not `<<EOF`), with
  no other program-bearing argument (`-c`, `-m`, `-e`, `--eval`, or a script path), used
  to be a narrow carve-out: rewritable when the heredoc BODY also passed a denylist scan
  for host-reaching literals (an absolute path outside every allowed root, `~`/`HOME`/
  `expanduser`/`USERPROFILE`, a `..` segment, `chdir`, a shell-out primitive, or the
  tokens `git `/`gh `). Adversarial review of PR #1295, round 6, reproduced live against
  that scan: a `chr()`-built path string and a `getattr(os, 'sys'+'tem')`-based dynamic
  dispatch both read as non-reaching, with zero denylisted literal appearing anywhere in
  the source text, for an outside-root read, an outside-root write, and an `os.system`
  shell-out — a denylist/pattern scan over a Turing-complete language's raw source text
  cannot be made sound against composed or computed constructions, and no sound,
  non-enumerative gate was articulated for it (the only fix would be to actually parse
  the target language's AST, out of proportion for a shell-command-shape classifier and
  not attempted). **The carve-out is reverted outright, not narrowed further**: a bare
  `-` argument fed by ANY heredoc (quoted or unquoted) to one of these interpreters is,
  again, unconditionally treated as reaching, restoring the pre-#1273 rule this carve-out
  had reversed. The heredoc-body denylist scan this depended on
  (`HEREDOC_BODY_LITERAL_DENY`, `heredocBodyReaches()`, and the rest of that family in
  `lib/shape-rewrite-reach.js`) was deleted in the same change, since it no longer had
  any caller. There is no positive case for this shape anymore — every one of the
  previously-listed "planted negatives that stay reaching" (an unquoted delimiter,
  `python3 -c "…"`, `python3 script.py <<'EOF'` …, a `cd`/`git`-prefixed chain before the
  heredoc) is simply the whole shape now, alongside the previously-carved-out quoted case.
- **`gh` read verbs are not path-capable.** A `$VAR`, `${VAR}`, or `--jq` expression in a
  `gh` read-verb call's arguments is not "building a path" — these verbs never write or
  dereference an argument as a filesystem target. Read verbs: `pr view|list|checks|diff|
  status`, `issue view|list|status`, `run list|view|watch`, `repo view`, `release
  list|view`, `search *`, `label list`, `workflow list|view`, `auth status`, and `api`
  **only** when the call carries no `-X`/`--method` other than GET and no
  `-f`/`-F`/`--field`/`--raw-field`/`--input`/`--body-file` in either the space-separated
  OR glued (`--input=payload.json`, `--method=POST`) form. A global flag before the
  subcommand pair (`gh --repo owner/repo pr view $n`, `gh -R owner/repo issue list`)
  still resolves. The subcommand is read from a **fixed position** — the first one or
  two bare (non-flag) words after skipping the leading run of global flags — not by
  scanning every adjacent literal pair in the argument list. Adversarial review of PR
  #1295, round 2, findings 1 and 2 found two ways the earlier position-free scan and
  exact-token flag check missed a write: `gh issue edit $n --title search` matched the
  bare literal `search` sitting in a `--title` VALUE, `gh issue edit $n --body pr view`
  matched the adjacent pair `pr view` sitting in a `--body` VALUE, and `gh api …/$n/…
  --input=payload.json` missed the glued form entirely — all three let a genuinely
  mutating call with an unresolved `$n` read as a no-path read. Both are now closed:
  `api` and `search` are recognized only when they land exactly at the fixed subcommand
  position, never elsewhere in the call, and every `GH_API_WRITE_FLAGS` member is
  checked in both its unglued and glued forms generically (not one hardcoded
  `startsWith` per flag). Planted negatives that stay reaching: any write verb
  (`checkout`, `clone`, `download`, `create`, `edit`, `comment`, `close`, `merge`,
  `delete`, `review`, `ready`, `sync`, `fork`) and any `api` call carrying `-X POST`/etc.,
  a field flag, or `--body-file`/`--input` in either form — e.g. `gh pr checkout $n`,
  `gh run download $n`, `gh api -X POST … $n`, `gh pr edit $n --body-file -`. The
  detector fails closed: an unrecognized verb/flag combination, or one recognized only
  somewhere other than the fixed subcommand position, is treated as write-shaped
  (reaching), never assumed safe.
- **No-path variables: a variable is only "not building a path" on a command with no
  file operand at all.** The shipped output-only no-path set (`OUTPUT_ONLY_COMMANDS`) is
  `echo`, `printf`, `printenv`, `true`, `false`, `:`, `expr`, `seq`, `basename`,
  `dirname`, `sleep`, `tr`, plus the `gh` read verbs above. A `$VAR` in one of these
  commands' arguments does not reach. `jq`, `cut`, `sort`, `uniq`, `head`, `tail`, and
  `wc` were tried and reverted before merge: each takes a FILE operand (`sort -o file`,
  `uniq in out`, `head file`, `jq . file`, `wc -l file`, `cut -f1 file`), so a `$VAR`
  there can resolve to a read or write target outside the sandbox at runtime — a
  containment hole caught in adversarial review (PR #1295, finding 1). `test`, `[`,
  `[[`, and `date` were also tried and reverted for the same bar (ce-code-review round on
  2b279d2, finding #4): `date -f FILE` reads dates line-by-line from FILE (live-
  reproduced: non-date content in that file is echoed verbatim to stderr), and
  `test`/`[`/`[[`'s `-f`/`-e`/`-r`/`-w`/`-x`/`-s` operators file-test their operand — the
  path check has no flag-awareness to exempt only the non-file-test operands of these
  commands, so the entire command loses the exemption rather than gaining one that
  can't be enforced narrowly. Any other command — `cat`, `ls`, `sed -n`, `rg` with a
  path, `cp`, `mv`, `rm`, `python3 <path>`, `bash <path>`, `git` — still reaches through
  a variable argument it can't resolve. Planted negatives: `for f in *.md; do cat "$f";
  done`, `sed -n 1p $S/x`, `bash "$SCRIPT"`, `git -C "$WT" status`, `sort -o $out
  data.txt`, `uniq $in $out`, `head $f`, `jq . $f`, `wc -l $f`, `cut -d, -f1 "$LINE"`,
  `tail -n1 "$X"`, `test -f $f`, `[ -e $f ]`, `date -f $f`.
- **Assignment-position command substitution is now a detected shape.** `NAME=$(…)` and
  `` NAME=`…` `` (a leading assignment, or one after `;`/`&&`/`||`/newline) is detected as
  the existing `cmdsub` shape and reach-checked like any other substitution — the mined
  set includes real examples such as `PY=$(for c in python3 python py; …)`, `sha=$(gh pr
  view $n …)`, and `tip=$(git rev-parse HEAD)`. A literal `/tmp/...` `mktemp` target
  inside the allowed roots resolves; `git`, being outright reaching, still reaches
  through an assignment until a future R-git carve-out lands — `WT=$(git rev-parse
  --show-toplevel)` and `D=$(mktemp -d /home/user/hov-stack/x.XXXXXX)` (outside the
  worktree) both stay pass-through, unchanged.
- **A newline separates commands in the reach check (dotfiles#1317).** Until this fix,
  `reachWords()` read an unquoted newline as plain whitespace, so every later line was
  more arguments to the first line's command. Behind an output-only first line, a
  variable path on a later line was never checked: `echo "$(date)"` + newline +
  `rm -rf "$TARGET"` was rewritten, while the `;` form was refused. A newline now splits
  like `;`. After `|`, `&&`, `||` or `(` it continues the command, so `a |` + newline +
  `bash` keeps its piped stdin; after `;`, `&` or another newline it adds no second
  separator. A backslash-newline is still a line continuation. A `#` that starts a word
  refuses the command outright. Read as words, a comment could cut a pipe (`a | # note`
  + newline + `bash` lost bash's piped stdin) or open a quote (`# don't` swallowed later
  lines), and a `<<'EOF'` inside a comment was taken for a real heredoc. Skipping
  comments instead is wrong wherever bash does not read `#` as one (extglob, `(( ))`,
  `${ }`, `$[ ]`), since the rest of that line still runs. A `#` in an unquoted heredoc
  body is data and does not refuse. Measured 2026-09-22:
  - Of the 30-day refused set (11,630 invocations), the fix withdraws 28 would-be
    rewrites, all read by hand and none writing outside, and adds 64 (368 → 404).
    The `#` rule withdraws none of the 404.
  - None of the 244 unique commands the live hook actually rewrote since 2026-09-21
    depended on the bug.

**Addendum, 2026-09-21 (round 2 of PR #1295's adversarial-first review).** Re-measured
against the round-2 review's own 470-record mined-refusal snapshot
(`/tmp/pc-cov-145e3a7e/full.json`, same method as above): commit 53e1c8a (round 1's
fixes only) reproduces the PR body's stated baseline exactly, 127/470 (27.0%)
rewritable; after the three round-2 fixes above (gh subcommand anchoring, glued-flag
detection, interp heredoc-body scan), 103/470 (21.9%) — a drop of 24 records. Diffing
per-record outcomes shows all 24 lost records are `interp`-shaped and none involve
`gh`: the interp body scan is the entire cause of the coverage decrease, an expected and
disclosed cost (over-refusal on real scripts that touch `/home/user/...` paths not under
this worktree, several of them legitimate but unresolvable statically as safe). The gh
anchoring and glued-flag fixes (findings 1 and 2) show zero flips in this organic
sample — a null result, not a failure: both bugs were found by the reviewer's
constructed reproductions, not organically present in this week's mined refusals, and
both reproductions are now covered as red-first tests in
`hooks/tests/shape-rewrite.test.js`. Interp's share of the rewritable set drops
from 52/127 (40.9%) to 28/103 (27.2%) accordingly.

**Addendum, 2026-09-21 (round 3 of PR #1295's adversarial-first review).** A follow-up
ce-code-review on 2b279d2 found the round-2 heredoc-body scan was still an ALLOWLISTED
extra check bolted onto one carve-out (`INLINE_INTERPRETERS`), not a default: a
command whose name is not `python`/`node`/`perl`/`ruby`/a shell but that still reads a
heredoc as its program — `ssh host <<'EOF'`, `psql <<'EOF'`, any other stdin-reading
client this hook has never heard of — matched none of the four recognized command-name
sets and so skipped every reach scan entirely, with no default-deny fallback (finding
#1, P0). Fixed by inverting the default: a **quoted** `<<`/`<<-` heredoc fed to any
command that is not `INLINE_INTERPRETERS`, not `SHELLS`, and not a "pure data sink"
(`cat`, `tee`, or an `OUTPUT_ONLY_COMMANDS` member — none of which can execute their
stdin as code) is now treated as reaching outright; a shell (`SHELLS`) fed *any*
`<<`/`<<-` heredoc, quoted or not, is treated as reaching outright unconditionally
(closes `bash -s <<'EOF' ... EOF`, previously uncovered). This default-deny is
deliberately scoped to `<<`/`<<-` only — `<<<` (here-string) and plain `<` (file
redirect) are unaffected, because both already run through pre-existing, unrelated
mechanisms (a here-string target is an ordinary word subject to the generic
argument scan; a plain `<` target is a `REDIRECT_TARGET_OPS` member checked
unconditionally) and widening the new default onto them was unnecessary. The sink
exception is a bare skip, not a scan: `cat`/`tee`/output-only commands never run
`heredocBodyReaches()` over their body at all, since the denylist itself would
false-positive on an inert body (e.g. `cat <<'EOF'` … `$(git status)` … `EOF`, a
pre-existing green test, contains the literal `git ` the denylist flags).

The **interp carve-out itself is kept**, unchanged in shape, as the one disclosed
exception to the new default — the parity argument from round 1 (a Write-then-run
two-step is already unaudited the same way) still stands as the justification, not as
a claim that the carve-out is safe on its own. What round 2 added and round 3
re-affirms explicitly: `heredocBodyReaches()` is a **literal tripwire, not a
containment proof**. It catches a body that spells out a host-reaching primitive by
name (`subprocess`, `os.system`, an absolute `/etc/...` path, a bare `git `/`gh `
token); it does **not** catch the same primitive reached through import aliasing
(`import os as o; o.system(...)`), reflection/`getattr`, string concatenation of a
denied path, base64/hex-decoded literals, or any other composed construction — the
identical class of evasion the shell reach check already accepts for a `$VAR` it
cannot resolve. A stale in-code comment claiming the body was "deliberately not
reach-checked" — written for round 1, contradicted by round 2's own scan sitting a
few lines below it — has been corrected to say what actually runs (finding #9): the
body IS scanned, but only the shape of the *command string* that reaches this branch
ever changes, never what actually executes.

**Superseded, round 6:** the paragraph above is a historical record of round 3, not
current behavior. Round 6 live-reproduced exactly the residual-risk class round 3
disclosed here (`getattr`-based dynamic dispatch and `chr()`-built path strings both
evaded `heredocBodyReaches()` with zero denylisted literal in the source text) and
found it defeated with no sophistication required — more severe than "residual," with
no sound non-enumerative gate articulable for it. The interp carve-out was reverted
outright, not narrowed further: `heredocBodyReaches()` and the rest of the
`HEREDOC_BODY_LITERAL_DENY` family were deleted, and a bare `-` argument fed by any
heredoc (quoted or not) to an `INLINE_INTERPRETERS` command is unconditionally treated
as reaching, full stop. See the `interp` shape entry earlier in this file for the
current rule.

Re-measured against the same 470-record snapshot after the round-3 fixes (default-deny
above, plus a `gh` reaching-outright check moved off an unbounded adjacent-pair scan
onto the fixed-position `ghSubcommandPosition()` helper — finding #10 — and one shared
`isInterpStdinArgShape()` predicate replacing two independently-tokenized copies of the
same shape test — finding #12): 96/470 (20.4%) rewritable, down from 103/470 (21.9%), a
drop of 7 records — the default-deny catching real stdin-fed commands (an `ssh`-plus-
quoted-heredoc call among them) that were previously rewritable with zero scrutiny of
their payload. The coverage script's own `reach:heredoc_or_stdin_payload` bucket reads
0 both before and after this round — not because the new denial path is inactive (the
7-record drop and the `ssh` case landing in `reach:other_cmd_outright(ssh)` prove it
ran) but because the script buckets by matching `/treated as reaching outright/` before
it ever reaches its heredoc-specific pattern, and every message this round adds ends in
that same "treated as reaching outright" phrase; a categorization-script artifact, not
a measurement of whether the fix fired. Finally, the heredoc-body-denylist, `gh`-verb-
classification, and word-object-accessor families (roughly 210 lines, previously
one-third of this file's total growth since the base commit — finding #8) were split
out into `hooks/lib/shape-rewrite-reach.js`; the split is confirmed
behavior-preserving by identical coverage output and an unchanged 708/708 full hook
suite before and after.

**Addendum, 2026-09-21 (round 4 of PR #1295's adversarial-first review).** Five more
findings, four fixed, one refuted (and independently addressed by another's fix):

1. **Finding #1 (P1).** A bare shell fed its script through a real pipe (`cat <<'EOF' |
   bash`, `echo '...' | bash`) or an interpreter fed a program the same way (`echo
   '...' | python3`) read that piped stdin as code, but the SHELLS/INLINE_INTERPRETERS
   dispatch only ever inspected argument words, never whether stdin itself was the
   payload — a piped bare shell/interpreter with no other non-flag operand is now
   treated as reaching outright, unconditionally. Fixing this exposed a second,
   independent bug in `excludeHeredocBodies()`: the function cut every heredoc at its
   delimiter's own text span (`delimEnd`) rather than at the end of the delimiter's
   *line*, silently dropping same-line trailing text after the marker — `cat <<'EOF' |
   bash` tokenized as bare `cat <<EOF` with the `| bash` invisible to every downstream
   check. Fixed by tracking each heredoc's `sameLineEnd` and cutting there instead.
   `bash script.sh` and `bash -c '...'` piped the same way are untouched (a real
   operand is present) and stay rewritable.
2. **Finding #2 (P1).** `ghApiIsReadOnly()` matched write flags by literal token
   (`-f`, `--field`, etc.) but a whole-word bare shell variable in flag position
   (`gh api repos/x/y/issues/$n $FLAG`) matches none of them and read as safe, even
   though `$FLAG` undergoes ordinary word-splitting at runtime and can resolve to
   `-f body=...` or `-X DELETE`. A bare `$VAR`/`${VAR}` word (not embedded inside a
   larger literal like `repos/.../$n`) in `gh api` argument position is now
   unconditionally treated as write-shaped.
3. **Finding #3 (P1), together with the refuted finding #6.** Before this round, the
   ONLY unconditional-reach `gh` verbs were a two-line hardcoded check for exactly
   `pr checkout` and `repo clone`/`repo sync`; every other write verb invoked with
   purely literal arguments — `gh co 123` (gh's own built-in alias for `pr checkout`),
   `gh issue delete 5`, an interposed unrecognized global flag shifting the subcommand
   anchor — fell through to the generic per-argument scan and read as safe whenever no
   argument was an unresolved variable. This directly contradicted this doc's own
   pre-existing claim ("an unrecognized verb/flag combination ... is treated as
   write-shaped (reaching), never assumed safe") for the verb-level case: that
   sentence was true only for the argument-scan path, never enforced at the verb
   level itself. Fixed with one shared resolver, `ghReachesOutright()`, called once
   from the `gh` dispatch site: any `b1:b2` subcommand pair not positively listed in
   `GH_READ_VERB_PAIRS` (and not `api`/`search`/`auth status`, which keep their
   existing separately-nuanced dispatch) is write-shaped and reaches outright,
   independent of whether any argument is a variable — closing `gh co 123` with zero
   preconditions and superseding the old two-verb hardcoded check. The refuted
   finding #6 (an interposed *unrecognized* global flag also shifts the subcommand
   anchor, but real `gh` rejects a truly unrecognized global flag before ever reaching
   the subcommand, so it is not independently exploitable with real `gh` invocations)
   is addressed as a side effect of this same fix rather than fixed on its own —
   recorded as checked-and-cleared, not dropped, since finding #3 demonstrates the
   identical gap with zero preconditions.
4. **Finding #4 (P2).** `SEGMENT_HEAD_KEYWORDS` (the `do`/`then`/etc. loop/if-keyword
   strip) was quote-insensitive: `"do" echo $SECRET_PATH` — a real command literally
   named `do`, quoted — was stripped as if it were the unquoted loop keyword, so the
   `echo` behind it was analyzed as the segment's own head and the unresolved `$VAR`
   argument was missed. The in-code comment asserting this strip only applies to a
   genuinely unquoted keyword was false as shipped; both the code and the comment are
   now fixed to only strip a token that is genuinely unquoted. Real loop/if syntax
   (`for n in 1 2; do gh pr view $n; done`) keeps stripping as before.
5. **Finding #5 (P3, this doc).** The no-path variables bullet above still listed
   `test`, `[`, `[[`, and `date` in the output-only no-path set after an earlier round
   (53e1c8a/dfc75de) had already removed them (file-test operators and `date -f FILE`
   reading a path as data); corrected above to the shipped
   twelve-member `OUTPUT_ONLY_COMMANDS` set. The gh-mutation-fails-closed claim in the
   round-2 section above is re-verified accurate as of finding #3's fix in this round
   (previously true only for the argument-scan path, as finding #3 showed) and no
   other stale claims were found on this pass.

Verification: `node --test hooks/tests/shape-rewrite.test.js` 142/142 (135
baseline + 7 new, one per finding-or-pairing above except #5, which is a doc-only
fix); `bash hooks/tests/run.sh` 715/715. Re-measured against the same 470-record
snapshot: 93/470 (19.8%) rewritable, down from 96/470 (20.4%) — a drop of 3, entirely
attributable to finding #3/#6's fix reclassifying 11 real write-verb calls (`gh issue
close`, `gh issue comment`, `gh issue create`, `gh pr merge`, `gh pr create`, `gh pr
close`) that were previously split between REWRITABLE (3 records) and
`reach:variable_in_argument` (8 records) into the new `reach:other_cmd_outright(gh
<verb>)` categories; the DETECTED SHAPE TALLY is byte-identical before and after,
confirming `detectShapes()` is unaffected. Findings #1, #2, and #4 show zero effect on
this corpus — a genuine null result, not a failure: none of the 470 mined records
happen to contain a piped-bare-shell, bare-`$VAR`-`gh api`, or quoted-`do`/`then`
pattern; their correctness is independently proven by the red/green unit-test evidence
in `shape-rewrite.test.js`, not by this metric. Per this doc's own standing direction,
stricter is the correct outcome even though it lowers the coverage share.

A bug in `excludeHeredocBodies()` was flagged here as deferred and framed as
"unrelated to finding #1's repro" — that framing did not hold up. Round 5's
adversarial review (finding #5, addendum below) proved it live-exploitable on its
own: any heredoc immediately followed (next line, no chain operator) by a
write-shaped command reached `reachesWithin()` fused into one unparseable word
(`cat <<EOF\nbody\nEOF\ngh pr merge 123 --squash` excluded to the single token
`"cat <<EOFgh pr merge 123 --squash"`), so the trailing dangerous command was
invisible to the reach check while the rewritten script still executed it verbatim.
Fixed in round 5; see the addendum below for the general rule applied and
verification evidence.

**Addendum, 2026-09-21 (round 5 of PR #1295's adversarial-first review).** Six
findings, all fixed; two further items were raised and dismissed as non-findings in
the same round, but with unequal footing. This doc's own status as an
actively-consulted reference held up and is not revisited here. The second — a
self-certification concern against a PR that is explicitly mid-flight and
independently re-reviewed each round — was dismissed at the time with **no cited
revision, verifier, or artifact**, which does not meet this same doc's own standing
bar ("work is closed by an independent verifier citing evidence at an exact
revision"). Round 8 raised the identical concern again and it was fair on its face:
across rounds 1-7 this PR carries exactly one PR-level comment, everything else is
commit prose and doc addenda from the same committer.

It is now addressed, honestly and only in part, by PR #1295 comment
`issuecomment-5771521912` (2026-09-22T05:11:19Z) — a coordinator verification record
naming exactly what was independently re-executed at `e76514d`: CI run 35686827092
(green, all four jobs), `hooks/tests/shape-rewrite.test.js` at 152/152,
`bash hooks/tests/run.sh` at 725/725, and a live before/after timing
re-measurement of round-7 finding #2 (`bash -ccc…!` and `ln -sss…!` at n=160000,
milliseconds post-fix versus seconds pre-fix). That same comment discloses, just as
explicitly, what it did **not** independently verify: round-7 finding #3's four doc
corrections (read, not re-derived) and the 200,026-case differential fuzz behind
finding #2's equivalence claim, which was not committed at the time — a bounded,
committed replacement ships in this PR's round-8 fix (see the PR body's round-8
section for the exact test and its red/green evidence). Rounds 1-4's claims are
outside that comment's scope entirely and remain unverified by anyone but the
committer. The underlying self-certification condition is not resolved by this: every
round's fixes, and this doc's own corrections, are still authored and adjudicated by
the same coordinator identity that opened the PR, with no separately-provenanced
reviewer account attached to any of it. That gap is stated here as open, not closed by
this paragraph or by the comment it cites.

Common thread across findings #1-#3, named directly per this round's own
instruction: each guard checked only the syntactically simplest/most-privileged
spelling of the dangerous shape and was defeated by an equivalent form carrying
the identical payload. The general rule applied in every one of the three: classify
by the semantic category the guard actually cares about (an argument unresolvable
at static-analysis time; stdin that IS the script being executed; a segment whose
stdin comes from a preceding pipe) rather than by the one lexical spelling the
original exploit happened to use — so a fourth or fifth variant of the same
category is covered for free, not by another special case.

1. **Finding #1 (P1).** `ghApiIsReadOnly()`'s per-argument scan resolved a
   `$(...)`-substitution-bearing flag word (`--$(echo field)=x`) to `null` via
   `litAt()` and then `continue`d past it — treating an unresolvable flag as
   absent rather than as write-shaped, the same gap round 4's finding #2 had
   already closed for a bare `$VAR`/`${VAR}` word in the identical position, just
   not for the command-substitution spelling of "unresolvable." Fixed by checking
   `wordHasDynamic(w)` up front for every word in the scan and failing closed (not
   read-only) on any dynamic content — generalizing the bare-variable special
   case to the full unresolvable-argument surface instead of adding a second
   one-syntax carve-out.
2. **Finding #2 (P1).** The piped-stdin default-deny (round 3 finding #1) proved a
   real script-file argument was present by checking for any non-flag word — but
   `/dev/stdin` (and `/dev/fd/0`, `/proc/self/fd/0`) IS the piped stdin, just
   spelled as an operand, and was independently allowlisted in `DEVICE_ALLOW`
   besides. `bash /dev/stdin`/`python3 /dev/stdin` fed via a real pipe passed the
   "has an operand" test and skipped the piped-stdin reach check entirely. Fixed
   with a shared `STDIN_ALIAS_PATHS` set threaded into every `hasNonFlagOperand`
   computation (`hasBareExecShape`, `reachesWithin`, and the corresponding
   shape-detection site — three independent copies of this check, all three
   fixed together): a stdin-alias path no longer counts as a "real" operand.
3. **Finding #3 (P1), same defect class as finding #2.** `segment()`'s
   `curPipedStdin` tracking unconditionally reset to `e.value === '|'` on every
   `SHELL_CHAIN_OPS` transition, including `(`/`)` — themselves chain-op members
   for segmentation purposes but structurally transparent grouping punctuation,
   not a fresh command boundary. `cmd | (bash)` clobbered the just-set
   `pipedStdin=true` back to `false` the instant it saw `(`, so the wrapped `bash`
   segment evaluated as if it started fresh. Fixed with `TRANSPARENT_GROUPING_OPS
   = new Set(['(', ')'])`: segmentation still splits on these, but the
   `curPipedStdin` reassignment is skipped for them, so a piped-stdin signal now
   survives being wrapped in one or more transparent subshell groups.
4. **Finding #4 (P2).** `run()`'s `if (!shapes.length) return rawInput;`
   short-circuited before `reaches()` ever ran, and `detectShapes()` returned `[]`
   for every one of the PR's own motivating standalone examples (`cat <<'EOF' |
   bash`, bare `echo '...' | bash`/`| python3`, `ssh host <<'EOF'`, `psql
   <<'EOF'`, `bash -s <<'EOF'`) — so the round-3/4 default-deny protections were
   unreachable through the real hook entry point for exactly the cases used as
   their own live-red evidence, even though the unit tests (calling
   `reaches()`/`detectShapes()` directly) stayed green. Fixed by adding a new
   detection-only shape, `hasBareExecShape()` (contributes `'bareexec'` to
   `detectShapes()`'s output, never itself a reach decision), covering three
   rules: (a) piped stdin into a shell/interpreter with no other real operand,
   (b) a shell segment carrying its own heredoc redirect, (c) a non-shell/
   interpreter segment with a quoted heredoc that isn't a recognized safe data
   sink (`cat`/`tee`/`OUTPUT_ONLY_COMMANDS`). `shapes.length` is now non-zero for
   all six motivating forms, so `reaches()` actually runs and classifies each one
   (verified: every one reads back as reaching, via reachesWithin()'s own
   pre-existing, unchanged logic). Checked empirically rather than assumed:
   `run()`'s own pass/reject action for these six commands is unchanged either
   way, before and after this fix — `reachesWithin()` judges every
   `hasBareExecShape`-covered form as reaching *unconditionally* (none of the
   six is path-dependent), and this hook only ever rewrites a command that does
   **not** reach into an audited script, leaving anything that reaches as
   pass-through either way. So this fix is not a changed outcome for these six
   commands; it closes a dead-code gap in the reach-check pipeline itself — a
   prerequisite for `reaches()` to run at all here, and for any future,
   possibly path-conditional, addition to `reachesWithin()`'s rules for these
   shapes to actually take effect through the real entry point instead of
   silently no-op'ing behind `shapes.length === 0` the way it did before.
5. **Finding #5 (P1).** Documented above and in this addendum's lead-in
   correction: `excludeHeredocBodies()` fused the kept text before and after a
   heredoc's body with no separator, silently gluing a trailing write-shaped
   command onto the heredoc's own opening line as one unparseable word. Fixed by
   cutting at `sameLineEnd + 1` (keeping the newline) instead of `sameLineEnd` —
   the general form: a body-exclusion transform must never drop the token
   separator living at the exact position it drops the body.
6. **Finding #6 (P2).** `hasInterpStdinShape()` (new in round 4) did a
   from-scratch backward retokenization per quoted heredoc with no bound other
   than distance to the previous chain operator — O(n^2) in heredoc count
   (measured on the unfixed code: n=500/2000/8000 heredocs at 83ms/732ms/5.33s).
   Fixed with a two-part general rule. (a) A forward pass computes each heredoc's
   shared-segment start once; heredocs sharing a segment are then processed as
   one group with incremental delta-tokenization between them, advancing the
   outer loop to the group's end unconditionally rather than to wherever an inner
   early-exit happened to stop (the first-draft fix under-advanced here, silently
   reproducing the same O(n^2) cost as "many one-heredoc groups" — caught and
   fixed before this round closed, not shipped). (b) Fixing (a) exposed a second,
   independent, pre-existing bug in `findHeredocs()` itself, not one of the
   original six findings: heredocs sharing one operator line (`cmd <<'A' <<'B'`)
   each recomputed their body-search start from the shared line's end, forcing
   heredoc *i* to re-walk all `2*i` prior body+delimiter lines to reach its own
   terminator — still O(n^2), and the actual remaining bottleneck after (a)
   (stage timing at n=8000: `findHeredocs` 560ms of 597ms total,
   `hasInterpStdinShape` 3ms) — and a correctness defect in its own right: an
   earlier heredoc's true body containing a line matching a later heredoc's
   delimiter text corrupted the later heredoc's parsed boundary (`skipTo`) so it
   landed BEFORE the earlier heredoc's own boundary, a structurally invalid,
   overlapping parse that `excludeHeredocBodies()` and every downstream reach
   check rely on being correctly ordered (confirmed: old code gave `skipTo` pair
   `(43, 29)`, new code `(43, 60)`). Fixed with a running `nextBodyStart` pointer
   (`bodyStart = Math.max(firstNl + 1, nextBodyStart)`, updated to each heredoc's
   own `skipTo` once resolved) so each heredoc's search starts where the previous
   one actually ended. Root-caused and fixed per this repo's own "no band-aid
   patches" rule rather than leaving a second silent quadratic sink in the same
   feature area while reporting finding #6 as closed.

Verification: fresh red(pre-round-5)/green(fixed) differential evidence for
all six findings, built from a correctly-isolated pre-round-5 snapshot (both
`shape-rewrite.js` and `shape-rewrite-reach.js` read via `git show
HEAD:<path>`, since both are uncommitted working-tree modifications against
`2f86203` — an earlier snapshot's `lib/` was a symlink to the already-fixed
live tree and could not have exercised the pre-fix `ghApiIsReadOnly()`, so
was rebuilt). `node --test hooks/tests/shape-rewrite.test.js`:
152/152 (142 baseline + 10 new, all round-5). `bash hooks/tests/run.sh`:
725/725 (715 baseline + 10 new). Coverage on the 470-record mined
full-command corpus (`node /home/user/.claude/jobs/145e3a7e/tmp/cov3.js`,
live worktree code, vs. the same script pointed at the pre-round-5 snapshot):
REWRITABLE 93→89 (−4), NOT_DETECTED 111→107 (−4), reach:* 266→274 (+8) —
the direction is correct: fewer commands are mislabeled safe-to-rewrite or
invisible, not more capable. Per-command diff against all 470 records
(not just the aggregate tally) confirms exactly 8 moved and attributes each:
4 NOT_DETECTED→reach are finding #4 (`bash -s <<heredoc>>` rule (b); quoted
heredoc into `git`/`ssh` rule (c)); 4 REWRITABLE→reach are finding #5
(heredoc-immediately-followed-by-another-command glue, revealing a
previously-hidden trailing reference this hook treats as reaching). Findings
#1/#2/#3/#6 did not fire on this particular mined corpus (no `gh api`
$()-obfuscation, `/dev/stdin`, subshell-wrapped pipe, or adversarially-sized
heredoc stack among these 470 real records) — their fresh red/green evidence
is the synthetic differential above, not this corpus. Two bugs disclosed per
this round's own honesty requirement: a self-introduced `hasInterpStdinShape`
grouping regression (introduced mid-fix, caught, fixed before commit) and the
`findHeredocs` shared-segment body-boundary bug (pre-existing, found not
introduced, fixed) — the latter's severity is higher than a first pass
suggested: beyond corrupting the internal `skipTo` pair, it fully masked a
live piped-`bash` exploit through the public `detectShapes()`/`reaches()` API
(`[]`/`null`) until fixed.

**Addendum, 2026-09-21 (round 6 of PR #1295's adversarial-first review).** Four more
findings, all fixed or resolved:

1. **Finding #1 (P1).** The interp carve-out's heredoc-body denylist
   (`HEREDOC_BODY_LITERAL_DENY` family in `hooks/lib/shape-rewrite-reach.js`,
   reached via `heredocBodyReaches()`) — kept since round 1 as "a literal tripwire, not
   a containment proof" per the round-3 addendum above — was live-reproduced as
   bypassable: 2 of 3 constructed payloads (a `chr()`-built path string, a
   `getattr(os, 'sys' + 'tem')` dynamic dispatch) evaded every denylist entry with zero
   denylisted literal ever appearing in the source text. A denylist/pattern scan over a
   Turing-complete language's raw source text cannot be made sound against composed or
   computed constructions — the identical class of evasion the shell reach check
   already accepts for other unresolvable dynamic content, but here it undermined the
   carve-out's own stated justification. **Reverted outright**, per the reviewer's own
   instruction to choose revert unless a sound, non-enumerative gate could be
   articulated — none could: any heredoc-fed interpreter
   (`python3`/`python`/`node`/`perl`/`ruby` `- <<...`) now reaches unconditionally,
   exactly like the pre-round-1 default. The entire heredoc-body-denylist family
   (`HEREDOC_BODY_LITERAL_DENY`, `HEREDOC_BODY_DENY_PATH_PREFIXES`,
   `normalizeHeredocPathToken`, `heredocBodyHasOutsidePath`, `heredocBodyReaches`) is
   removed rather than left as dead code gating a carve-out that no longer exists. New
   red-then-green exploit tests use computed-at-runtime payloads (character-code-built
   strings, `getattr`-based dispatch), not just literal reproductions.
2. **Finding #2 (P2).** `shape-rewrite.js` had no internal execution-time budget
   despite two prior rounds (round 4/round 5, finding #6 above) fixing O(n^2) parsing
   sinks in this same file — nothing backstopped a *future* regression from running
   unchecked into the hook's external 5000ms CLI timeout (a timed-out PreToolUse
   command hook fails OPEN, not closed: the call proceeds unblocked). Mirrors
   `fanout-admission.js`'s (PR #1294) own `ANALYSIS_BUDGET_MS`/`AnalysisBudgetExceeded`/
   deadline-threading pattern rather than inventing a new one: one internal budget
   (`CLAUDE_SHAPE_REWRITE_BUDGET_MS`, default 2500ms), threaded through `findHeredocs`,
   `hasInterpStdinShape`, `hasBareExecShape`, and `reachesWithin`'s recursion and
   per-segment loops, throws once exceeded and is caught at the two public entry points
   (`detectShapes`, `reaches`), each returning its own fail-closed result (`[]`, and a
   reaching-outright reason respectively) rather than letting the process run
   unbounded. `run()` computes ONE shared deadline and passes it to both
   `detectShapes()` and `reaches()`, so total wall-clock stays bounded by one budget
   instead of up to 2x. A direct caller that omits the deadline (every existing test)
   still gets its own fresh default budget — non-breaking.
3. **Finding #3 (P2).** The same `hasNonFlagOperand`-shaped predicate was written
   three times independently (two call sites in `shape-rewrite.js`, one in the interp
   carve-out). Extracted into one shared `toLiteralTokens`/`hasNonFlagOperand` pair in
   `hooks/lib/shape-rewrite-reach.js`, exported and used by all three call
   sites — the same pattern this PR already used for round 3's
   `isInterpStdinArgShape()` unification (finding #12) and round 3's family extraction
   (finding #8).
4. **Finding #4 (P3, this doc).** Every round's coverage percentage above was produced
   by a script (`cov.js`/`cov2.js`/`cov3.js` across rounds) reading a 470-record corpus
   at ephemeral paths (`/home/user/.claude/jobs/<job-id>/tmp/`,
   `/tmp/pc-cov-<job-id>/full.json`) — neither committed to this repository, so none of
   those percentages are independently reproducible by a later reader. **Resolved by
   NOT committing the script or corpus** (option (b) of the two offered, not (a)), for
   two independent reasons: the corpus is real command records mined from live session
   transcripts across the fleet (real repo names, real internal paths, real business
   content) — appropriate as one-off job scratch, not appropriate to commit into
   permanent git history as a test fixture; and this repo's own anti-ceremony doctrine
   gates creating a tracked process artifact on naming a concrete consumer whose
   running code branches on it — a coverage percentage read only by a human in a
   markdown doc does not clear that bar. The durable, reproducible proof for this and
   every prior round remains the tracked unit-test suite, cited below. This round's
   aggregate numbers are reported once more below, using the still-present (as of this
   writing) ephemeral `cov3.js`/corpus, explicitly as a final, non-reproducible
   cross-check rather than a durable metric — no future round should cite a new
   coverage percentage without first re-litigating this finding.

Verification: `node --test hooks/tests/shape-rewrite.test.js` 149/149 (152
baseline; finding #1's revert required removing ~15 carve-out-mechanism-specific tests
and rewriting/flipping ~6 more whose expected outcome depended on the now-removed
carve-out, plus 3 new computed-payload exploit tests, netting 147 before finding #2's
2 new budget tests brought the file to 149 — see the PR body's round-6 section for the
itemized list). `bash hooks/tests/run.sh` 722/722 (725 baseline, same net -3
delta). Coverage (ephemeral `cov3.js`, final measurement, not reproducible after this
round): REWRITABLE 89→69 (−20), NOT_DETECTED 107→107 (unchanged — shape *detection*,
untouched by findings #1-#3, is not the same thing as the reach *decision* that
changed), reach:* 274→294 (+20) — the entire drop is attributable to finding #1's
revert: every one of the 76 interp-shaped records that used to pass through the
denylist carve-out (whether the denylist happened to catch it or not is now moot)
reaches unconditionally instead. Direction is correct per this doc's own standing
rule: stricter is the correct outcome even though it lowers the coverage share.


### Mechanism (from the v2.1.243 bundle; behavior above is the authority)

Every command is parsed; a parse of any kind other than "simple" → immediate too-complex
refusal. The parser has dozens of bailouts (command substitution, expansions with
modifiers, heredoc/redirect subtleties, exotic assignments, zsh syntax, brace expansion,
control characters). "Simple" parses carry a command **list** — chains and pipes are
analyzed member-wise, which is why plain `&&`/`;`/pipe compositions pass. Surviving
commands then get git-specific checks: env/`-C`/`--chdir` pins resolved against the
worktree, launcher-before-git, glob-spelled git, more than one `git` in a single command.
Unparseable input fails open to an empty simple parse — do not build on that.

Two scope limits the bundle reading alone would have gotten wrong, both settled by probe:
the **launcher-before-git check does not reach into `-c` string payloads** (`bash -c "git
status"` runs), and **assignment values are not analyzed at all** (`P=$(pwd) printenv P`
runs while `echo $(date)` does not).

This verifier is also not the only guard in the path. `git add -A` in this session was
refused by the local git-guard hook, not by isolation; dcg independently blocks dynamic
and `$HOME` redirect targets. A command that passes here can still be stopped by those,
and the messages look nothing alike — read which guard spoke before rewriting anything.

## Documented semantics and knobs (researched 2026-08-27, claude-code-guide agent)

What the official docs and issue tracker add on top of the probes:

- **"You can't turn this check off."** — verbatim from the worktree-isolation
  enforcement docs (code.claude.com/docs/en/worktrees). The check covers Bash, PowerShell
  and Monitor, in every isolated session type (`--worktree`, EnterWorktree, resume,
  subagent isolation, background sessions). Documented remediation is exactly the denial
  message's: split into plain, separate commands. No grammar or allowlist is published.
- **Hooks and bypass mode do not skip it**: a maintainer reproduction on
  anthropics/claude-code#84258 (v2.1.233) confirms PreToolUse `permissionDecision:
  "allow"` and `--dangerously-skip-permissions` still hit the block — it is an
  execution-time boundary below the permission layer. Matches our fleet measurement
  `pretooluse-hooks-survive-bypass-permissions`.
- **`worktree.symlinkDirectories: ["node_modules"]`** (settings.json) is the documented
  way to reuse dependencies in fresh worktrees (maintainer answer on
  anthropics/claude-code#60113). It addresses setup cost, not command verification.
- **`worktree.bgIsolation: "none"` is the one real off switch, and it works by removing
  the isolation, not by relaxing the check.** Read out of the 2.1.243 bundle's own
  settings schema: `bgIsolation` accepts `"worktree" | "none"` and is described as
  *"Isolation mode for background sessions in this repo. 'worktree' (default) blocks
  Edit/Write in the main checkout until EnterWorktree is called. 'none' lets background
  jobs edit the working copy directly."* With `"none"` a background session never enters
  a worktree, so the command verifier never applies — the session is told to skip
  EnterWorktree and work in place. Two things the public docs do not mention: the
  resolution order is **`CLAUDE_BG_ISOLATION` env var → the session record →
  `worktree.bgIsolation` in settings**, so an env var overrides the repo setting; and
  managed settings can pin this key with restrictive value `"worktree"`, which is how an
  operator forecloses the escape fleet-wide. Setting it to `"none"` is a security-posture
  change, operator-only — never set it as a workaround (see Forbidden workarounds).
- **Changelog scan v2.1.198→v2.1.247 (latest)** — scoped to what shipped in those
  releases, not a claim about configuration generally: no relaxation of the shape rules,
  no published grammar or allowlist, no pnpm/npx special case. Relevant hardenings: 2.1.216 (git
  `-C`/`--git-dir`/`GIT_DIR`/`GIT_WORK_TREE` redirects), 2.1.217 (symlinked-cwd
  canonicalization), 2.1.222 (isolation applies to file edits + Bash in all session
  types; auto-allow-hook bypass fixed), 2.1.238 (misleading refusal message fixed).
- **No public issue covers the package-manager-script refusal** as of 2026-08-27 — #60113
  is about missing node_modules, #84258 about hooks/bypass. The upstream feedback below
  is not yet filed by anyone.

## Ceremony Test (required of any new process artifact — evidence-regime section 1)

- **Consumer:** any agent in a worktree-isolated session, reached through the one
  `CLAUDE.md` Global Rules bullet that links here. Not a human-read-only doc.
- **Defect it exists for:** 7,109 refusals / 192 sessions / 30d, the fleet's #1 bash
  friction, each one a wasted retry round-trip; worst recorded outcome is work reported
  "complete but unverified" when an agent concluded its gates could not run.
- **Gate:** the verifier is inside the CLI, so no local hook can enforce shape — but one
  can pre-empt it. Since 2026-09 `hooks/PreToolUse/shape-rewrite.js` (registered
  last in the Bash chain) rewrites a "too complex to verify" call into `bash <script>`
  under the session's scratch directory after a reach check that refuses whatever it
  cannot bound statically to the worktree and scratch areas — git, a `cd` other than a literal absolute path inside those roots (whose target then also anchors every relative path), an outside
  path, an opaque construct (inline interpreters, `eval`, `xargs`, `find -exec`,
  `awk`/`sed` scripts, symlink creation), a wrapper prefix carrying an unrecognized
  option, a variable or expression it can't resolve on a path-capable command, a
  literal argument that canonicalizes outside the allowed roots (a symlink counts), or
  a reaching command name appearing anywhere in a segment rather than only at its head;
  the two shared-checkout policy refusals are never rewritten. dotfiles#1273 narrowed
  three of these exclusions and carved out a fourth, since reverted: a `gh` read verb's
  argument is not path-capable, so a variable there doesn't count as unresolved, with
  the subcommand read from a fixed, global-flag-skipped position rather than scanned
  for anywhere in the argument list (round 2 of PR #1295's review); the output-only
  no-path command set grew to cover `tr` and a handful of other no-file-operand
  commands (no-path variables) — `jq`/`cut`/`sort`/`uniq`/`head`/`tail`/`wc` were tried
  and reverted before merge, since each takes a FILE operand a `$VAR` could smuggle
  outside the sandbox; and `NAME=$(…)` / `` NAME=`…` `` assignments are now detected as
  `cmdsub` and reach-checked like any other substitution instead of passing
  `detectShapes` unnoticed. The fourth — an interpreter's bare `-` fed by a
  **quoted**-delimiter heredoc treated as not-opaque PROVIDED the heredoc body also
  passed a host-reaching-literal denylist scan (round 2's `interp` shape carve-out) —
  was **reverted outright in round 6** of the same PR's review: a denylist scan over a
  Turing-complete language's raw source text cannot be made sound against composed or
  computed constructions (a `chr()`-built path and a `getattr`-based dynamic dispatch
  both evaded it with zero denylisted literal in the source text), so a bare `-` fed by
  ANY heredoc, quoted or not, to `python3`/`python`/`node`/`perl`/`ruby` is again
  unconditionally treated as reaching, restoring the pre-#1273 rule. Full
  discriminators and planted negatives for the three that remain, and the current
  `interp` rule: "`shape-rewrite.js` reach-check refinements" above. The script is
  written
  mode 0600, one file per call named `shape-rewrite-<shapes>-<tool_use_id>.sh`, and
  never overwritten — a pre-existing path at that name passes the call through
  unrewritten; each rewrite also prunes same-prefix files older than 24 hours from the
  same directory. The rewrite prints a `[shape-rewrite]` receipt as the first line of
  the tool result and is counted under `guard_blocked:shape-rewrite:<shapes>`, which
  papercut quarantines as an `advisory-rewrite` receipt (it shows under
  `papercut list --quarantined`, not in the ranked list); a
  rewritten call the verifier still refuses counts under
  `guard_blocked:shape-rewrite-refused:<shapes>`. It fails open: unknown isolation, no
  scratch directory, a reach, or any internal error leaves the call for the verifier
  exactly as before. `SHAPE_REWRITE_DISABLE=1` in the hook's own environment is the
  only switch; there is no per-call opt-out. Plan and rationale:
  `docs/plans/2026-09-20-2120-feat-rewrite-not-deny-hook-plan.md`.
- **Delete when:** the next 30-day counts (read as the friction record below says)
  show the family falling with the `shape-rewrite` signatures accounting for the
  difference and a near-zero
  `shape-rewrite-refused` count — then the always-on rule shrinks to a pointer here and
  the table becomes the hook's test fixture — **or** a CC release fixes the false
  positives and the table stops matching behavior. A rising `shape-rewrite-refused`
  count means the detector is out of step with the CLI, not that the family is fixed.
  Either way this doc gets retired or rewritten, not left standing as decoration.
- **Friction record:** the `worktree-isolation-unverifiable` family stays *escalated* to
  the upstream verifier issue, with a note naming this hook as the local remedy
  (`papercut family show worktree-isolation-unverifiable`); it is deliberately not
  adopted. A target-prefix claim would be blind — Bash failure records carry no target,
  and a scoped record without a target never counts (`member_record` in the papercut
  CLI, fail-closed) — and a plain claim would read `regressed` at the first opaque
  command the fail-open hook declines, by design. The retirement test above therefore
  reads counts, never the family's verification stage: the `shape-rewrite` receipts
  from `papercut list --quarantined --days 30 --json`, and `shape-rewrite-refused` and
  the family's member signatures (named by `papercut family show
  worktree-isolation-unverifiable --json`; `list` has no family row) from
  `papercut list --days 30 --json` (the text view stops at `--limit`, 30 rows by
  default).

## Doctrine: substitute tools, never escape the guard

1. **File content → Write/Edit tool**, not heredocs or `echo >` chains. If a heredoc is
   truly needed for a throwaway shell script, quote the delimiter (`<<'EOF'`).
2. **Runtime values → separate commands.** Run the producing command, read its output,
   then issue the next command with the value inlined as a literal. No `$( )`, no
   backticks, no `${VAR:-default}`/`${VAR%…}` modifiers, no loop bodies that use the loop
   variable — unroll short loops into explicit commands.
3. **Repo quality gates → the repo's own verify script, then direct bin files** — never
   the package-manager wrapper. Provenance: steps 1 and 2 below are **field results from
   a private pnpm workspace on 2026-08-27, not re-probed in this matrix** (memory notes
   `use-claude-verify-sh-not-bare-pnpm` and `pnpm-is-blocked-in-worktree-isolated-sessions`).
   What this matrix independently establishes is only the shape: a plain in-worktree
   script path passes (`./scripts/work-spec-check.sh --help`), `bash <script file>`
   passes, `python3 <script file>` passes, and `node --version` passes. In order:
   1. `bash .claude/verify.sh` (or the repo's equivalent wrapper script). Plain
      in-worktree script invocation passes, and it ran turbo typecheck where every pnpm
      form was refused. Look for the repo's sanctioned wrapper before concluding a
      capability is missing.
   2. `node <path-to-bin-file>` — resolve the package path with
      `node -e "console.log(require.resolve('<pkg>/package.json'))"` and invoke the bin
      file directly; this ran tsc, tsx, eslint, and velite. **`./node_modules/.bin/X`
      does NOT work in a pnpm workspace** — the `.bin` entry is a symlink that resolves
      outside the worktree and is refused, even though a plain in-worktree script
      (`./scripts/x.sh`, probed PASS here) is fine. The symlink target is the
      difference.
   3. CI-first with compensating checks, saying plainly that local gates did not run.
   Field-reported extra denials in pnpm workspaces (not re-probed here): any pipe
   attached to a pnpm command, and a grep whose pattern contains the word "hash" (git-op
   heuristic — shorten the pattern).
4. **Git stays bare or worktree-pinned**: `git status`, `git -C <abs worktree path> …`,
   and worktree-targeted chains all pass. Never `-C`/`cd` to the shared checkout.
5. **Scratch redirects → literal `/tmp/<unique-dir>/` paths.** dcg refuses a truncating
   `>` to any target it cannot resolve before the shell runs. As of dcg 0.15.3 a
   variable resolves from a literal `/tmp` assignment, from a variable built on one
   (`F="$D/x"`), or from `$(mktemp -d /tmp/…)`, including after `&&` and with `$$` in
   the path: `S=/tmp/d; mkdir -p "$S" && cmd > "$S/out" 2>&1` and
   `mkdir -p /tmp/d && S=/tmp/d && cmd > "$S/out"` both pass. Still refused: a loop
   variable (even over literal words), a `2> file` next to the variable target (`2>&1`
   is fine), an assignment behind `||`, any other `$( )` value, a mktemp template or
   `-p`/`--tmpdir` outside `/tmp`, `..` out of `/tmp`, and anything under `$HOME`. New
   in 0.15.3: an assignment dcg cannot model between the `/tmp` assignment and the
   redirect (`S=/tmp/d; N=$(python3 -c …); cmd > "$S/out"`) ends the proof, so redirect
   before it. Append (`>>`) passes. For loops, use item 6.
   `scripts/dcg-contract/` pins the passing forms, and the refusals that must
   hold in any release (unresolved, non-`/tmp`, a loop over words read at run time,
   `$HOME` targets). The literal-word-loop and `2> file` refusals are 0.15.3 limits,
   left unpinned so a release that lifts them can still be promoted.
6. **Anything genuinely multi-step → put it in a script file and run the file.** A script's
   own loops, `$( )` and redirects are never parsed; only the invoking command is
   (`bash /abs/path/runner.sh` — verified PASS, and how the 52-suite local test run in this
   PR was executed).
   Be honest about what that is: **the verifier does not inspect script contents**, so this
   is a trust-and-provenance policy, not a verified-safe shape. The line it draws is that
   the work sits in a readable file the operator can inspect and review, rather than in a
   `bash -c` string that exists only inside one command's argv. **Never put a
   shared-checkout `git -C`, a `cd` out of the worktree, or any command you could not run
   directly into a script to get it past the check** — that is the `bash -c` hole wearing
   a filename, and it is the same violation.

**Forbidden workarounds** — these weaken isolation instead of fixing the shape, and the
planted-negative on issue #534 makes prescribing any of them a review failure:

- `bash -c "git …"` string payloads. Probed: `bash -c "git status --short"` **passes** on
  2.1.243 because launcher payload strings are not analyzed. That is an isolation hole,
  not a feature — never use `-c` strings to smuggle an unverifiable or shared-checkout
  command past the check. (Running a repo's own in-worktree script — `bash
  .claude/verify.sh` — is not this hole: that is versioned worktree content doing repo
  work in place, the activity the verifier exists to permit.)
- Running the command from the shared checkout instead, `dangerouslyDisableSandbox`, any
  `ALLOW_*` escape, or editing the permission surface.
- **Turning the isolation itself off** — `"worktree": {"bgIsolation": "none"}` in
  settings, or `CLAUDE_BG_ISOLATION=none` in the environment. This is the one thing that
  genuinely stops the refusals, which is exactly why it is listed here: it stops them by
  letting background jobs write the shared checkout directly, discarding the isolation
  the whole worktree doctrine is built on. An agent that hits enough of these refusals
  will find this setting; the answer is that the friction is the price of the guarantee,
  and only the operator changes that trade.

## Bookkeeping

- **15 denial events on 2026-08-27** under the dotfiles worktree slug
  (`-home-user-hov-stack--claude-worktrees-worktree-command-shapes`) are this
  investigation's own probes, not organic friction. Subtract them from any 30-day rollup
  read before ~2026-09-26: the comparison baseline of 7,109 events / 192 sessions was
  taken *before* these probes ran, so an unadjusted next-rollup read is inflated by 15
  events in 1 session (0.2% — small, but the follow-up check below is a difference of
  measurements, so state the adjustment rather than assume it rounds away).
- **Follow-up check:** at the next monthly papercut review (~2026-09-27), run
  `papercut family` for the "too complex to verify" family over 30 days and compare the
  event and session counts against the 7,109 / 192 baseline, minus the 15/1 probe
  adjustment above. The doctrine line ships in CLAUDE.md the same day as this doc, so the
  window is clean. **Success = events per isolated session down by a third or more**;
  normalize by isolated-session count (fleet volume drifts), and check the CC version
  first — a release that fixes the false positives would move the number for reasons that
  have nothing to do with this doc, so record the version alongside the count.
  Falsification: no material fall means the doctrine did not work, and this doc should be
  rewritten or retired rather than kept as decoration — the guard is unpatchable here, so
  a doc that does not move the number has no other value.
  Precedent: the `/tmp/<unique-dir>/` scratch line collapsed the previous #1 cluster
  (51 sessions/wk).
- Demoted from `CLAUDE.md` (2026-09-21, dotfiles#1286): "(Fleet's #1 denial
  cluster, 51 sessions/wk, before this line — 2026-08.)"
- Verifier behavior is version-bound: re-probe the deny rows on major CC upgrades before
  trusting this table (the bundle is closed; nothing pins these semantics).

## Upstream feedback (draft for the operator — never auto-posted)

For anthropics/claude-code, three observations from the 2.1.243 probes. None of the three
is on the public tracker as of 2026-08-27 (#60113 covers worktree node_modules setup,
#84258 covers hooks/bypass not skipping the check — nothing covers the script-shape
refusal itself):

> Routing caveat: the repo's issue page rendered "Issue creation is restricted in this
> repository" when checked on 2026-08-27, so a new issue may not be fileable. The REST API
> still reports issues enabled (15,223 open) and `interaction-limits` needs admin rights to
> read, so this is a page observation, not a confirmed setting. If filing is blocked, `/bug`
> from inside Claude Code is the route that does not depend on it.

1. **Inconsistent launcher modeling:** `pnpm typecheck` is refused as unverifiable while
   `bash -c "git status"` runs unanalyzed. The first blocks every repo's quality gates in
   isolated sessions (the guard's own advice — "split it into plain, separate commands" —
   cannot express "run tsc"); the second is a payload-smuggling hole that defeats the
   git-redirect checks the verifier does perform.
2. **High-frequency false-positive shapes:** `${VAR:-default}` and read-only command
   substitution in argument position (`echo $(date)`) are everyday idioms with no path
   relevance — and the analyzer already accepts the *same* substitution as an assignment
   value (`P=$(pwd) printenv P` runs), so the refusal is positional rather than a judgment
   that the substitution is dangerous. At 7.1k events/30d on one fleet, extending the
   existing assignment-value tolerance to arguments whose substituted command is read-only
   would remove most of the friction without weakening the git-targeting checks.
3. **The `hash` token match is argument-position-blind:** `echo hash` and
   `grep -rn "hash" file` are both refused with "runs a string through hash". Matching the
   builtin only in command position — not as any argv element, and not inside a quoted
   search pattern — would fix a refusal that fires on ordinary code search in any repo
   whose code mentions hashes.
