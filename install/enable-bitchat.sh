#!/bin/bash
# Install the Bitchat terminal client and run it under the owner's chosen name.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(id -u)" -eq 0 ]] || { printf 'Run as root: sudo ./install/enable-bitchat.sh\n' >&2; exit 1; }
[[ -f "${ROOT}/install/nodo-bitchat.py" ]] || { printf 'Missing install/nodo-bitchat.py\n' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl build-essential pkg-config libdbus-1-dev bluez

if ! command -v cargo >/dev/null 2>&1 || ! cargo --version | grep -qE '1\.(8[5-9]|9[0-9])|cargo 2'; then
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck disable=SC1091
  source /root/.cargo/env
fi
cargo install --git https://github.com/ShilohEye/bitchat-terminal --root /usr/local --locked || \
  cargo install --git https://github.com/ShilohEye/bitchat-terminal --root /usr/local

install -d -m 0755 /etc/nodo /usr/local/sbin /var/lib/nodo
if [[ ! -f /etc/nodo/radio.json ]]; then
  printf '%s\n' '{"meshtasticLong":"Nodo","meshtasticShort":"NOD","bitchatName":"nodo"}' > /etc/nodo/radio.json
fi
install -m 0755 "${ROOT}/install/nodo-bitchat.py" /usr/local/sbin/nodo-bitchat.py

cat > /etc/systemd/system/nodo-bitchat.service <<'EOF'
[Unit]
Description=Bitchat terminal bridge
After=bluetooth.target

[Service]
Type=simple
Environment=NODO_BITCHAT=/usr/local/bin/bitchat
ExecStart=/usr/bin/python3 /usr/local/sbin/nodo-bitchat.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now bluetooth.service || true
systemctl enable --now nodo-bitchat.service
printf 'Bitchat CLI is installed. Set the name in the Messages tab.\n'
printf 'This client is unofficial. Private messages are not a finished, audited protocol.\n'
