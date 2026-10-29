#!/usr/bin/env python3
"""error_server.py —— QA 用的确定性错误后端（仅监听 127.0.0.1）。

POST /401/v1/chat/completions        -> 401，body 里故意带 apiKey，验证脱敏
POST /429/v1/chat/completions        -> 429
POST /500/v1/chat/completions        -> 500
POST /nonjson/v1/chat/completions    -> 200 + 非 JSON
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = "sk-qa-should-not-leak-1234"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("[error-server] " + (fmt % args) + "\n")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)

        if "/401/" in self.path:
            status, body = 401, '{"error":{"message":"invalid api key %s"}}' % SECRET
        elif "/429/" in self.path:
            status, body = 429, '{"error":"rate limited"}'
        elif "/500/" in self.path:
            status, body = 500, '{"error":"boom %s"}' % SECRET
        elif "/nonjson/" in self.path:
            status, body = 200, "this is not json"
        elif "/slow/" in self.path:
            import time
            time.sleep(3)
            status, body = 200, '{"choices":[{"message":{"content":"[]"}}]}'
        else:
            status, body = 404, '{"error":"not found"}'

        payload = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json" if status != 200 else "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18787
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
