#!/usr/bin/env python3
"""Same-origin API for the Nodo page. The browser never talks to the model port."""

import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LLM = os.environ.get("NODO_LLM_URL", "http://127.0.0.1:8081/v1/chat/completions")
CHAT_DIR = os.environ.get("NODO_CHAT_DIR", "/var/lib/nodo/chats")
NODES = os.environ.get("NODO_NODES", "/run/nodo/nodes.json")
HOST = "127.0.0.1"
PORT = 8090


def disk():
    path = CHAT_DIR if os.path.isdir(CHAT_DIR) else "/"
    st = os.statvfs(path)
    chats = 0
    if os.path.isdir(CHAT_DIR):
        for name in os.listdir(CHAT_DIR):
            full = os.path.join(CHAT_DIR, name)
            if os.path.isfile(full):
                chats += os.path.getsize(full)
    return {
        "free": st.f_bavail * st.f_frsize,
        "total": st.f_blocks * st.f_frsize,
        "chats": chats,
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length < 0 or length > 2_000_000:
            return None
        return self.rfile.read(length)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/disk":
            self.send_json(200, disk())
            return
        if path == "/nodes":
            try:
                with open(NODES, encoding="utf-8") as handle:
                    payload = json.load(handle)
            except (OSError, json.JSONDecodeError):
                payload = {"radio": None, "nodes": [], "note": "No radio report yet."}
            self.send_json(200, payload)
            return
        self.send_json(404, {"error": "Not found."})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        raw = self.read_body()
        if raw is None:
            self.send_json(400, {"error": "Request is too large."})
            return
        if path == "/chat":
            request = urllib.request.Request(LLM, data=raw, headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=300) as response:
                    data = response.read()
            except (urllib.error.URLError, TimeoutError):
                self.send_json(502, {"error": "The model is not running on this machine."})
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/archive":
            try:
                payload = json.loads(raw.decode())
            except json.JSONDecodeError:
                self.send_json(400, {"error": "Not a chat."})
                return
            os.makedirs(CHAT_DIR, exist_ok=True)
            name = payload.get("name") if isinstance(payload.get("name"), str) else ""
            name = "".join(ch for ch in name if ch.isalnum() or ch in "-_ ")[:40].strip() or "chat"
            stamp = str(int(os.times().elapsed * 1000))
            dest = os.path.join(CHAT_DIR, f"{stamp}-{name}.json")
            with open(dest, "w", encoding="utf-8") as handle:
                json.dump(payload, handle)
            self.send_json(200, {"saved": os.path.basename(dest)})
            return
        self.send_json(404, {"error": "Not found."})


if __name__ == "__main__":
    os.makedirs(CHAT_DIR, exist_ok=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
