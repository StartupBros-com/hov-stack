#!/usr/bin/env python3
"""Generic Slack Web API caller for the slack-admin skill.

Auth: SLACK_XOXP_TOKEN from the environment, falling back to
~/.config/slack-admin.env. The token is sent in the Authorization header
only and is never printed.

Usage:
    slack_api.py <method> [key=value ...] [--paginate <response_key>]

Examples:
    slack_api.py auth.test
    slack_api.py conversations.list types=public_channel,private_channel exclude_archived=true --paginate channels
    slack_api.py conversations.archive channel=C0XXXXXXX
    slack_api.py chat.postMessage channel=C0XXXXXXX text='hello world'

Output: JSON to stdout. With --paginate, follows next_cursor and prints the
merged item array. Exits 1 if the API returns ok=false.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ENV_FILE = os.path.expanduser("~/.config/slack-admin.env")
API = "https://slack.com/api/"


def load_token():
    token = os.environ.get("SLACK_XOXP_TOKEN")
    if token:
        return token
    try:
        with open(ENV_FILE) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("export SLACK_XOXP_TOKEN="):
                    return line.split("=", 1)[1].strip("'\"")
    except OSError:
        pass
    sys.exit(f"SLACK_XOXP_TOKEN not set and {ENV_FILE} not readable")


TOKEN = load_token()


def call(method, params):
    body = urllib.parse.urlencode(params).encode()
    for _ in range(8):
        req = urllib.request.Request(
            API + method, data=body, headers={"Authorization": f"Bearer {TOKEN}"}
        )
        try:
            with urllib.request.urlopen(req) as resp:
                parsed = json.load(resp)
        except urllib.error.HTTPError as exc:
            if exc.code == 429:
                time.sleep(int(exc.headers.get("Retry-After", "3")) + 1)
                continue
            raise
        if not parsed.get("ok") and parsed.get("error") == "ratelimited":
            time.sleep(3)
            continue
        return parsed
    return {"ok": False, "error": "retries_exhausted"}


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        sys.exit(__doc__)
    method = args[0]
    paginate_key = None
    params = {}
    rest = iter(args[1:])
    for a in rest:
        if a == "--paginate":
            paginate_key = next(rest, None)
            if not paginate_key:
                sys.exit("--paginate requires a response key (e.g. channels)")
        elif "=" in a:
            k, v = a.split("=", 1)
            params[k] = v
        else:
            sys.exit(f"unrecognized argument: {a!r} (expected key=value)")

    if paginate_key:
        items, cursor = [], None
        params.setdefault("limit", "200")
        while True:
            if cursor:
                params["cursor"] = cursor
            page = call(method, params)
            if not page.get("ok"):
                print(json.dumps(page, indent=2))
                sys.exit(1)
            items.extend(page.get(paginate_key, []))
            cursor = (page.get("response_metadata") or {}).get("next_cursor")
            if not cursor:
                break
        print(json.dumps(items, indent=2))
    else:
        result = call(method, params)
        print(json.dumps(result, indent=2))
        if not result.get("ok"):
            sys.exit(1)


if __name__ == "__main__":
    main()
