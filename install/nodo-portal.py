#!/usr/bin/env python3
"""Same-origin API for the Nodo page. The browser never talks to the model port."""

import json
import os
import re
import sqlite3
import subprocess
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LLM = os.environ.get("NODO_LLM_URL", "http://127.0.0.1:8081/v1/chat/completions")
CHAT_DIR = os.environ.get("NODO_CHAT_DIR", "/var/lib/nodo/chats")
LIBRARY = os.environ.get("NODO_LIBRARY", "/var/lib/nodo/library")
FILES = os.environ.get("NODO_FILES", "/var/lib/nodo/files")
NODES = os.environ.get("NODO_NODES", "/run/nodo/nodes.json")
INBOX = os.environ.get("NODO_INBOX", "/var/lib/nodo/inbox.jsonl")
RADIO = os.environ.get("NODO_RADIO", "/etc/nodo/radio.json")
OUTBOX = os.environ.get("NODO_OUTBOX", "/var/lib/nodo/radio-outbox.jsonl")
KIOSK = os.environ.get("NODO_KIOSK", "/etc/nodo/kiosk")
HOST = "127.0.0.1"
PORT = 8090


def library_root():
    candidates = [LIBRARY, os.path.join(LIBRARY, "Library"), os.path.join(LIBRARY, "library.noindex")]
    for path in candidates:
        if os.path.isfile(os.path.join(path, "index.sqlite")):
            return path
    return None


def note_hits(query):
    notes = [
        ("note:water", "Water", "Drinking water when the tap stops"),
        ("note:aid", "First aid", "Bleeding: first steps"),
        ("note:power", "Power", "Keep the node running"),
        ("note:radio", "Radio", "What each radio is for"),
    ]
    words = [word for word in re.findall(r"[\w']+", query.lower()) if len(word) > 1]
    found = []
    for ident, source, title in notes:
        if not words or any(word in f"{source} {title}".lower() for word in words):
            found.append({"id": ident, "title": title, "source": "Nodo notes"})
    return found


def file_hits(query):
    if not os.path.isdir(FILES):
        return []
    words = [word for word in re.findall(r"[\w']+", query.lower()) if len(word) > 1]
    found = []
    for name in sorted(os.listdir(FILES)):
        if name.startswith(".") or name.upper().startswith("README"):
            continue
        path = os.path.join(FILES, name)
        if not os.path.isfile(path):
            continue
        if words and not any(word in name.lower() for word in words):
            continue
        found.append({"id": "file:" + name, "title": name, "source": "Your files"})
    return found


def open_index():
    root = library_root()
    if not root:
        return None, None
    database = sqlite3.connect(f"file:{os.path.join(root, 'index.sqlite')}?mode=ro", uri=True)
    return database, os.path.join(root, "text")


def search_index(query, offset, limit):
    database, _text = open_index()
    if database is None:
        return [], 0, False
    try:
        total = database.execute("SELECT COUNT(*) FROM docs").fetchone()[0]
        if not query.strip():
            rows = database.execute(
                "SELECT d.id, d.title, s.label FROM docs d JOIN sources s ON s.id = d.source_id ORDER BY d.id LIMIT ? OFFSET ?",
                (limit, offset),
            ).fetchall()
            hits = [{"id": f"doc:{row[0]}", "title": row[1] or "Untitled", "source": row[2] or ""} for row in rows]
            return hits, total, offset + limit < total
        words = [word for word in re.findall(r"[\w']+", query.lower()) if len(word) > 1][:12]
        if not words:
            return [], total, False
        terms = " OR ".join('"' + word.replace('"', "") + '"' for word in words)
        try:
            ranked = database.execute(
                "SELECT rowid FROM fts WHERE fts MATCH ? AND rank MATCH 'bm25(4.0, 1.0)' ORDER BY rank LIMIT 300",
                (terms,),
            ).fetchall()
        except sqlite3.OperationalError:
            return [], total, False
        if not ranked:
            return [], total, False
        marks = ",".join("?" * len(ranked))
        ids = [row[0] for row in ranked]
        info = database.execute(
            f"SELECT p.id, d.id, d.title, s.label FROM passages p JOIN docs d ON d.id = p.doc_id JOIN sources s ON s.id = d.source_id WHERE p.id IN ({marks})",
            ids,
        ).fetchall()
        seen = set()
        hits = []
        order = {row[0]: index for index, row in enumerate(ranked)}
        for row in sorted(info, key=lambda item: order.get(item[0], 9999)):
            if row[1] in seen:
                continue
            seen.add(row[1])
            hits.append({"id": f"doc:{row[1]}", "title": row[2] or "Untitled", "source": row[3] or ""})
            if len(hits) >= limit:
                break
        return hits, total, False
    finally:
        database.close()


def read_bytes(database, text_dir, file_id, offset, length):
    row = database.execute("SELECT path FROM files WHERE id=?", (file_id,)).fetchone()
    if not row:
        return b""
    path = os.path.normpath(os.path.join(text_dir, row[0]))
    if os.path.commonpath([text_dir, path]) != os.path.normpath(text_dir):
        return b""
    with open(path, "rb") as handle:
        handle.seek(max(0, offset))
        return handle.read(max(0, length))


NOTES = {
    "water": "Drinking water when the tap stops\n\nBoil clear water for one minute, then let it cool before drinking. If the water is cloudy, let it settle and pour off the clear part first. Store cooled water in clean, covered containers. A local note is not a treatment plant: when in doubt, do not drink it.",
    "aid": "Bleeding: first steps\n\nPress a clean cloth firmly on the wound and keep pressing. If blood soaks through, add another cloth. Do not remove the first one. Raise the injured part if you can do that without making the pain much worse. This is an aid, not a clinician. Get a person with medical training as soon as you can.",
    "power": "Keep the node running\n\nThe node is a laptop. Dim the screen, close unused work, and prefer the battery you already charged. A power bank helps. The web console, the small model, and the saved library stay available with the internet unplugged. New models and new archives do not.",
    "radio": "What each radio is for\n\nThe network card this machine already has carries this console. Meshtastic needs a LoRa board for each person and only carries short text. Bitchat is a phone app over Bluetooth. FM listening needs a separate USB receiver. None of these is a replacement for the public telephone network.",
}


def read_item(ident):
    if ident.startswith("note:"):
        body = NOTES.get(ident[5:])
        if not body:
            return {"error": "That note is not on this machine."}
        title, _, text = body.partition("\n\n")
        return {"title": title, "source": "Nodo notes", "license": "", "text": text}
    if ident.startswith("file:"):
        name = ident[5:]
        if not name or "/" in name or name.startswith("."):
            return {"error": "That file is not available."}
        path = os.path.join(FILES, name)
        if not os.path.isfile(path):
            return {"error": "That file is not on disk."}
        if name.lower().endswith(".pdf"):
            try:
                text = subprocess.check_output(["pdftotext", "-layout", path, "-"], stderr=subprocess.DEVNULL, timeout=30)
            except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
                return {"title": name, "source": "Your files", "license": "", "text": "This PDF is on disk, but this machine could not extract its text."}
            return {"title": name, "source": "Your files", "license": "", "text": text.decode("utf-8", "replace")[:500000]}
        with open(path, "rb") as handle:
            raw = handle.read(500000)
        return {"title": name, "source": "Your files", "license": "", "text": raw.decode("utf-8", "replace")}
    if not ident.startswith("doc:"):
        return {"error": "Unknown text."}
    try:
        doc_id = int(ident[4:])
    except ValueError:
        return {"error": "Unknown text."}
    database, text_dir = open_index()
    if database is None:
        return {"error": "The imported library is not installed yet."}
    try:
        row = database.execute(
            "SELECT d.title, s.label, d.file_id, d.offset, d.length FROM docs d JOIN sources s ON s.id = d.source_id WHERE d.id=?",
            (doc_id,),
        ).fetchone()
        if not row:
            return {"error": "That text is not in the library."}
        try:
            raw = read_bytes(database, text_dir, row[2], row[3], min(row[4], 500000))
        except OSError:
            return {"error": "The text file could not be opened."}
        text = raw.decode("utf-8", "replace")
        if row[4] > 500000:
            text += "\n\nThis text was cut at 500,000 characters."
        return {"title": row[0] or "Untitled", "source": row[1] or "", "license": "", "text": text}
    finally:
        database.close()


def library_payload(query, offset):
    limit = 40
    indexed, total, more = search_index(query, offset, limit)
    extra = note_hits(query) + file_hits(query) if offset == 0 else []
    hits = extra + indexed
    if library_root():
        summary = f"{total} imported texts."
        if query.strip():
            summary = f"{len(indexed)} matches in {total} imported texts."
    else:
        summary = "The large library is not installed yet. These are the notes and files already on disk."
        more = False
    return {"hits": hits, "summary": summary, "more": more}


def radio_state():
    try:
        with open(RADIO, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        data = {}
    return {
        "meshtasticLong": str(data.get("meshtasticLong") or "")[:36],
        "meshtasticShort": str(data.get("meshtasticShort") or "")[:4],
        "bitchatName": str(data.get("bitchatName") or "")[:20],
    }


def inbox_state():
    messages = []
    try:
        with open(INBOX, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    messages.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        messages = []
    return {"messages": messages[-200:], "radio": radio_state()}


def save_radio(payload):
    os.makedirs(os.path.dirname(RADIO), exist_ok=True)
    current = radio_state()
    for key, limit in (("meshtasticLong", 36), ("meshtasticShort", 4), ("bitchatName", 20)):
        if key in payload and isinstance(payload[key], str):
            current[key] = payload[key].strip()[:limit]
    with open(RADIO, "w", encoding="utf-8") as handle:
        json.dump(current, handle)
    return current


def queue_radio(payload):
    via = payload.get("via")
    if via not in ("meshtastic", "bitchat"):
        return {"error": "Choose Meshtastic or Bitchat."}
    text = str(payload.get("text") or "").strip()
    who = str(payload.get("to") or "").strip()
    if not text or not who:
        return {"error": "A message needs a person and some text."}
    os.makedirs(os.path.dirname(OUTBOX), exist_ok=True)
    record = {"via": via, "to": who[:80], "text": text[:400]}
    with open(OUTBOX, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record) + "\n")
    return {"queued": True}


def kiosk_state():
    try:
        with open(KIOSK, encoding="utf-8") as handle:
            on = handle.read().strip() == "on"
    except OSError:
        on = False
    return {"on": on}


def set_kiosk(on):
    os.makedirs(os.path.dirname(KIOSK), exist_ok=True)
    with open(KIOSK, "w", encoding="utf-8") as handle:
        handle.write("on\n" if on else "off\n")
    command = ["systemctl", "enable", "--now", "nodo-kiosk.service"] if on else ["systemctl", "disable", "--now", "nodo-kiosk.service"]
    subprocess.run(command, timeout=20, check=False)
    return kiosk_state()


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
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)
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
        if path == "/library":
            text = query.get("q", [""])[0][:200]
            try:
                offset = max(0, int(query.get("offset", ["0"])[0]))
            except ValueError:
                offset = 0
            self.send_json(200, library_payload(text, offset))
            return
        if path == "/library/read":
            ident = query.get("id", [""])[0][:300]
            self.send_json(200, read_item(ident))
            return
        if path == "/kiosk":
            self.send_json(200, kiosk_state())
            return
        if path == "/inbox":
            self.send_json(200, inbox_state())
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
        if path in ("/radio", "/radio/send", "/kiosk"):
            try:
                payload = json.loads(raw.decode())
            except json.JSONDecodeError:
                self.send_json(400, {"error": "Not a radio request."})
                return
            if not isinstance(payload, dict):
                self.send_json(400, {"error": "Not a radio request."})
                return
            if path == "/kiosk":
                self.send_json(200, set_kiosk(bool(payload.get("on"))))
                return
            if path == "/radio":
                self.send_json(200, save_radio(payload))
                return
            result = queue_radio(payload)
            self.send_json(400 if "error" in result else 200, result)
            return
        self.send_json(404, {"error": "Not found."})


if __name__ == "__main__":
    os.makedirs(CHAT_DIR, exist_ok=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
