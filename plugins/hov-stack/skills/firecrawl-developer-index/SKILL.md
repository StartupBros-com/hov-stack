---
name: firecrawl-developer-index
description: Search library, SDK, API, and framework documentation, READMEs, GitHub issues, and merged pull requests for the matched passage. Use when the user names a version, pastes an error message, asks how to use, configure, or migrate a library, or asks whether a bug was fixed and in which release. Not for general programming concepts.
---

# Firecrawl Developer Index

Answer a developer question from the primary source: the issue where the bug
was reported, the merged pull request that fixed it, the README or docs page
that states the contract. A blog post describing a behaviour is weaker than the
passage that defines it, so use the index first and the open web second. The
repository half covers public repositories only; private code must be read
directly. There is no fixed recipe: decide what kind of question it is and pick
the approach below.

## Tools

One verb, called through the harness wrapper (not the vendor binary, whose
`developer` command is not used here, and not MCP):

`firecrawl-cli developer "<question>" [filters] --json`

Results are ranked over the whole index. Cost: without `FIRECRAWL_API_KEY` it
is free under Firecrawl's keyless allowance at any `--limit`, and the
envelope's `degraded` field says the account floor was not checked. With the
key, `--limit` 10 or less (the default) still tries keyless first and spends
nothing; a keyed run (a larger limit, or a keyless refusal) is 2 credits per
10 results, rounded up (`--limit 11` is 4), reserved and checked like `search`.

- `--limit N` (1-100, default 10).
- `--types LIST`: any of `doc`, `issue`, `pull_request`, `readme`; default all
  four. Narrowing here is the cheapest way to sharpen a query.
- `--repos owner/name,...` scopes the repository half (`issue`,
  `pull_request`, `readme`); `--sources ID,...` (at most 20) scopes the `doc`
  half. Passing both unions the halves.
- `--passages N` (1-5, default 1): the maximum passages per result. Raise it
  when the right page shows the wrong part, before raising `--limit`.
- `--skills-only`: search only indexed agent-skill files.
- `--language`, `--topic`, `--license`, `--min-stars`, `--max-stars`,
  `--archived true|false`, `--fork true|false`: repository attributes. Without
  `--sources` they return repository evidence only and no `doc` results. That
  is by design; do not retry or call the index broken.
- `--timeout S`, `--full`, `-o PATH` are wrapper-common. Body text is bounded at
  24,576 characters unless `--full`.

Results are in `data.results[]`:

```json
{"surface":"developer","verb":"developer",
 "data":{"success":true,"partial":false,"results":[
  {"id":"issue:tokio-rs/tokio#8175","url":"https://github.com/tokio-rs/tokio/issues/8175",
   "title":"Inconsistent cancel safety documentation#8175",
   "passages":[{"text":"# Inconsistent cancel safety documentation ..."}],"license":"MIT"}]}}
```

The `id` prefix is the artifact kind: `doc:`, `issue:`, `pull_request:`,
`readme:`, and, when you pass no `--types`, possibly `web:` (forum threads,
blogs, docs mirrors): on 2026-10-30 they were 14 of the 40 results from four
untyped calls and none from five typed ones, so pass `--types` to keep them
out. `title` is often absent on `doc` results; use `url`. Passages are markdown. `coverage`, when the API sends it,
says why a type is missing: `skipped` means you did not ask for it, `degraded`
or `unavailable` means the index or a filter, not your query. It was absent
from all 12 responses observed on 2026-10-30, so when it is missing, read a
missing type off `--types` and the id kinds returned. `partial: true` means
some half did not answer. The `repos` and `sources` echoes appear only when
you pass `--repos` or `--sources`, and carry `indexed: true|false`: `false`
means nothing from that scope can ever match, so drop the scope instead of
rephrasing. `--repos` without a repository type, or `--sources` without `doc`,
is an API 400 (exit 1).

## Match the approach to the question

- **Literal error string** → the string plus the library name, `--types
  issue,pull_request`. If nothing matches, strip paths, line numbers, and ids
  and retry on the invariant middle.
- **"How do I do X"** → the full question, all four types; the answer is
  usually a `doc` or `readme`.
- **Known bug** → search `issue,pull_request`, then re-query the issue's terms
  with `--repos` and `--types pull_request`. The merged PR says what changed.
- **API contract** (return value, required, default) → `--types readme,doc`.
  If the contract moved, follow up with `pull_request`.
- **Version-specific behaviour** → an opening report describes the broken
  version and its resolution supersedes it. Raise `--passages` and read the
  resolution and linked PR. Never answer from an opening report alone.
- **One library** → `--repos owner/name`, plus `--sources` for its docs.
- **Ecosystem-wide** ("who else hit this") → no scope; `--language`, `--topic`,
  `--min-stars` keep maintained repositories at the cost of all `doc` results.
- **Agent skills and conventions** → `--skills-only`.

## Principles

- Quote the passage and cite the `url`; do not paraphrase into a claim the
  reader cannot check.
- A fix is not a release. A merged PR reaches the user's version only once a
  release contains it; confirm from release notes, a changelog, or a tag.
- Scope last. Search the whole index, then narrow once you see the hits.
- Go to the web when the index has nothing: `exa-cli search`, then
  `firecrawl-cli fetch <url> --json` for a full page. Do not present a general
  web page as a primary source.

## Routing

- **Official library docs by exact version** → Context7 MCP first; use this
  index for issues, PRs, and READMEs, or when Context7 lacks the library.
- **Papers** → `firecrawl-research-index`.
- **GitHub-history fallback** (the index misses a repo) →
  `firecrawl-cli search "<repo and issue query>" --categories developer --json`
  (needs FIRECRAWL_API_KEY), only then.
- **Comparisons, opinion, news, unindexed projects** → the open web.
- **US law** → `firecrawl-gov-index`.
