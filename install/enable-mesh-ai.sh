#!/bin/bash
# Listen for /ai on the Meshtastic radio and answer from the local model.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(id -u)" -eq 0 ]] || { printf 'Run as root: sudo ./install/enable-mesh-ai.sh\n' >&2; exit 1; }
[[ -x /opt/nodo/venv/bin/python ]] || { printf 'Missing /opt/nodo/venv. Run sudo ./install.sh first.\n' >&2; exit 1; }
[[ -f "${ROOT}/install/nodo-mesh-ai.py" ]] || { printf 'Missing install/nodo-mesh-ai.py\n' >&2; exit 1; }

/opt/nodo/venv/bin/pip install -q meshtastic || true
install -m 0755 "${ROOT}/install/nodo-mesh-ai.py" /usr/local/sbin/nodo-mesh-ai.py

cat > /etc/systemd/system/nodo-mesh-ai.service <<'EOF'
[Unit]
Description=Answer /ai messages from the Meshtastic radio
After=network.target nodo-llm.service

[Service]
Type=simple
Environment=NODO_LLM_URL=http://127.0.0.1:8081/v1/chat/completions
Environment=NODO_NODES=/run/nodo/nodes.json
ExecStart=/opt/nodo/venv/bin/python /usr/local/sbin/nodo-mesh-ai.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl disable --now nodo-mesh.timer >/dev/null 2>&1 || true
systemctl enable --now nodo-mesh-ai.service
printf 'The radio now listens for /ai. A long answer is split into 220-byte messages.\n'
