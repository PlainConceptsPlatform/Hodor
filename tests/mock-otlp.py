"""tests/mock-otlp.py - OTLP/HTTP mock for tests/run.sh (python3 standard library only).

Usage: python3 mock-otlp.py <dir>   -> writes the chosen port to <dir>/port, serves until killed.
Every request is appended to <dir>/requests.jsonl as {code, auth, body}.
Response code from <dir>/mode.txt: '200' / '500' / ... (default 200), or 'okleft N' = N more 200s, then 500.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DIR = sys.argv[1]
os.makedirs(DIR, exist_ok=True)
MODE = os.path.join(DIR, "mode.txt")


def next_code():
    try:
        with open(MODE, encoding="utf-8") as f:
            mode = f.read().strip()
    except OSError:
        mode = "200"
    if mode.startswith("okleft "):
        left = int(mode.split()[1])
        if left <= 0:
            return 500
        with open(MODE, "w", encoding="utf-8") as f:
            f.write("okleft %d" % (left - 1))
        return 200
    return int(mode) if mode.isdigit() else 200


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode("utf-8", "replace")
        code = next_code()
        rec = {"code": code, "auth": self.headers.get("Authorization") or "", "body": body}
        with open(os.path.join(DIR, "requests.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port"), "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
