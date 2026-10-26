#!/usr/bin/env python3
"""gsc: agent-native Google Search Console access.

WHY A CLI AND NOT AN MCP SERVER

The previous path was the third-party `mcp-gsc` package via uvx. It broke with
`ModuleNotFoundError: No module named 'mcp.server.fastmcp'`: the package pins an
old MCP SDK API, uvx resolves a current `mcp`, and the import path no longer
exists. Nothing was wrong with the credentials.

That failure mode is structural, not bad luck. An MCP server adds a protocol
layer, a session lifecycle and a third-party package between an agent and an API
that is already simple. It breaks on SDK drift, has to be reconnected per
session, and is unavailable to subagents, cron jobs and shell scripts.

A CLI has none of those properties. It shells out from anywhere, its output is
greppable, its dependencies are pinned in one venv, and when Google changes
something the failure is a readable stack trace rather than `-32000`.

AUTH

Use --credentials, HOV_STACK_GOOGLE_CREDENTIALS, GOOGLE_APPLICATION_CREDENTIALS,
or google-service-account.json under $CLAUDE_CONFIG_DIR (default ~/.claude).
The service account needs siteOwner on the properties you query.

Read commands use the readonly scope. `sitemap submit` is the only command that
asks for the writable one.

USAGE

  gsc sites
  gsc query --site startupbros.com --days 28 --dim page --limit 50
  gsc query --site startupbros.com --dim query --contains "amazon ranking"
  gsc pages --site startupbros.com --days 90        # top pages by clicks
  gsc url --site startupbros.com --url https://...  # URL inspection
  gsc sitemap list --site willmitchell.com
  gsc sitemap submit --site willmitchell.com --url https://willmitchell.com/sitemap.xml

Add --json for machine-readable output; the default is a padded table.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, timedelta

CREDENTIALS = os.path.join(
    os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
    "google-service-account.json",
)

# Least privilege by default. Everything that only reads asks for the readonly
# scope; only `sitemap submit` requests the writable one, and it says so in its
# help text. Broadening the module-level scope so one write command works would
# silently hand every other command the ability to mutate Search Console.
SCOPES_READ = ["https://www.googleapis.com/auth/webmasters.readonly"]
SCOPES_WRITE = ["https://www.googleapis.com/auth/webmasters"]


def credentials_path():
    return (
        os.environ.get("HOV_STACK_GOOGLE_CREDENTIALS")
        or os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
        or CREDENTIALS
    )


def service(write: bool = False, credentials=None):
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    creds = service_account.Credentials.from_service_account_file(
        credentials or credentials_path(), scopes=SCOPES_WRITE if write else SCOPES_READ
    )
    return build("searchconsole", "v1", credentials=creds, cache_discovery=False)


def normalise_site(site: str) -> str:
    """Accept a bare domain, a URL, or a full sc-domain: property."""
    if site.startswith(("sc-domain:", "http://", "https://")):
        return site
    return f"sc-domain:{site}"


def cmd_sites(args) -> int:
    entries = (
        service(credentials=args.credentials)
        .sites()
        .list()
        .execute()
        .get("siteEntry", [])
    )
    if args.json:
        print(json.dumps(entries, indent=2))
        return 0
    for entry in entries:
        print(f"{entry['permissionLevel']:22} {entry['siteUrl']}")
    return 0


def run_query(args, dimensions):
    end = date.today() - timedelta(days=args.lag)
    start = end - timedelta(days=args.days)

    body = {
        "startDate": start.isoformat(),
        "endDate": end.isoformat(),
        "dimensions": dimensions,
        "rowLimit": args.limit,
    }

    filters = []
    if args.contains:
        filters.append(
            {
                "dimension": dimensions[0],
                "operator": "contains",
                "expression": args.contains,
            }
        )
    # Scope to one page SERVER-side.
    #
    # Without this the only way to see a page's queries is to pull every
    # page+query pair and filter locally, which the API's row cap silently
    # truncates: on 2026-08-05 a page reporting 13,834 impressions returned
    # query rows totalling 22 (0.2%), and another returned 14 of 11,224. Both
    # read as "almost no queries" when the real answer was "the cap cut them".
    # A filter pushed to the API returns that page's rows and nothing else, so
    # the cap applies to a set small enough to fit.
    if getattr(args, "page", None):
        filters.append(
            {
                "dimension": "page",
                "operator": "equals" if args.page.startswith("http") else "contains",
                "expression": args.page,
            }
        )
    if filters:
        body["dimensionFilterGroups"] = [{"filters": filters}]

    return (
        service(credentials=args.credentials)
        .searchanalytics()
        .query(siteUrl=normalise_site(args.site), body=body)
        .execute()
        .get("rows", [])
    )


def print_rows(rows, dimensions, as_json) -> int:
    if as_json:
        print(json.dumps(rows, indent=2))
        return 0
    if not rows:
        print("(no rows)")
        return 0

    width = max(len(" / ".join(r["keys"])) for r in rows)
    width = min(width, 92)
    header = f"{'  '.join(dimensions):<{width}}  {'clicks':>7} {'impr':>8} {'ctr':>7} {'pos':>6}"
    print(header)
    print("-" * len(header))
    for row in rows:
        key = " / ".join(row["keys"])[:width]
        print(
            f"{key:<{width}}  {row['clicks']:>7.0f} {row['impressions']:>8.0f} "
            f"{row['ctr'] * 100:>6.2f}% {row['position']:>6.1f}"
        )
    return 0


def cmd_query(args) -> int:
    dimensions = args.dim.split(",")
    return print_rows(run_query(args, dimensions), dimensions, args.json)


def cmd_pages(args) -> int:
    args.dim = "page"
    args.contains = args.contains or None
    return print_rows(run_query(args, ["page"]), ["page"], args.json)


def cmd_url(args) -> int:
    """URL Inspection: what Google actually knows about one URL.

    This is the authoritative answer to 'is Google indexing this, and what does
    it think the canonical is', which matters for deciding whether a dead URL is
    worth redirecting or can simply 404.
    """
    body = {"inspectionUrl": args.url, "siteUrl": normalise_site(args.site)}
    try:
        result = (
            service(credentials=args.credentials)
            .urlInspection()
            .index()
            .inspect(body=body)
            .execute()
        )
    except Exception as exc:  # noqa: BLE001 - surface the real API error
        print(f"inspection failed: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, indent=2))
        return 0

    idx = result.get("inspectionResult", {}).get("indexStatusResult", {})
    for field in (
        "verdict",
        "coverageState",
        "robotsTxtState",
        "indexingState",
        "pageFetchState",
        "googleCanonical",
        "userCanonical",
        "lastCrawlTime",
    ):
        if field in idx:
            print(f"{field:18} {idx[field]}")
    return 0


def cmd_sitemap_list(args) -> int:
    """What sitemaps does Search Console actually know about for this property?

    Worth checking before assuming a sitemap is doing anything. A sitemap that
    exists and resolves is not the same as a sitemap Google has been told about:
    willmitchell.com served a valid /sitemap.xml listing every page while URL
    Inspection reported the property's own /citations as "URL is unknown to
    Google", because nothing had ever pointed a crawler at the file.
    """
    result = (
        service(credentials=args.credentials)
        .sitemaps()
        .list(siteUrl=normalise_site(args.site))
        .execute()
    )
    entries = result.get("sitemap", [])

    if args.json:
        print(json.dumps(entries, indent=2))
        return 0

    if not entries:
        print("(no sitemaps submitted for this property)")
        return 0

    for entry in entries:
        warnings = entry.get("warnings", 0)
        errors = entry.get("errors", 0)
        submitted = (entry.get("lastSubmitted") or "")[:10]
        downloaded = (entry.get("lastDownloaded") or "never")[:10]
        print(
            f"{entry['path']}\n"
            f"  submitted={submitted or 'unknown'}  downloaded={downloaded}  "
            f"errors={errors}  warnings={warnings}"
        )
    return 0


def cmd_sitemap_submit(args) -> int:
    """Submit a sitemap. This is a WRITE against the property.

    Note on scope: this is the one place the CLI asks for the writable
    `webmasters` scope rather than `webmasters.readonly`.

    Note on what this does NOT do: there is no public API for the URL
    Inspection "Request Indexing" button. The Indexing API only accepts
    JobPosting and BroadcastEvent, so it does not apply to ordinary pages.
    Sitemap submission is the API-reachable way to get a URL discovered;
    anything faster is a dashboard action.
    """
    site = normalise_site(args.site)
    try:
        service(write=True, credentials=args.credentials).sitemaps().submit(
            siteUrl=site, feedpath=args.url
        ).execute()
    except Exception as exc:  # noqa: BLE001 - surface the real API error
        print(f"submit failed: {exc}", file=sys.stderr)
        return 1

    print(f"submitted {args.url} to {site}")
    print("Google fetches asynchronously; re-check with: gsc sitemap list --site <site>")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="gsc", description="Agent-native Google Search Console access."
    )
    credentials_help = (
        "service-account JSON; default HOV_STACK_GOOGLE_CREDENTIALS, then GOOGLE_APPLICATION_CREDENTIALS, then "
        + CREDENTIALS
    )
    parser.add_argument(
        "--credentials", default=credentials_path(), help=credentials_help
    )
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    sub = parser.add_subparsers(dest="command", required=True)

    sites_p = sub.add_parser("sites", help="list properties this account can read")
    sites_p.add_argument("--json", action="store_true", help="machine-readable output")
    sites_p.set_defaults(func=cmd_sites)

    # --json is accepted both before and after the subcommand. Argparse would
    # otherwise only honour `gsc --json query`, and `gsc query --json` is the
    # form everyone reaches for first. A flag that silently does nothing in the
    # obvious position is worse than no flag.
    def add_json(p):
        p.add_argument("--json", action="store_true", help="machine-readable output")

    def add_query_args(p):
        add_json(p)
        p.add_argument("--site", required=True, help="domain, URL, or sc-domain: property")
        p.add_argument("--days", type=int, default=28)
        # Search Console data lags roughly 2 days; querying up to today silently
        # returns a partial final day and makes trends look like a cliff.
        p.add_argument("--lag", type=int, default=2, help="days to back off from today")
        p.add_argument("--limit", type=int, default=100)
        p.add_argument("--contains", help="substring filter on the first dimension")
        p.add_argument(
            "--page",
            help="scope to one page, server-side (full URL = exact, else substring). "
            "Use this instead of pulling page+query pairs and grepping: the row "
            "cap truncates that silently and low-traffic rows vanish.",
        )

    q = sub.add_parser("query", help="search analytics")
    add_query_args(q)
    q.add_argument("--dim", default="query", help="comma-separated: query,page,country,device,date")
    q.set_defaults(func=cmd_query)

    p = sub.add_parser("pages", help="top pages by clicks")
    add_query_args(p)
    p.set_defaults(func=cmd_pages)

    u = sub.add_parser("url", help="URL inspection for one URL")
    u.add_argument("--json", action="store_true", help="machine-readable output")
    u.add_argument("--site", required=True)
    u.add_argument("--url", required=True)
    u.set_defaults(func=cmd_url)

    sm = sub.add_parser("sitemap", help="list or submit sitemaps")
    sm_sub = sm.add_subparsers(dest="sitemap_command", required=True)

    sm_list = sm_sub.add_parser("list", help="sitemaps Search Console knows about")
    add_json(sm_list)
    sm_list.add_argument("--site", required=True)
    sm_list.set_defaults(func=cmd_sitemap_list)

    sm_submit = sm_sub.add_parser(
        "submit", help="submit a sitemap (WRITE: uses the webmasters scope)"
    )
    add_json(sm_submit)
    sm_submit.add_argument("--site", required=True)
    sm_submit.add_argument("--url", required=True, help="full URL of the sitemap")
    sm_submit.set_defaults(func=cmd_sitemap_submit)

    for child in (sites_p, q, p, u, sm, sm_list, sm_submit):
        child.add_argument(
            "--credentials", default=argparse.SUPPRESS, help=credentials_help
        )
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
