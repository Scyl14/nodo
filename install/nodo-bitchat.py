#!/usr/bin/env python3
"""Run the Bitchat terminal client and copy direct messages into the owner inbox.

The upstream program is a full-screen terminal and keeps no log. This watches its
debug output for private messages and can send a /dm typed in the console.
"""

import json
import os
import pty
import re
import select
import time

INBOX = os.environ.get("NODO_INBOX", "/var/lib/nodo/inbox.jsonl")
RADIO = os.environ.get("NODO_RADIO", "/etc/nodo/radio.json")
OUTBOX = os.environ.get("NODO_OUTBOX", "/var/lib/nodo/radio-outbox.jsonl")
BIN = os.environ.get("NODO_BITCHAT", "/usr/local/bin/bitchat")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def nickname():
    try:
        with open(RADIO, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return "nodo"
    name = str(data.get("bitchatName") or "nodo").strip()
    return "".join(ch for ch in name if ch.isalnum() or ch in "-_")[:20] or "nodo"


def log_message(who, text):
    os.makedirs(os.path.dirname(INBOX), exist_ok=True)
    record = {
        "at": int(time.time() * 1000),
        "via": "bitchat",
        "direction": "in",
        "who": who[:80],
        "text": text[:2000],
        "direct": True,
    }
    with open(INBOX, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record) + "\n")


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
            who = "".join(ch for ch in str(item.get("to") or "") if ch.isalnum() or ch in "-_")[:20]
            text = str(item.get("text") or "").replace("\n", " ").strip()[:400]
            if who and text:
                os.write(master, f"/dm {who} {text}\n".encode())
                record = {
                    "at": int(time.time() * 1000),
                    "via": "bitchat",
                    "direction": "out",
                    "who": who,
                    "text": text,
                    "direct": True,
                }
                with open(INBOX, "a", encoding="utf-8") as inbox:
                    inbox.write(json.dumps(record) + "\n")
        if kept:
            handle.writelines(kept)
        fcntl.flock(handle, fcntl.LOCK_UN)


def note_line(line):
    clean = ANSI.sub("", line).strip()
    if not clean or clean.startswith("/"):
        return
    lowered = clean.lower()
    if "dm" not in lowered and "priv" not in lowered and "whisper" not in lowered:
        return
    who = "bitchat"
    text = clean
    match = re.search(r"(?:dm|priv|whisper)[^A-Za-z0-9]+([A-Za-z0-9_-]{1,20})", clean, re.I)
    if match:
        who = match.group(1)
    log_message(who, text)


def main():
    if not os.path.isfile(BIN):
        raise SystemExit(f"Missing {BIN}. Run sudo ./install/enable-bitchat.sh")
    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.execv(BIN, [BIN, "-dd"])
    os.close(slave)
    os.write(master, f"/name {nickname()}\n".encode())
    buffer = b""
    current = nickname()
    while True:
        alive, _status = os.waitpid(pid, os.WNOHANG)
        if alive:
            break
        ready, _, _ = select.select([master], [], [], 2)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                note_line(line.decode("utf-8", "replace"))
        name = nickname()
        if name != current:
            os.write(master, f"/name {name}\n".encode())
            current = name
        drain(master)


if __name__ == "__main__":
    main()
