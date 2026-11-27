#!/usr/bin/env python3
"""Run the Bitchat terminal client. A message that starts with /ai is asked of the local model.

The reply goes back as a private message. A long reply is split into 220-byte
parts, the same way the Meshtastic radio does. Direct messages are stored for
the owner. The language is whatever the question used.
"""

import json
import os
import pty
import queue
import re
import select
import threading
import time
import urllib.error
import urllib.request

INBOX = os.environ.get("NODO_INBOX", "/var/lib/nodo/inbox.jsonl")
RADIO = os.environ.get("NODO_RADIO", "/etc/nodo/radio.json")
OUTBOX = os.environ.get("NODO_OUTBOX", "/var/lib/nodo/radio-outbox.jsonl")
LLM = os.environ.get("NODO_LLM_URL", "http://127.0.0.1:8081/v1/chat/completions")
BIN = os.environ.get("NODO_BITCHAT", "/usr/local/bin/bitchat")
LIMIT = 220
MAX_PARTS = 12
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
INCOMING_DM = re.compile(r"^\[[^\]]+\|DM\]\s*<(.+?)\s*→\s*you>\s*(.*)$")
OUTGOING_DM = re.compile(r"^\[[^\]]+\|DM\]\s*<you\s*→")
INCOMING_CHANNEL = re.compile(r"^\[[^\]]+\]\s*<(.+?)\s*@\s*[^>]+>\s*(.*)$")
INCOMING_PUBLIC = re.compile(r"^\[[^\]]*\]\s*<([^>@]+?)>\s*(.*)$")


def nickname():
    try:
        with open(RADIO, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return "nodo"
    name = str(data.get("bitchatName") or "nodo").strip()
    return "".join(ch for ch in name if ch.isalnum() or ch in "-_")[:20] or "nodo"


def split_text(text, limit):
    raw = text.encode("utf-8")
    parts = []
    index = 0
    while index < len(raw):
        end = min(index + limit, len(raw))
        if end < len(raw):
            while end > index and (raw[end] & 0xC0) == 0x80:
                end -= 1
        if end == index:
            end = min(index + limit, len(raw))
        parts.append(raw[index:end].decode("utf-8", "ignore"))
        index = end
    return [part for part in parts if part]


def pack(text):
    body = " ".join(text.split())
    if not body:
        return []
    bare = split_text(body, LIMIT)
    if len(bare) <= 1:
        return bare
    width = len(f"{min(len(bare), MAX_PARTS)}/{min(len(bare), MAX_PARTS)} ")
    pieces = split_text(body, LIMIT - width)
    if len(pieces) > MAX_PARTS:
        pieces = pieces[:MAX_PARTS]
    total = len(pieces)
    return [f"{number}/{total} {piece}" for number, piece in enumerate(pieces, 1)]


def ask(question):
    """One question, with no earlier turns. A new /ai does not continue the last one."""
    payload = json.dumps({
        "messages": [{"role": "user", "content": question}],
        "temperature": 0.3,
    }).encode()
    request = urllib.request.Request(LLM, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=300) as response:
        data = json.loads(response.read().decode())
    return data["choices"][0]["message"]["content"]


def log_message(direction, who, text, direct):
    os.makedirs(os.path.dirname(INBOX), exist_ok=True)
    record = {
        "at": int(time.time() * 1000),
        "via": "bitchat",
        "direction": direction,
        "who": str(who)[:80],
        "text": text[:2000],
        "direct": bool(direct),
    }
    with open(INBOX, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record) + "\n")


def parse_line(line):
    """Return (sender, text, direct) for a message from someone else, or None."""
    clean = ANSI.sub("", line).strip()
    if not clean or OUTGOING_DM.match(clean):
        return None
    match = INCOMING_DM.match(clean)
    if match:
        return match.group(1).strip(), match.group(2).strip(), True
    match = INCOMING_CHANNEL.match(clean)
    if match:
        return match.group(1).strip(), match.group(2).strip(), False
    match = INCOMING_PUBLIC.match(clean)
    if match:
        sender = match.group(1).strip()
        if sender.lower() == nickname().lower():
            return None
        return sender, match.group(2).strip(), False
    return None


def command_of(text):
    stripped = text.strip()
    head = stripped.lower()
    if head == "/ai":
        return ""
    if head.startswith("/ai ") or head.startswith("/ai\n"):
        return stripped[3:].strip()
    return None


def target_name(sender):
    token = sender.strip().split()
    return "".join(ch for ch in (token[0] if token else "") if ch.isalnum() or ch in "-_")[:20]


def send_dm(master, sender, text):
    who = target_name(sender)
    if not who:
        return
    for part in pack(text):
        os.write(master, f"/dm {who} {part}\n".encode())
        log_message("out", who, part, True)
        time.sleep(0.4)


def drain(master):
    if not os.path.exists(OUTBOX):
        return
    import fcntl
    with open(OUTBOX, "r+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        lines = handle.readlines()
        handle.seek(0)
        handle.truncate()
        kept = []
        for line in lines:
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if item.get("via") != "bitchat":
                kept.append(line if line.endswith("\n") else line + "\n")
                continue
            who = target_name(str(item.get("to") or ""))
            text = " ".join(str(item.get("text") or "").split())
            if who and text:
                for part in pack(text):
                    os.write(master, f"/dm {who} {part}\n".encode())
                    log_message("out", who, part, True)
                    time.sleep(0.4)
        if kept:
            handle.writelines(kept)
        fcntl.flock(handle, fcntl.LOCK_UN)


def main():
    if not os.path.isfile(BIN):
        raise SystemExit(f"Missing {BIN}. Run sudo ./install/enable-bitchat.sh")
    answers = queue.Queue()
    busy = threading.Lock()

    def work(sender, question):
        if not question:
            answer = "Write the question after /ai"
        else:
            try:
                answer = ask(question).strip() or "No answer."
            except (urllib.error.URLError, TimeoutError, KeyError, json.JSONDecodeError):
                answer = "The model is not running on this machine."
        answers.put((sender, answer))

    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.execv(BIN, [BIN])
    os.close(slave)
    os.write(master, f"/name {nickname()}\n".encode())
    buffer = b""
    current = nickname()
    seen = []
    while True:
        alive, _status = os.waitpid(pid, os.WNOHANG)
        if alive:
            break
        try:
            sender, answer = answers.get_nowait()
        except queue.Empty:
            sender = None
        if sender:
            send_dm(master, sender, answer)
            busy.release()
        ready, _, _ = select.select([master], [], [], 1)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                parsed = parse_line(raw.decode("utf-8", "replace"))
                if not parsed:
                    continue
                sender, text, direct = parsed
                key = (sender, text)
                if key in seen:
                    continue
                seen.append(key)
                seen[:] = seen[-40:]
                question = command_of(text)
                if direct or question is not None:
                    log_message("in", sender, text, direct)
                if question is None:
                    continue
                if not busy.acquire(blocking=False):
                    send_dm(master, sender, "Busy. Send /ai again in a moment.")
                    continue
                threading.Thread(target=work, args=(sender, question), daemon=True).start()
        name = nickname()
        if name != current:
            os.write(master, f"/name {name}\n".encode())
            current = name
        drain(master)


if __name__ == "__main__":
    main()
