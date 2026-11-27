#!/usr/bin/env python3
"""Watch the Meshtastic radio. A text that starts with /ai is asked of the local model.

The reply is sent back to that radio. A reply longer than one packet is split on
character boundaries into 220-byte messages, numbered 1/N. The language is whatever
the question used. No radio, or a busy serial port, just waits and tries again.
"""

import json
import os
import queue
import threading
import time
import urllib.error
import urllib.request

LLM = os.environ.get("NODO_LLM_URL", "http://127.0.0.1:8081/v1/chat/completions")
NODES = os.environ.get("NODO_NODES", "/run/nodo/nodes.json")
INBOX = os.environ.get("NODO_INBOX", "/var/lib/nodo/inbox.jsonl")
RADIO = os.environ.get("NODO_RADIO", "/etc/nodo/radio.json")
OUTBOX = os.environ.get("NODO_OUTBOX", "/var/lib/nodo/radio-outbox.jsonl")
LIMIT = 220
MAX_PARTS = 12


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
    cut = False
    if len(pieces) > MAX_PARTS:
        pieces = pieces[:MAX_PARTS]
        cut = True
    total = len(pieces)
    packed = [f"{number}/{total} {piece}" for number, piece in enumerate(pieces, 1)]
    if cut:
        note = f"{total}/{total} …"
        packed[-1] = note if len(note.encode()) + 1 + len(packed[-1].encode()) > LIMIT else packed[-1] + " …"
        if len(packed[-1].encode()) > LIMIT:
            packed[-1] = split_text(packed[-1], LIMIT)[0]
    return packed


def log_message(via, direction, who, text, direct):
    os.makedirs(os.path.dirname(INBOX), exist_ok=True)
    record = {
        "at": int(time.time() * 1000),
        "via": via,
        "direction": direction,
        "who": str(who),
        "text": text[:2000],
        "direct": bool(direct),
    }
    with open(INBOX, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record) + "\n")


def radio_names():
    try:
        with open(RADIO, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return "", ""
    long_name = str(data.get("meshtasticLong") or "").strip()[:36]
    short_name = str(data.get("meshtasticShort") or "").strip()[:4]
    return long_name, short_name


def apply_name(interface):
    long_name, short_name = radio_names()
    if not long_name:
        return
    key = (long_name, short_name)
    if getattr(interface, "_nodo_name", None) == key:
        return
    try:
        interface.getNode("^local").setOwner(long_name=long_name, short_name=short_name or long_name[:4])
        interface._nodo_name = key
    except Exception:
        return


def drain_outbox(interface):
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
            if item.get("via") != "meshtastic":
                kept.append(line if line.endswith("\n") else line + "\n")
                continue
            text = str(item.get("text") or "").strip()
            destination = item.get("to")
            if not text or destination in (None, ""):
                continue
            channel = int(item.get("channel") or 0)
            try:
                for part in pack(text):
                    interface.sendText(part, destinationId=destination, channelIndex=channel)
                    log_message("meshtastic", "out", destination, part, True)
                    time.sleep(2)
            except Exception:
                kept.append(line if line.endswith("\n") else line + "\n")
        if kept:
            handle.writelines(kept)
        fcntl.flock(handle, fcntl.LOCK_UN)
    payload = json.dumps({
        "messages": [{"role": "user", "content": question}],
        "temperature": 0.3,
    }).encode()
    request = urllib.request.Request(LLM, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=300) as response:
        data = json.loads(response.read().decode())
    return data["choices"][0]["message"]["content"]


def write_nodes(interface, port):
    nodes = []
    for node_id, node in (interface.nodes or {}).items():
        user = node.get("user") or {}
        pos = node.get("position") or {}
        item = {
            "id": str(node_id),
            "name": user.get("longName") or user.get("shortName") or str(node_id),
            "short": user.get("shortName") or "",
        }
        lat = pos.get("latitude")
        lon = pos.get("longitude")
        if isinstance(lat, (int, float)) and isinstance(lon, (int, float)):
            item["lat"] = lat
            item["lon"] = lon
        nodes.append(item)
    os.makedirs(os.path.dirname(NODES), exist_ok=True)
    tmp = NODES + ".partial"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump({"radio": port, "nodes": nodes, "note": "Only nodes this radio has heard."}, handle)
    os.replace(tmp, NODES)


def message_text(packet):
    decoded = packet.get("decoded") or {}
    port = decoded.get("portnum")
    if port not in ("TEXT_MESSAGE_APP", 1):
        return None
    text = decoded.get("text")
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    return text if isinstance(text, str) else None


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


def main():
    import glob
    from pubsub import pub
    from meshtastic.serial_interface import SerialInterface

    busy = threading.Lock()
    outgoing = queue.Queue()

    def send(interface, destination, channel, text):
        for part in pack(text):
            interface.sendText(part, destinationId=destination, channelIndex=channel or 0)
            time.sleep(2)

    def work(sender, channel, who, question):
        try:
            answer = ask(question).strip() or "No answer."
        except (urllib.error.URLError, TimeoutError, KeyError, json.JSONDecodeError):
            answer = "The model is not running on this machine."
        outgoing.put((True, sender, channel, who, answer))

    def on_receive(packet, interface):
        me = getattr(getattr(interface, "myInfo", None), "my_node_num", None)
        sender = packet.get("from")
        if sender is None or sender == me:
            return
        text = message_text(packet)
        if not text:
            return
        destination = packet.get("to")
        direct = destination not in (None, 0xFFFFFFFF, 4294967295)
        who = sender
        try:
            node = (interface.nodes or {}).get(sender) or (interface.nodes or {}).get(str(sender)) or {}
            user = node.get("user") or {}
            who = user.get("longName") or user.get("shortName") or sender
        except Exception:
            who = sender
        stripped = text.strip()
        head = stripped.lower()
        if direct or head == "/ai" or head.startswith("/ai ") or head.startswith("/ai\n"):
            log_message("meshtastic", "in", who, stripped, direct)
        channel = packet.get("channel", 0)
        if head == "/ai":
            question = ""
        elif head.startswith("/ai ") or head.startswith("/ai\n"):
            question = stripped[3:].strip()
        else:
            return
        if not question:
            outgoing.put((False, sender, channel, who, "Write the question after /ai"))
            return
        if not busy.acquire(blocking=False):
            outgoing.put((False, sender, channel, who, "Busy. Send /ai again in a moment."))
            return
        threading.Thread(target=work, args=(sender, channel, who, question), daemon=True).start()

    pub.subscribe(on_receive, "meshtastic.receive")
    while True:
        ports = sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*"))
        if not ports:
            time.sleep(10)
            continue
        try:
            interface = SerialInterface(ports[0])
        except Exception:
            time.sleep(10)
            continue
        try:
            write_nodes(interface, ports[0])
            apply_name(interface)
            ticks = 0
            while True:
                while True:
                    try:
                        is_answer, sender, channel, who, text = outgoing.get_nowait()
                    except queue.Empty:
                        break
                    try:
                        send(interface, sender, channel, text)
                        if is_answer:
                            log_message("meshtastic", "out", who, text, True)
                    finally:
                        if is_answer:
                            busy.release()
                drain_outbox(interface)
                time.sleep(1)
                ticks += 1
                if ticks % 30 == 0:
                    write_nodes(interface, ports[0])
                    apply_name(interface)
        finally:
            try:
                interface.close()
            except Exception:
                pass
            time.sleep(5)


if __name__ == "__main__":
    main()
