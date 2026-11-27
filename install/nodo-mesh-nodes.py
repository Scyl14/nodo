#!/usr/bin/env python3
"""Write Meshtastic nodes this machine can hear. No radio means an empty list."""

import glob
import json
import os

OUT = os.environ.get("NODO_NODES", "/run/nodo/nodes.json")


def write(payload):
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".partial"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    os.replace(tmp, OUT)


def main():
    ports = sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*"))
    if not ports:
        write({"radio": None, "nodes": [], "note": "No USB radio is connected."})
        return
    try:
        from meshtastic.serial_interface import SerialInterface
    except ImportError:
        write({"radio": ports[0], "nodes": [], "note": "The meshtastic Python package is not installed."})
        return
    iface = SerialInterface(ports[0])
    try:
        nodes = []
        for node_id, node in (iface.nodes or {}).items():
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
        write({"radio": ports[0], "nodes": nodes, "note": "Only nodes this radio has heard. A node without a position is not pinned."})
    finally:
        iface.close()


if __name__ == "__main__":
    main()
