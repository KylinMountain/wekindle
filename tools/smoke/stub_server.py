#!/usr/bin/env python3
"""Local stub server emulating the WeRead endpoints used by the smoke test.

Routes:
  POST /web/login/renewal      -> {"succ": 1} + Set-Cookie (wr_session, wr_vid)
  POST /api/agent/gateway      -> requires Authorization: Bearer; echoes api_name
  GET  /web/book/getProgress   -> requires Cookie header; returns progress JSON
  GET  /redirect               -> 302 to /web/book/getProgress
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, obj, status=200, extra_headers=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path == "/web/login/renewal":
            self._send_json({"succ": 1, "vid": 424242}, extra_headers={
                "Set-Cookie": "wr_gid=test-renewed-gid-123; Path=/; HttpOnly",
            })
            return
        if self.path == "/api/agent/gateway":
            auth = self.headers.get("Authorization") or ""
            if not auth.startswith("Bearer "):
                self._send_json({"errCode": -2010, "errMsg": "no bearer"}, status=401)
                return
            try:
                payload = json.loads(body or b"{}")
            except json.JSONDecodeError:
                payload = {}
            api_name = payload.get("api_name")
            if api_name == "/book/info":
                self._send_json({
                    "bookId": payload.get("bookId"),
                    "title": "冒烟测试之书",
                    "author": "测试作者",
                    "format": "epub",
                })
                return
            self._send_json({"echo": api_name, "ok": True})
            return
        self._send_json({"errCode": -1, "errMsg": "unknown path"}, status=404)

    def do_GET(self):
        if self.path.startswith("/web/book/getProgress"):
            cookie = self.headers.get("Cookie") or ""
            if "wr_gid=" not in cookie:
                self._send_json({"errCode": -2012, "errMsg": "login timeout"}, status=401)
                return
            self._send_json({"bookId": "stub", "chapterUid": 3, "progress": 42})
            return
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/web/book/getProgress?bookId=stub")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._send_json({"errCode": -1}, status=404)

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8321
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
