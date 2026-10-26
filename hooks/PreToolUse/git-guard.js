#!/usr/bin/env node
/**
 * PreToolUse Hook: Git Safety Guard
 *
 * Blocks:
 *   1. Indiscriminate staging (git add . / -A / --all).
 *   2. commit/push directly on main/master (escape: ALLOW_MAIN_COMMIT=1).
 *   3. Destructive git commands that lose work or history — reset --hard,
 *      checkout -- <path>, restore <path>, push --force, push --delete/-d/:ref
 *      (remote branch deletion), push +refspec (bare force), clean -f,
 *      branch -D, stash drop/clear — each answered with a safer alternative
 *      (escape: ALLOW_DESTRUCTIVE_GIT=1). While a rebase is in progress the
 *      documented recovery commands (checkout -- / restore) are allowed
 *      automatically so the agent isn't trapped mid-rebase.
 *   4. `git config` writes that install code execution / persistence —
 *      core.hooksPath, core.fsmonitor, and `!`-shell aliases, plus their
 *      inline `git -c ...` equivalents (escape: ALLOW_GIT_CONFIG_EXEC=1).
 *      These are an arbitrary-exec vector, not a normal config write; reads
 *      (--get/--list/bare key) are left alone.
 *   5. AI attribution trailers written into a commit or merge message, or into
 *      a `gh pr|issue create|comment|edit` body (Co-Authored-By naming an
 *      assistant product or an assistant vendor address, in `:` or
 *      `--trailer key=value` form, or the Claude Code byline). The attribution
 *      settings only control what Claude Code appends itself; text copied from
 *      a prompt or template lands verbatim (escape: ALLOW_AI_TRAILER=1). Human
 *      co-authors pass. Out of reach by design: text that never appears
 *      literally in the Bash command — `-F <file>` / `--body-file` written
 *      earlier, `-m "$(cat file)"`, commit.template.
 *
 *   Every ALLOW_* escape is recognised as a real environment variable, as an
 *   env assignment leading a segment, or as an earlier `export` — never as a
 *   substring inside quoted text, a heredoc body or a comment (escapeLeads).
 *   Not a rule, by measurement: identity overrides (`-c user.*` on commit).
 *   60 days of transcripts hold 114 such commands, every one a deliberately
 *   scoped identity; a deny would fight the operator's own workflow (#840).
 *
 * Follows the run-with-flags.js pattern: exports run(rawInput) for
 * direct require() without spawning a child process.
 */

'use strict';

const { deny, allow, setDenyContext } = require('../lib/pretooluse-decision');
const { writeHookOutput } = require('../lib/hook-output');

// (indiscriminate-`add` matcher is defined below, after the reGit helper, so it
// reuses reGit's optional `-C <dir>` handling)

// Protected branch names
const PROTECTED_BRANCHES = new Set(['main', 'master']);

// `git` followed by any run of GLOBAL options before the subcommand: `-C <dir>`,
// `-c key=val`, `--git-dir`/`--work-tree`/`--namespace`/`--exec-path` (either
// `=` or space form), `--no-pager`, `-p`/`--paginate`, `--no-optional-locks`,
// `--literal-pathspecs`, `--bare`, `--no-replace-objects`. Tolerating only `-C`
// let `git -c commit.gpgsign=false commit` and `git --no-pager commit` walk past
// every subcommand rule, the commit-on-main rule included (2026-09-01 inward
// vet of #832). Only `-C` carries a cwd for the branch checks (extractCwd).
const GIT_OPT = String.raw`(?:-[Cc]\s+(?:"[^"]+"|'[^']+'|\S+)|-c\S+|--(?:git-dir|work-tree|namespace|exec-path|config-env|super-prefix)(?:=\S+|\s+(?:"[^"]+"|'[^']+'|\S+))|--(?:no-pager|paginate|no-optional-locks|literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-replace-objects|no-lazy-fetch|bare)|-p)`;
const GIT = String.raw`git\s+(?:` + GIT_OPT + String.raw`\s+)*`;
const reGit = (body) => new RegExp('^' + GIT + body);

// Stages everything indiscriminately. Confirms it is a `git [-C dir] add` (reGit),
// then flags the stage-all forms: `-A`/`--all` anywhere, or a whole-cwd pathspec
// (`.` or `./`, bare or after the `--` pathspec separator). Evaluated against the
// env-stripped command in run() so a `FOO=bar git add -A` prefix cannot slip past,
// and `-C`-aware so `git -C repo add -- .` is caught too. A specific `./path` (not
// the bare cwd) is intentionally allowed.
const isDangerousAdd = (c) => {
  if (!reGit(String.raw`add(?:\s|$)`).test(c)) return false;
  if (/(?:^|\s)(?:-A|--all)(?:\s|$)/.test(c)) return true;
  if (/(?:^|\s)(?:--\s+)?\.\/?(?:\s|$)/.test(c)) return true;
  return false;
};

// Split a `git push` command's argument list into refspec-shaped tokens:
// quote-aware, flags (leading `-`) dropped. `tokens[0]` is the remote when
// present; everything after is a refspec. Shared by the protected-branch
// refspec check (3a, below) and the destructive push rules in DESTRUCTIVE_GIT
// so all three read the same argument list instead of three independent
// parses drifting apart. Returns null if `command` isn't a `git push`.
function pushArgTokens(command) {
  const m = reGit(String.raw`push\b`).exec(command);
  if (!m) return null;
  return (command.slice(m[0].length).match(/(?:"[^"]*"|'[^']*'|\S)+/g) || [])
    .map((t) => t.replace(/^["']|["']$/g, ''))
    .filter((t) => !t.startsWith('-'));
}

// Destructive commands that discard work/history, each mapped to a safer form.
// `recoverable: true` marks the documented mid-rebase recovery path
// (checkout -- / restore), which is allowed while a rebase is in progress.
const DESTRUCTIVE_GIT = [
  {
    label: 'git reset --hard',
    danger: (c) => reGit(String.raw`reset\b`).test(c) && /\s--hard\b/.test(c),
    why: 'discards all uncommitted changes permanently',
    safe: 'git stash (recoverable)',
  },
  {
    label: 'git checkout -- <path>',
    danger: (c) => reGit(String.raw`checkout\s+(?:--(?:\s|$)|\.(?:\s|$))`).test(c),
    why: 'discards uncommitted changes to those files',
    safe: 'git stash push [path] (preserves changes)',
    recoverable: true,
  },
  {
    label: 'git restore <path>',
    danger: (c) =>
      reGit(String.raw`restore\b`).test(c) &&
      !(/--staged\b/.test(c) && !/--worktree\b/.test(c)),
    why: 'discards uncommitted worktree changes',
    safe: 'git stash push [path]',
    recoverable: true,
  },
  {
    label: 'git push --force',
    danger: (c) =>
      reGit(String.raw`push\b`).test(c) &&
      (/(?:^|\s)--force(?![-\w])/.test(c) || /(?:^|\s)-[a-z]*f[a-z]*\b/.test(c)),
    why: 'can overwrite commits pushed by others',
    safe: 'git push --force-with-lease (fails if the remote moved)',
  },
  {
    label: 'git push --delete/-d/:ref (remote branch deletion)',
    danger: (c) => {
      if (reGit(String.raw`push\b`).test(c) && /(?:^|\s)(?:--delete|-d)\b/.test(c)) return true;
      // Bare `:branch` refspec (empty source = "delete this ref on the remote"),
      // e.g. `git push origin :feature-x`. tokens[0] is the remote; everything
      // after is a refspec (same convention as 3a below).
      const tokens = pushArgTokens(c);
      return !!tokens && tokens.slice(1).some((t) => t.startsWith(':'));
    },
    why: 'deletes a branch on the remote for everyone who has not fetched yet',
    safe: 'gh pr merge --delete-branch (API-side, safe post-merge)',
  },
  {
    label: 'git push +refspec (bare force-push prefix)',
    danger: (c) => {
      const tokens = pushArgTokens(c);
      return !!tokens && tokens.slice(1).some((t) => t.startsWith('+'));
    },
    why: 'the leading `+` force-pushes that refspec regardless of --force, and can overwrite commits pushed by others',
    safe: 'git push --force-with-lease (fails if the remote moved), or drop the `+` prefix',
  },
  {
    label: 'git clean -f',
    danger: (c) =>
      reGit(String.raw`clean\b`).test(c) &&
      /(?:^|\s)-[a-z]*f[a-z]*\b/.test(c) &&
      !/(?:^|\s)-[a-z]*n[a-z]*\b/.test(c) &&
      !/--dry-run\b/.test(c),
    why: 'permanently deletes untracked files',
    safe: 'git clean -fdn (preview first)',
  },
  {
    label: 'git branch -D',
    danger: (c) => reGit(String.raw`branch\b`).test(c) && /(?:^|\s)-D\b/.test(c),
    why: 'force-deletes a branch even if it is unmerged',
    // Was `git branch -d (refuses unless merged)`, which sent the agent straight
    // into a second block: dcg denies -d as well (core.git:branch-force-delete,
    // deliberate — upstream #209), so the old advice had no working path behind
    // it. Verified 2026-08-06 that all three suggestions below pass dcg.
    safe: 'gh pr merge --delete-branch, or wt-sweep.sh (dcg blocks git branch -d too)',
  },
  {
    label: 'git stash drop/clear',
    danger: (c) => reGit(String.raw`stash\s+(?:drop|clear)\b`).test(c),
    why: 'permanently drops stashed changes',
    safe: 'git stash list (verify first)',
  },
];

// AI attribution trailers a model may write INTO a commit message (dotfiles#823).
// The attribution setting only governs the trailer Claude Code appends itself;
// when a prompt or an instruction template hands the model the trailer, it lands
// verbatim (smaug, 2026-08-20: 34 commit calls carried it despite
// includeCoAuthoredBy=false). Matched on the RAW command so heredoc bodies count,
// but anchored to trailer position (line start or the opening quote of a -m /
// --trailer argument) so prose that merely discusses the convention passes.
// Three shapes hit: a trailer naming an assistant product (`:` or git's
// `--trailer key=value` `=`), a trailer whose address is at an assistant
// vendor domain (catches `Anthropic <hi@anthropic.com>`, `Devin <…@cognition.ai>`,
// `Happy <…@happy.engineering>` without listing ambiguous human first names),
// and the Claude Code byline. Human co-authors pass, and the deny text quotes
// only the name part, never an address.
const AI_TRAILER_RE = new RegExp(
  String.raw`(?:^|[\n"'])\s*(?:` +
    String.raw`Co-Authored-By\s*[:=]\s*(?:Claude|Anthropic|Codex|Cursor|(?:GitHub\s+)?Copilot|Gemini|ChatGPT|GPT-?\d|OpenAI|Droid|Factory|aider)\b[^\n"'<]{0,60}` +
    String.raw`|Co-Authored-By\s*[:=]\s*[^\n"'<]{0,60}<[^>\n]*(?:@(?:anthropic\.com|openai\.com|cursor\.(?:com|sh)|factory\.ai|cognition\.ai|aider\.chat|happy\.engineering)|kiro@amazon\.com)>` +
    String.raw`|(?:🤖\s*)?Generated with \[?Claude Code)`,
  'i'
);
function aiAttributionTrailer(cmd) {
  const m = AI_TRAILER_RE.exec(cmd);
  if (!m) return null;
  return m[0].split('<')[0].trim().slice(0, 80);
}

// Text spans an agent controls but a guard must not read as command shape:
// heredoc bodies and the contents of quoted strings. gitCommands() does the same
// scrub with index-restore; this lighter form is for yes/no checks only.
function scrubTextSpans(command) {
  return command
    .replace(/<<-?\s*(['"]?)([A-Za-z_]\w*)\1[\s\S]*?\n[ \t]*\2\b/g, ' ')
    .replace(/'[^']*'/g, "''")
    .replace(/"[^"]*"/g, '""');
}

// Segment boundaries as gitCommands() sees them: start of string, the shell
// operators, and a bare newline (multi-line Bash-tool scripts are the common
// shape). Shared by the escape parser and the gh-body gate so both agree with
// the segment split.
const SEG_START = String.raw`(?:^|&&|\|\||;|\||\n)\s*`;

// An ALLOW_* escape counts only as a real environment variable or as an env
// assignment leading a segment (the shape stripEnv() removes) — or `export`ed
// as its own statement earlier in the command, which persists into every
// later segment — matched on the scrubbed text. A raw substring test let the
// token inside a commit body, a heredoc or a trailing `# comment` disarm
// rules 2b, 3 and the history-loss rules (reproduced 2026-09-02, dotfiles#840).
// Rule 5 shipped this shape first; every legitimate spelling found in 60 days
// of transcripts (leading, after `;` / `&&`, on its own line, `export`ed) still
// matches.
function escapeLeads(command, name) {
  if (process.env[name] === '1') return true;
  const re = new RegExp(
    SEG_START + String.raw`(?:export\s+)?(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*` + name + String.raw`=1(?:\s|$)`
  );
  return re.test(scrubTextSpans(command.trim()));
}

// gh segments that carry PR or issue text: rule 5's attribution check covers
// these too, because `attribution.pr: ""` only governs what Claude Code appends
// itself and two skill templates plus a plugin command put the byline in a
// `--body` (dotfiles#840). `gh api` with a `body=` field is the generic form of
// the same write. `--body-file` / `-F` contents are out of reach by design.
const GH_BODY_RE = new RegExp(
  SEG_START + String.raw`(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*gh\s+(?:pr\s+(?:create|comment|edit|merge|review)|issue\s+(?:create|comment|edit)|api\b[^\n]*(?:-f|-F|--field|--raw-field)\s+["']?body=)`
);

// `git config` writes (and inline `git -c ...`) that install code execution or
// persistence. core.hooksPath / core.fsmonitor point git at a program that runs
// on the next ordinary git op; a `!`-prefixed alias runs a shell command. These
// are an arbitrary-exec vector, not a normal config write. Returns {key,why} or
// null. Reads (--get/--list/--get-regexp, or a bare key with no value) pass.
const CONFIG_EXEC_KEYS = [
  { key: 'core.hooksPath', why: 'points git at a hooks dir whose scripts run on the next git operation' },
  { key: 'core.fsmonitor', why: 'runs an arbitrary program on git status/index reads' },
];
function gitConfigExec(cmd) {
  // Inline one-shot form: `git -c core.hooksPath=... <subcmd>` (any subcommand).
  const inline = /(?:^|\s)-c\s+(core\.hooksPath|core\.fsmonitor)\s*=/i.exec(cmd);
  if (inline) {
    const k = inline[1].toLowerCase() === 'core.hookspath' ? 'core.hooksPath' : 'core.fsmonitor';
    return { key: k, why: 'inline `-c ' + k + '=` runs arbitrary code for this git invocation' };
  }
  // Persistent form: `git [-C dir] config [scope flags] KEY VALUE`.
  if (!reGit(String.raw`config\b`).test(cmd)) return null;
  if (/(?:^|\s)(?:--get(?:-all|-regexp|-urlmatch)?|--list|-l|--name-only)\b/.test(cmd)) return null; // read
  for (const { key, why } of CONFIG_EXEC_KEYS) {
    // key followed by a value (=val, or a token that isn't another flag)
    const re = new RegExp('(?:^|\\s)' + key.replace('.', '\\.') + '(?:=|\\s+(?!-)\\S)', 'i');
    if (re.test(cmd)) return { key, why };
  }
  // Shell alias: `git config alias.x '!cmd'` — only the `!`-exec form is dangerous.
  if (/(?:^|\s)alias\.[\w.-]+(?:=|\s)/i.test(cmd) && /!/.test(cmd)) {
    return { key: 'alias.*', why: 'a `!`-prefixed git alias runs a shell command every time that alias is used' };
  }
  return null;
}

// Strip leading `VAR=value` env assignments so guards can't be bypassed by
// prefixing a command with environment variables (e.g. `GIT_PAGER=cat git ...`).
function stripEnv(cmd) {
  return cmd.replace(
    /^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)+/,
    ''
  );
}

function unquote(value) {
  return value.replace(/^['"]|['"]$/g, '');
}

// Return actual git command segments, not arbitrary prose containing "git".
// Bash tool calls commonly chain `cd repo && git ...`; guards inspect each real
// command boundary and carry a preceding `cd` into branch/rebase checks.
//
// Heredoc bodies and quoted strings are scrubbed first so embedded text (commit
// messages, `echo` args, doc heredocs that mention git commands) is never
// mis-read as a command to block. This deliberately also blinds the guard to
// `sh -c "git ..."` obfuscation: distinguishing quoted-code from quoted-data
// needs a real shell parser, and this is an accident-prevention guardrail, not
// a laundering boundary (see HARNESS.md "guardrail, not a jail").
//
// Quoted spans collapse to INDEXED placeholders rather than empty quotes, and
// each hit carries an `expand` function that (a) restores quoted content and
// (b) substitutes $VAR/${VAR} from same-command assignments. Path-extraction
// sites (cd targets, `-C` args) call it so `wt=/x; git -C "$wt" commit` is
// attributed to /x rather than silently falling back to the session cwd —
// which both denied innocent worktree commits when the launch checkout sat on
// main (145+/wk papercut) AND allowed `git -C "<main checkout>" commit` from a
// feature cwd (the same one-line bug in both directions, fixed 2026-08-07).
// Restored content is only ever treated as a PATH STRING, never re-parsed as
// commands, so the prose immunity above is preserved. A path that still holds
// an unexpandable `$VAR` resolves to null = "repo unknowable", and branch
// checks stay silent exactly like the existing not-a-git-repo posture.
function gitCommands(command) {
  const path = require('path');
  const quoted = [];
  const scrub = command
    // <<DELIM ... \nDELIM  (quoted or bare delimiter)
    .replace(/<<-?\s*(['"]?)([A-Za-z_]\w*)\1[\s\S]*?\n[ \t]*\2\b/g, ' ')
    // collapse quoted spans to indexed placeholders (keeps token shape, drops
    // content from command-shape matching; \x01 never appears in real input)
    .replace(/'([^']*)'/g, (_, s) => {
      quoted.push(s);
      return "'\x01" + (quoted.length - 1) + "'";
    })
    .replace(/"([^"]*)"/g, (_, s) => {
      quoted.push(s);
      return '"\x01' + (quoted.length - 1) + '"';
    });

  const restoreQuoted = (s) =>
    s.replace(/\x01(\d+)/g, (_, i) => (quoted[+i] !== undefined ? quoted[+i] : ''));

  // Same-command `VAR=value` assignments, harvested from the SCRUBBED text so
  // an assignment-shaped string inside quoted prose is invisible here.
  const vars = Object.create(null);
  for (const m of scrub.matchAll(/(?:^|[;&|\n]\s*)([A-Za-z_]\w*)=("[^"]*"|'[^']*'|[^\s;&|]+)/g)) {
    vars[m[1]] = restoreQuoted(unquote(m[2]));
  }
  const expand = (s) => {
    const out = restoreQuoted(s).replace(/\$\{?([A-Za-z_]\w*)\}?/g, (all, name) =>
      name in vars ? vars[name] : all
    );
    return out;
  };

  const hits = [];
  let cwd = process.cwd();
  for (let segment of scrub.split(/\s*(?:&&|\|\||;|\||\n)\s*/)) {
    segment = segment.trim();
    const cd = /^cd\s+("[^"]*"|'[^']*'|\S+)$/.exec(segment);
    if (cd) {
      const target = expand(unquote(cd[1]));
      if (target && !target.includes('$')) {
        cwd = cwd === null ? (path.isAbsolute(target) ? target : null) : path.resolve(cwd, target);
      } else {
        // Unresolvable cd target: everything after it runs somewhere we cannot
        // name. Mark unknown rather than mis-attributing the session cwd.
        cwd = null;
      }
      continue;
    }
    const bare = stripEnv(segment);
    if (/^git\s/.test(bare)) hits.push({ command: bare, cwd, expand });
  }
  return hits;
}

// Extract the `-C <dir>` target from a git command, else the command segment's
// cwd. Returns null when the repo is unknowable (unexpandable variable in the
// path, or a relative -C under an already-unknown segment cwd) — callers must
// treat null as "cannot attribute", not as the session cwd.
function extractCwd(command, fallbackCwd = process.cwd(), expand = (s) => s) {
  const path = require('path');
  // `-C` may sit after other global options (`git -c x=y -C dir commit`).
  const m = new RegExp('^git\\s+(?:' + GIT_OPT + '\\s+)*?-C\\s+("[^"]*"|\'[^\']*\'|\\S+)').exec(command);
  if (!m) return fallbackCwd;
  const target = expand(unquote(m[1]));
  if (!target || target.includes('$')) return null;
  if (path.isAbsolute(target)) return target;
  if (!fallbackCwd) return null;
  return path.resolve(fallbackCwd, target);
}

// Is a rebase in progress in the repo at `cwd`? (recovery commands are OK then)
function rebaseInProgress(cwd) {
  if (!cwd) return false;
  try {
    const { execFileSync } = require('child_process');
    const fs = require('fs');
    const path = require('path');
    const gitDir = execFileSync('git', ['rev-parse', '--git-dir'], {
      encoding: 'utf8',
      timeout: 3000,
      stdio: ['pipe', 'pipe', 'pipe'],
      cwd,
    }).trim();
    const abs = path.isAbsolute(gitDir) ? gitDir : path.join(cwd, gitDir);
    return (
      fs.existsSync(path.join(abs, 'rebase-merge')) ||
      fs.existsSync(path.join(abs, 'rebase-apply'))
    );
  } catch {
    return false;
  }
}

/**
 * @param {string} rawInput - JSON string from Claude Code stdin
 * @returns {string} JSON response or pass-through
 */
function run(rawInput) {
  try {
    const input = JSON.parse(rawInput);
    const command = input.tool_input?.command;

    if (typeof command !== 'string') return rawInput;

    // Attribute any deny below to a papercut record. A PreToolUse denial reaches
    // no post-hook, so this is the only place a guard block can be counted.
    // Never throws; enforcement does not depend on it.
    setDenyContext({
      guard: 'git-guard',
      cwd: input.cwd,
      sessionId: input.session_id,
      agentId: input.agent_id,
      tool: input.tool_name || 'Bash',
      command,
    });

    // 2b. Block: `git config` exec/persistence vectors (hooksPath, fsmonitor,
    //     `!`-alias, inline `-c`). Runs on the RAW command, not the scrubbed
    //     split: a `!`-alias VALUE is legitimately quoted, so scrubbing quotes
    //     would blind this check. Escape: ALLOW_GIT_CONFIG_EXEC=1.
    const escapedConfigExec = escapeLeads(command, 'ALLOW_GIT_CONFIG_EXEC');
    if (!escapedConfigExec) {
      const hit = gitConfigExec(stripEnv(command.trim()));
      if (hit) {
        return deny(
          'Blocked: `git config ' + hit.key + '`, ' + hit.why +
            '. This is an arbitrary-code-execution / persistence vector, not a normal config write. ' +
            'If genuinely intended, prefix the command with ALLOW_GIT_CONFIG_EXEC=1.'
        );
      }
    }

    const hits = gitCommands(command.trim());

    // 5. Block: an AI attribution trailer written INTO the commit message. Runs
    //    on the RAW command like 2b, because heredoc bodies — where the trailer
    //    lives — are scrubbed before the segment split; the segment split only
    //    proves a real `git commit` / `git merge -m` is present. Escape:
    //    ALLOW_AI_TRAILER=1 — recognised only as an env assignment leading a
    //    segment (the shape stripEnv() removes), and only on the scrubbed text,
    //    so the token inside the very message this rule inspects cannot disarm
    //    it. Precedence: this deny fires before the per-segment rules, so a
    //    trailer commit on main reports the trailer first and the main-branch
    //    doctrine once the trailer is gone — lossy by design, never permissive.
    const escapedTrailer = escapeLeads(command, 'ALLOW_AI_TRAILER');
    const carriesMessage =
      hits.some((h) => reGit(String.raw`(?:commit|merge)\b`).test(h.command)) ||
      GH_BODY_RE.test(scrubTextSpans(command.trim()));
    if (!escapedTrailer && carriesMessage) {
      const trailer = aiAttributionTrailer(command);
      if (trailer) {
        return deny(
          'Blocked: commit or PR text carries an AI attribution trailer (`' + trailer + '`). ' +
            'Harness policy keeps attribution off (settings attribution.commit and attribution.pr are ""), so this ' +
            'came from the prompt or an instruction template, not from Claude Code. Re-run without the ' +
            'attribution lines. If it is genuinely wanted, prefix the command with ALLOW_AI_TRAILER=1.'
        );
      }
    }


    for (const { command: gitCommand, cwd: segmentCwd, expand } of hits) {
      // 1. Block: git add . / git add -A / git add --all (-C-aware). The deny
      // names the actual changed files (capped) so the very next command can be
      // the fix, and points at `git add -u`, which stages tracked modifications
      // and deletions without sweeping in untracked junk — the safe form of
      // what `git add .` is usually reaching for. This rule alone was 145 of
      // 518 weekly guard denials (2026-08) purely on message actionability.
      if (isDangerousAdd(gitCommand)) {
        let hint = '';
        try {
          const { execFileSync } = require('child_process');
          const addCwd =
            extractCwd(gitCommand, segmentCwd, expand) || segmentCwd || process.cwd();
          const files = execFileSync('git', ['status', '--porcelain'], {
            encoding: 'utf8',
            timeout: 3000,
            stdio: ['pipe', 'pipe', 'pipe'],
            cwd: addCwd,
          })
            .trim()
            .split('\n')
            .filter(Boolean)
            .map((l) => {
              const p = l.slice(3).replace(/^"|"$/g, '');
              const arrow = p.lastIndexOf(' -> ');
              return arrow === -1 ? p : p.slice(arrow + 4);
            })
            .filter((f) => f && !f.endsWith('/'));
          if (files.length) {
            hint =
              ' In this repo right now that is: `git add ' +
              files.slice(0, 8).join(' ') +
              (files.length > 8 ? '` (+' + (files.length - 8) + ' more)' : '`') +
              '.';
          }
        } catch {
          // status unavailable -- generic message still stands
        }
        return deny(
          'Use specific file paths instead of `git add .` to avoid staging worktrees, secrets, and unrelated files. ' +
            'For already-tracked files, `git add -u` stages modifications and deletions without touching untracked files.' +
            hint
        );
      }

      // 2. Block: destructive git commands that lose work/history.
      const escapedDestructive = escapeLeads(command, 'ALLOW_DESTRUCTIVE_GIT');
      if (!escapedDestructive) {
        for (const rule of DESTRUCTIVE_GIT) {
          if (rule.danger(gitCommand)) {
            if (rule.recoverable && rebaseInProgress(extractCwd(gitCommand, segmentCwd, expand))) {
              return allow(
                'Rebase in progress — allowing `' + rule.label +
                  '` as the documented recovery path.'
              );
            }
            // ALLOW_DESTRUCTIVE_GIT=1 clears THIS guard and nothing else. dcg is
            // registered on the same PreToolUse/Bash matcher, never sees this env
            // var, and independently denies 6 of these 7 commands (measured
            // 2026-08-06: reset --hard, checkout --, restore --worktree,
            // push --force, clean -fd, branch -D; only stash drop gets through,
            // which dcg merely warns on). Promising the escape works sends the
            // agent into a second block it cannot clear either — so say what is
            // actually true and route to the operator instead.
            return deny(
              'Blocked: `' + rule.label + '` — ' + rule.why + '. Safer: ' +
                rule.safe + '. ALLOW_DESTRUCTIVE_GIT=1 clears this guard, but dcg ' +
                'blocks most of these independently and does not honour it — ask ' +
                'the operator rather than chaining bypasses.'
            );
          }
        }
      }

      // 3. Block: git commit / git push while on main/master.
      const gitMutation = reGit(String.raw`(commit|push)\b`).exec(gitCommand);
      if (!gitMutation) continue;

      // 3a. Block: a push whose DESTINATION refspec is a protected branch, even
      // when the checked-out branch is innocent. The current-branch check in (3)
      // cannot see these -- `git push origin HEAD:main` from a feature branch
      // writes main while `git branch --show-current` reports the feature branch.
      // Covers: HEAD:main, HEAD:refs/heads/main, :main (delete), feature:master,
      // `--delete origin main`, and a bare `git push origin main` from elsewhere.
      if (gitMutation[1] === 'push') {
        // pushTokens[0] is the remote; everything after it is a refspec.
        const pushTokens = pushArgTokens(gitCommand) || [];
        for (const spec of pushTokens.slice(1)) {
          const dest = spec
            .slice(spec.lastIndexOf(':') + 1)
            .replace(/^\+/, '')
            .replace(/^refs\/heads\//, '');

          if (PROTECTED_BRANCHES.has(dest)) {
            const escapedRefspec = escapeLeads(command, 'ALLOW_MAIN_COMMIT');
            if (escapedRefspec) {
              return allow(
                'ALLOW_MAIN_COMMIT=1 set — proceeding with push to ' + dest + '.'
              );
            }
            return deny(
              'Blocked: git push targeting ' + dest + ' via refspec `' + spec + '`. ' +
                'Doctrine: never push directly to main/master — work in a worktree/branch ' +
                'and ship via PR. If this is genuinely intended, prefix the command ' +
                'with ALLOW_MAIN_COMMIT=1.'
            );
          }
        }
      }

      try {
        const { execFileSync } = require('child_process');
        const cwd = extractCwd(gitCommand, segmentCwd, expand);
        // Repo unknowable (unexpandable $VAR in cd/-C): cannot attribute a
        // branch, so stay silent — same posture as the not-a-repo catch below.
        // Never guess the session cwd here: that exact guess produced both
        // false "commit on main" denies and false allows (2026-08-07).
        if (!cwd) continue;
        const branch = execFileSync('git', ['branch', '--show-current'], {
          encoding: 'utf8',
          timeout: 3000,
          stdio: ['pipe', 'pipe', 'pipe'],
          cwd,
        }).trim();

        if (PROTECTED_BRANCHES.has(branch)) {
          const escaped = escapeLeads(command, 'ALLOW_MAIN_COMMIT');
          if (escaped) {
            return allow(
              'ALLOW_MAIN_COMMIT=1 set — proceeding with git ' + gitMutation[1] + ' on ' + branch + '.'
            );
          }
          return deny(
            'Blocked: git ' + gitMutation[1] + ' on ' + branch + '. Doctrine: never commit or push ' +
              'directly to main/master — work in a worktree/branch and ship via PR. ' +
              'If this is genuinely intended, prefix the command with ALLOW_MAIN_COMMIT=1.'
          );
        }
      } catch {
        // Not in a git repo or git not available -- allow silently
      }
    }
  } catch {
    // Invalid JSON -- pass through
  }

  return rawInput;
}

// Standalone entry point (backwards-compatible)
if (require.main === module) {
  let data = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    if (data.length < 1024 * 1024) data += chunk;
  });
  process.stdin.on('end', () => {
    writeHookOutput(run(data), data);
    process.exit(0);
  });
}

module.exports = { run };
