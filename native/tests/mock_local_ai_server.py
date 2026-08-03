#!/usr/bin/env python3
"""Deterministic local-only fixture for native UI smoke tests.

This is not the production model server. It mirrors the three llama-server
routes used by the clients so the browser-to-review flow can be tested without
network access, credentials, or changes to the assignment database.
"""

from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HOST = "127.0.0.1"
PORT = 8080


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/health":
            self._json({"status": "ok"})
        elif self.path == "/v1/models":
            self._json({"data": [{"id": "fixture-model"}]})
        elif self.path == "/fixture":
            body = b"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>CSE 122 Assignments</title></head>
<body>
  <main>
    <h1>CSE 122</h1>
    <article>
      <h2>Project 2 - Absurdle</h2>
      <p>Due July 30, 2026 at 11:59 PM</p>
      <p>Implement the dictionary pruning algorithm.</p>
    </article>
  </main>
</body>
</html>"""
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        json.loads(self.rfile.read(length))
        content = json.dumps(
            {
                "assignments": [
                    {
                        "course_name": "CSE 122",
                        "title": "Project 2 - Absurdle",
                        "due_date": "2026-07-30",
                        "due_time": "23:59",
                        "description": "Implement the dictionary pruning algorithm.",
                        "source_name": "Local fixture",
                        "source_url": f"http://{HOST}:{PORT}/fixture",
                        "confidence": "high",
                        "warnings": [],
                    }
                ]
            }
        )
        self._json(
            {
                "choices": [
                    {
                        "message": {
                            "role": "assistant",
                            "content": content,
                        }
                    }
                ]
            }
        )

    def log_message(self, format: str, *args: object) -> None:
        return

    def _json(self, payload: object) -> None:
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
