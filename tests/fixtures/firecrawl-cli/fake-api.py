#!/usr/bin/env python3
"""Offline Firecrawl API: a loopback listener for the wrapper's direct transport.

FIRECRAWL_API_TEST_CONTROL is JSON: {"status": 200, "body": {...}} or
{"status": 200, "text": "..."} plus optional "headers" and "sleep" seconds.
Every request is appended to FIRECRAWL_API_TEST_LOG as one JSON line with the
method, path, Authorization, Content-Type, User-Agent, and decoded body.
The bound port is printed on stdout; the server runs until killed.
"""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import time


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        try:
            body = json.loads(raw)
        except ValueError:
            body = raw
        with open(os.environ["FIRECRAWL_API_TEST_LOG"], "a", encoding="utf-8") as log:
            log.write(json.dumps({
                "method": "POST",
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "content_type": self.headers.get("Content-Type"),
                "user_agent": self.headers.get("User-Agent"),
                "body": body,
            }) + "\n")
        control = json.loads(Path(os.environ["FIRECRAWL_API_TEST_CONTROL"]).read_text())
        if control.get("sleep"):
            time.sleep(control["sleep"])
        if "text" in control:
            payload = control["text"].encode("utf-8")
        else:
            payload = json.dumps(control.get("body", {})).encode("utf-8")
        # "truncate" promises more bytes than it sends; HTTP/1.0 closes the socket
        # after the handler returns, so the client sees a short body.
        length = len(payload) + (64 if control.get("truncate") else 0)
        try:
            self.send_response(control.get("status", 200))
            for name, value in control.get("headers", {}).items():
                self.send_header(name, value)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            self.wfile.write(payload)
        except OSError:
            pass  # The client gave up (timeout test); nothing to report.

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
