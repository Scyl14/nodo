#!/bin/bash
# Meshtastic inbox plus the Bitchat terminal identity.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(id -u)" -eq 0 ]] || { printf 'Run as root: sudo ./install/enable-radio.sh\n' >&2; exit 1; }
"${ROOT}/install/enable-mesh-ai.sh"
"${ROOT}/install/enable-bitchat.sh"
printf 'Open Messages in the console. Direct messages to these names are listed there.\n'
