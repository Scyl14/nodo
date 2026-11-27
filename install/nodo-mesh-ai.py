#!/usr/bin/env python3
"""Watch the Meshtastic radio. A text that starts with /ai is asked of the local model.

The reply is sent back to that radio. A reply longer than one packet is split on
character boundaries into 220-byte messages, numbered 1/N. The language is whatever
the question used. No radio, or a busy serial port, just waits and tries again.
"""

import json
import os
import threading
import time
import urllib.error
import urllib.request

LLM = os.environ.get("NODO_LLM_URL", "http://127.0.0.1:8081/v1/chat/completions")
NODES = os.environ.get("NODO_NODES", "/run/nodo/nodes.json")
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


def ask(question):
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


def main():
    import glob
    from pubsub import pub
    from meshtastic.serial_interface import SerialInterface

    busy = threading.Lock()

    def send(interface, destination, channel, text):
        for part in pack(text):
            interface.sendText(part, destinationId=destination, channelIndex=channel or 0)
            time.sleep(2)

    def on_receive(packet, interface):
        me = getattr(getattr(interface, "myInfo", None), "my_node_num", None)
        sender = packet.get("from")
        if sender is None or sender == me:
            return
        text = message_text(packet)
        if not text:
            return
        stripped = text.strip()
        head = stripped.lower()
        if head == "/ai":
            question = ""
        elif head.startswith("/ai ") or head.startswith("/ai\n"):
            question = stripped[3:].strip()
        else:
            return
        channel = packet.get("channel", 0)
        if not question:
            send(interface, sender, channel, "Write the question after /ai")
            return
        if not busy.acquire(blocking=False):
            send(interface, sender, channel, "Busy. Send /ai again in a moment.")
            return
        try:
            try:
                answer = ask(question).strip()
            except (urllib.error.URLError, TimeoutError, KeyError, json.JSONDecodeError):
                answer = "The model is not running on this machine."
            if not answer:
                answer = "No answer."
            send(interface, sender, channel, answer)
        finally:
            busy.release()

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
            while True:
                time.sleep(30)
                write_nodes(interface, ports[0])
        finally:
            try:
                interface.close()
            except Exception:
                pass
            time.sleep(5)


if __name__ == "__main__":
    main()
