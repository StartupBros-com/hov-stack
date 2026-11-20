#!/usr/bin/env python3
"""Measurements for tests/firecrawl-local-live.test.sh (#807); verdicts live in the test.

  local-live.py ns <wrapper> <firecrawl-local> <scratch>
      Run inside `unshare -r -n -m` (a private network with nothing outside it). Puts
      "public" addresses on the namespace's loopback, serves fixture pages from
      8.8.4.4, maps localtest.me to 127.0.0.1 and Firecrawl's hosts to 8.8.8.8 in a
      bind-mounted /etc/hosts, counts every connection to each listener, and runs the
      real wrapper and binary against them. Prints one JSON object.
  local-live.py measure <out.json> -- <command...>
      Runs the command, samples its whole process tree every 50 ms (summed VmRSS, and
      summed Pss from smaps_rollup, which does not count shared pages twice), and
      writes {"rc", "stdout", "stderr", "peak_rss_mb", "peak_pss_mb", "peak_procs"}.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PUBLIC, CLOUD, METADATA = "8.8.4.4", "8.8.8.8", "169.254.169.254"
METADATA_NAME = "metadata-name.example"  # resolves to METADATA in the namespace
CLOUD_HOSTS = "api.firecrawl.dev firecrawl.dev www.firecrawl.dev"
FALSE = "/usr/bin/false" if os.path.exists("/usr/bin/false") else "/bin/false"


def as_user():
    """Chrome refuses to run as root without --no-sandbox, and the namespace's setup runs
    as its root: run the wrapper and binary in a child user namespace as the outer uid,
    sharing this network and mount namespace."""
    with open("/proc/self/uid_map") as handle:
        outer = handle.read().split()[1]
    return ["unshare", f"--map-user={outer}", f"--map-group={outer}", "--"]


def tree(root):
    children = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat") as handle:
                parent = int(handle.read().rsplit(")", 1)[1].split()[1])
        except (OSError, IndexError, ValueError):
            continue
        children.setdefault(parent, []).append(int(entry))
    found, todo = [], [root]
    while todo:
        pid = todo.pop()
        found.append(pid)
        todo.extend(children.get(pid, []))
    return found


def kib(path, field):
    try:
        with open(path) as handle:
            for line in handle:
                if line.startswith(field + ":"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


def measure(out, command, env=None):
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env
    )
    peak = {"rss": 0, "pss": 0, "procs": 0}
    done = threading.Event()

    def sample():
        while not done.is_set():
            pids = tree(process.pid)
            peak["rss"] = max(peak["rss"], sum(kib(f"/proc/{p}/status", "VmRSS") for p in pids))
            peak["pss"] = max(peak["pss"], sum(kib(f"/proc/{p}/smaps_rollup", "Pss") for p in pids))
            peak["procs"] = max(peak["procs"], len(pids))
            time.sleep(0.05)

    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    stdout, stderr = process.communicate()
    done.set()
    sampler.join()
    result = {
        "rc": process.returncode, "stdout": stdout, "stderr": stderr[-2000:],
        "peak_rss_mb": peak["rss"] // 1024, "peak_pss_mb": peak["pss"] // 1024,
        "peak_procs": peak["procs"],
    }
    if out:
        Path(out).write_text(json.dumps(result))
    return result


def page(title, body, head=""):
    return (f"<!doctype html><html><head><title>{title}</title>{head}</head>"
            f"<body>{body}</body></html>").encode()


def script_page(marker):
    return page("js", "<div id=\"root\"></div><script>document.getElementById('root').innerHTML="
                f"'<h1>Built by script</h1><p>'+'{marker} '.repeat(40)+'</p>';</script>")


def ns(wrapper, binary, scratch):
    scratch = Path(scratch)
    for command in (
        ["ip", "link", "set", "lo", "up"],
        ["ip", "addr", "add", f"{PUBLIC}/32", "dev", "lo"],
        ["ip", "addr", "add", f"{CLOUD}/32", "dev", "lo"],
        ["ip", "addr", "add", f"{METADATA}/32", "dev", "lo"],
    ):
        subprocess.run(command, check=True)
    hosts = scratch / "hosts"
    hosts.write_text(
        f"127.0.0.1 localhost localtest.me\n{CLOUD} {CLOUD_HOSTS}\n{METADATA} {METADATA_NAME}\n"
    )
    subprocess.run(["mount", "--bind", str(hosts), "/etc/hosts"], check=True)

    hits = {"localtest": [], "metadata": [], "cloud": [], "public": []}

    def recorder(name):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                hits[name].append(self.path)
                path = self.path.split("?")[0]
                body = pages.get(path) if name == "public" else b"listener"
                content_type = "text/html"
                if isinstance(body, tuple) and body[0] == "flip":
                    # The first request (the plain fetch) gets the page, every later
                    # one (Chrome's) the redirect.
                    body = body[1] if hits[name].count(self.path) == 1 else ("redirect", body[2])
                if isinstance(body, tuple) and body[0] == "typed":
                    content_type, body = body[1], body[2]
                if isinstance(body, tuple):
                    self.send_response(302)
                    self.send_header("location", body[1])
                    self.send_header("content-length", "0")
                    self.end_headers()
                    return
                self.send_response(200 if body is not None else 404)
                self.send_header("content-type", content_type)
                body = body or b"<html><body>not found</body></html>"
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            do_POST = do_GET

            def log_message(self, *args):
                pass
        return Handler

    local = ThreadingHTTPServer(("127.0.0.1", 0), recorder("localtest"))
    port = local.server_address[1]
    trap = f"http://localtest.me:{port}"
    pages = {
        "/plain-a": page("plain a", "<h1>Plain A</h1><p>" + "ALPHAMARKER " * 40 + "</p>"),
        "/plain-b": page("plain b", "<h1>Plain B</h1><p>" + "BRAVOMARKER " * 40 + "</p>"),
        "/js": script_page("SCRIPTMARKER"),
        "/probe": page(
            "probe",
            f"<h1>Probe</h1><p>{'PROBEMARKER ' * 40}</p><img src=\"{trap}/img\">"
            f"<script>fetch('{trap}/fetch').catch(function(){{}});"
            f"document.body.insertAdjacentHTML('beforeend','<p>script ran</p>');</script>",
            head=f"<meta http-equiv=\"refresh\" content=\"1;url={trap}/refresh\">",
        ),
        "/r-local": ("redirect", f"{trap}/redirect"),
        "/r-metadata": ("redirect", f"http://{METADATA}/latest/meta-data/"),
        "/r-metaname": ("redirect", f"http://{METADATA_NAME}/latest/meta-data/"),
        # Script-built on the plain fetch, a redirect to a private name in Chrome: the
        # refusal comes from the browser's guard, worded "'name' resolves to ...".
        "/flip-local": ("flip", script_page("FLIPMARKER"), f"{trap}/flip"),
        "/flip-metadata": ("flip", script_page("FLIPMARKER"),
                           f"http://{METADATA_NAME}/latest/meta-data/"),
        # An HTTP-200 bot check: the scraper flags it only from the markdown it returns.
        "/botcheck": page("Just a moment...", "<h1>Verifying you are human</h1>"
                          "<p>This may take a few seconds.</p>"),
        # A JSON page yields markdown and rawHtml only.
        "/data.json": ("typed", "application/json",
                       json.dumps({"marker": "JSONMARKER " * 20}).encode()),
    }
    for index in range(1, 5):
        pages[f"/js-{index}"] = script_page(f"PAGE{index}MARKER")
    servers = [
        local,
        ThreadingHTTPServer((PUBLIC, 80), recorder("public")),
        ThreadingHTTPServer((METADATA, 80), recorder("metadata")),
    ]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    for cloud_port in (80, 443):
        listener = socket.create_server((CLOUD, cloud_port))

        def accept(sock=listener):
            while True:
                connection, _ = sock.accept()
                hits["cloud"].append(sock.getsockname()[1])
                connection.close()
        threading.Thread(target=accept, daemon=True).start()

    stubs = scratch / "stubs"
    stubs.mkdir()
    vendor_log = scratch / "vendor.log"
    (stubs / "firecrawl").write_text(
        f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {vendor_log}\necho 'vendor stub: no cloud here' >&2\nexit 1\n"
    )
    os.chmod(stubs / "firecrawl", 0o755)
    home = scratch / "home"
    home.mkdir()
    python_dir = os.path.dirname(sys.executable)
    wrapper_env = {
        "PATH": f"{stubs}:{python_dir}:/usr/bin:/bin", "HOME": str(home),
        "FIRECRAWL_CLI_LOCAL_BIN": binary, "LANG": "C.UTF-8",
        # A fall-through goes straight to the logging vendor stub, not the keyless API.
        "FIRECRAWL_CLI_KEYLESS": "0",
    }
    direct_home = scratch / "direct"
    direct_home.mkdir()
    direct_env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(direct_home),
        "TMPDIR": str(direct_home), "FIRECRAWL_CLOUD": "off",
        "FIRECRAWL_LOCAL_HOME": str(direct_home),
    }

    def snapshot():
        return {name: len(value) for name, value in hits.items()}

    def delta(before):
        after = snapshot()
        return {name: after[name] - before[name] for name in after}

    def wrapper_run(*urls, out=None, formats=None):
        before = snapshot()
        vendor_before = vendor_log.read_text().count("\n") if vendor_log.exists() else 0
        shape = ["--format", formats] if formats else ["--full"]
        result = measure(out, [*as_user(), wrapper, "fetch", *urls, *shape, "--json"], env=wrapper_env)
        vendor_after = vendor_log.read_text().count("\n") if vendor_log.exists() else 0
        try:
            result["json"] = json.loads(result["stdout"])
        except ValueError:
            result["json"] = None
        result["hits"] = delta(before)
        result["vendor_calls"] = vendor_after - vendor_before
        return result

    def direct_run(url, public_only=True, browser="always", chrome=None, formats="markdown"):
        before = snapshot()
        argv = [binary, "scrape", url]
        argv += ["--public-only"] if public_only else []
        argv += ["-f", formats, "--timeout", "30000", "-c", "1"]
        argv += ["--browser", browser] if browser else []
        env = dict(direct_env)
        if chrome:
            env["FIRECRAWL_CHROME_PATH"] = chrome
        done = subprocess.run([*as_user(), *argv], capture_output=True, text=True, env=env, timeout=120)
        time.sleep(1.5)  # a meta refresh or late fetch() would land after the page settles
        try:
            parsed = json.loads(done.stdout)
        except ValueError:
            parsed = None
        return {"rc": done.returncode, "json": parsed, "stdout": done.stdout,
                "stderr": done.stderr[-2000:], "hits": delta(before)}

    base = f"http://{PUBLIC}"
    results = {"trap_port": port}
    results["three"] = wrapper_run(f"{base}/plain-a", f"{base}/plain-b", f"{base}/js")
    results["probe_public_only"] = direct_run(f"{base}/probe")
    results["probe_control"] = direct_run(f"{base}/probe", public_only=False)
    results["redirect_local"] = wrapper_run(f"{base}/r-local")
    results["redirect_metadata"] = wrapper_run(f"{base}/r-metadata")
    results["chrome_hidden"] = direct_run(f"{base}/js", browser=None, chrome=FALSE)
    results["four_browser"] = wrapper_run(*(f"{base}/js-{i}" for i in range(1, 5)))
    # Pro review of #826: the browser guard's DNS refusals, the HTML-only bot check and
    # a result missing a requested format, through the wrapper and as the binary says them.
    results["flip_local"] = wrapper_run(f"{base}/flip-local")
    results["flip_metadata"] = wrapper_run(f"{base}/flip-metadata")
    results["browser_private_direct"] = direct_run(f"{base}/r-local")
    results["browser_metadata_direct"] = direct_run(f"{base}/r-metaname")
    results["botcheck_html"] = wrapper_run(f"{base}/botcheck", formats="html")
    results["botcheck_direct_html"] = direct_run(
        f"{base}/botcheck", browser=None, chrome=FALSE, formats="html")
    results["botcheck_direct_html_markdown"] = direct_run(
        f"{base}/botcheck", browser=None, chrome=FALSE, formats="html,markdown")
    results["json_markdown_html"] = wrapper_run(f"{base}/data.json", formats="markdown,html")
    results["json_direct"] = direct_run(
        f"{base}/data.json", browser=None, chrome=FALSE, formats="markdown,html")
    results["plain_html"] = wrapper_run(f"{base}/plain-a", formats="html")
    results["plain_direct_html"] = direct_run(
        f"{base}/plain-a", browser=None, chrome=FALSE, formats="html,markdown")
    results["plain_direct_all"] = direct_run(
        f"{base}/plain-a", browser=None, chrome=FALSE, formats="markdown,links,rawHtml,html")
    results["cloud_connections_total"] = len(hits["cloud"])
    for server in servers:
        server.shutdown()
    print(json.dumps(results))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "ns":
        ns(*sys.argv[2:5])
    elif mode == "measure":
        assert sys.argv[3] == "--"
        result = measure(sys.argv[2], sys.argv[4:])
        sys.exit(0)
    else:
        sys.exit(f"unknown mode {mode!r}")
