#!/bin/bash
# Nodo installer for a machine that already runs Debian 12 or 13.
# The console uses the network card the PC already has.
# A Wi-Fi access point is optional, and only if you say yes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YES=0
CHECK=0
UNINSTALL=0

die() { printf 'nodo-install: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [--yes] [--check]

  --yes     Take the recommended model, library, and skip the map and Wi-Fi.
            Still prints every choice before it downloads.
  --uninstall
            Stop Nodo and delete its files, so the next run starts clean.
            Debian packages such as nginx stay installed.
  --check   Show what this machine would be offered. Change nothing.
  --help

Run it on Debian 12 or 13. It does not need a Wi-Fi adapter.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --check) CHECK=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ ! -t 0 && "$YES" -ne 1 && "$CHECK" -ne 1 && "$UNINSTALL" -ne 1 ]]; then
  die "No terminal to ask questions. Pass --yes or run it in a terminal."
fi

uninstall_nodo() {
  say "This removes Nodo data and services. It does not remove Debian itself."
  say "Deleted: /var/lib/nodo /opt/nodo /etc/nodo and the Nodo systemd units."
  if [[ "$CHECK" -eq 1 ]]; then
    say "Check only. Nothing was changed."
    exit 0
  fi
  [[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo ./install.sh --uninstall"
  local unit
  for unit in nodo-kiosk nodo-wifi nodo-llm nodo-portal nodo-mesh-ai nodo-mesh.timer nodo-mesh nodo-hostapd nodo-addr nodo-dnsmasq; do
    systemctl disable --now "${unit}.service" >/dev/null 2>&1 || true
    systemctl disable --now "${unit}" >/dev/null 2>&1 || true
  done
  rm -f \
    /etc/systemd/system/nodo-kiosk.service \
    /etc/systemd/system/nodo-wifi.service \
    /etc/systemd/system/nodo-llm.service \
    /etc/systemd/system/nodo-portal.service \
    /etc/systemd/system/nodo-mesh.service \
    /etc/systemd/system/nodo-mesh.timer \
    /etc/systemd/system/nodo-mesh-ai.service \
    /etc/systemd/system/nodo-hostapd.service \
    /etc/systemd/system/nodo-addr.service \
    /etc/systemd/system/nodo-dnsmasq.service \
    /etc/nginx/sites-enabled/nodo \
    /etc/nginx/sites-available/nodo \
    /usr/local/sbin/nodo-portal.py \
    /usr/local/sbin/nodo-mesh-nodes \
    /usr/local/bin/pmtiles
  rm -rf /var/lib/nodo /opt/nodo /etc/nodo /run/nodo
  systemctl daemon-reload
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  fi
  say "Nodo is removed. Run sudo ./install.sh for a fresh install."
  say "The owner password lives in the browser. Clear the site data for this address, or the old lock screen remains."
  exit 0
}

if [[ "$UNINSTALL" -eq 1 ]]; then
  uninstall_nodo
fi

debian_name="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  debian_name="${PRETTY_NAME:-unknown}"
fi

ask() {
  local prompt="$1" default="$2" reply
  if [[ "$YES" -eq 1 ]]; then
    printf '%s\n' "$default"
    return
  fi
  read -r -p "$prompt [$default] " reply
  printf '%s' "${reply:-$default}"
}

confirm_default() {
  local prompt="$1" default="$2" reply
  if [[ "$YES" -eq 1 ]]; then
    [[ "$default" == "y" ]]
    return
  fi
  read -r -p "$prompt [$default] " reply
  reply="${reply:-$default}"
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

ram_gb=0
free_gb=0
if [[ -r /proc/meminfo ]]; then
  ram_kb="$(awk '/MemTotal/ { print $2; exit }' /proc/meminfo)"
  ram_gb=$((ram_kb / 1024 / 1024))
fi
if command -v df >/dev/null 2>&1; then
  free_kb="$(df -Pk /var 2>/dev/null | awk 'NR==2 { print $4 }')"
  free_gb=$((free_kb / 1024 / 1024))
fi

recommend="3"
if ((ram_gb < 4)); then recommend="1.5"
elif ((ram_gb < 8)); then recommend="3"
elif ((ram_gb < 16)); then recommend="7"
else recommend="14"
fi

model_need_gb() {
  case "$1" in
    1.5) echo 2 ;;
    3) echo 3 ;;
    7) echo 8 ;;
    14) echo 13 ;;
    *) echo 0 ;;
  esac
}

drop_for_disk() {
  local tier="$1" need
  need="$(model_need_gb "$tier")"
  if ((free_gb > 0 && free_gb < need)); then
    case "$tier" in
      14) printf '7' ;;
      7) printf '3' ;;
      *) printf '1.5' ;;
    esac
  else
    printf '%s' "$tier"
  fi
}
recommend="$(drop_for_disk "$recommend")"
recommend="$(drop_for_disk "$recommend")"
recommend="$(drop_for_disk "$recommend")"

gpu="none"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  gpu="nvidia"
fi

say "Nodo installer"
say "  Machine: ${debian_name}"
say "  RAM: ${ram_gb} GB"
say "  Free on /var: ${free_gb} GB"
say "  GPU: ${gpu} (the same model file is used either way)"
say "  Recommended model: Qwen2.5 ${recommend}B Q4_K_M"
say "  Library Everything needs about 27 GB free during install."
say "  A map is a cut of OpenStreetMap, not the planet (about 120 GB)."

if [[ "$CHECK" -eq 1 ]]; then
  if [[ "${ID:-}" != "debian" ]]; then
    say "A real run accepts Debian 12 or 13 only."
  fi
  say "Check only. Nothing was changed."
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "Run as root, or pass --check."
[[ "${ID:-}" == "debian" && ( "${VERSION_ID:-}" == "12" || "${VERSION_ID:-}" == "13" ) ]] || die "Debian 12 or 13 only. Found ${debian_name}."

say "Installing packages. No model is downloaded yet."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates curl git python3 python3-venv python3-pip \
  iw iproute2 nginx build-essential cmake pkg-config \
  rtl-sdr bluez wireless-regdb

if apt-cache show llama.cpp >/dev/null 2>&1; then
  apt-get install -y llama.cpp || true
fi
if apt-cache show chromium >/dev/null 2>&1; then
  apt-get install -y chromium || true
elif apt-cache show chromium-browser >/dev/null 2>&1; then
  apt-get install -y chromium-browser || true
fi

say ""
say "Models, Apache-2.0, Q4_K_M. The 3B stays installed when you pick 7B or 14B."
say "  1.5   about 1.1 GB   under 4 GB of RAM"
say "  3     about 1.9 GB   4 to 8 GB"
say "  7     about 4.7 GB   8 to 16 GB, plus the 3B"
say "  14    about 9.0 GB   16 GB or more, plus the 3B"
say "  skip"
model="$(ask "Which model? Recommended is ${recommend}" "$recommend")"
case "$model" in
  1.5|3|7|14|skip) ;;
  *) die "Model must be 1.5, 3, 7, 14, or skip." ;;
esac
if [[ "$model" != "skip" ]]; then
  need="$(model_need_gb "$model")"
  if ((free_gb < need)); then
    die "About ${need} GB free are required for that model. /var has ${free_gb} GB."
  fi
fi

lib_default="skip"
if ((free_gb >= 30)); then lib_default="everything"
elif ((free_gb >= 12)); then lib_default="essentials"
fi
say ""
say "Library, the public survival-llm set. Not the private build, and not paid books."
say "  everything   about 8.8 GB down, about 21 GB installed, about 27 GB free needed"
say "  essentials   about 1.3 GB down, about 3 GB installed, about 10 GB free needed"
say "  skip"
library="$(ask "Which library? Suggested: ${lib_default}" "$lib_default")"
case "$library" in
  everything|essentials|skip) ;;
  *) die "Library must be everything, essentials, or skip." ;;
esac
if [[ "$library" == "everything" ]]; then
  reserve=0
  if [[ "$model" != "skip" ]]; then
    reserve="$(model_need_gb "$model")"
  fi
  if ((free_gb < reserve + 27)); then
    die "That model plus Everything wants about $((reserve + 27)) GB free. /var has ${free_gb} GB."
  fi
fi
if [[ "$library" == "essentials" && free_gb -lt 10 ]]; then
  die "Essentials wants about 10 GB free. /var has ${free_gb} GB."
fi

say ""
say "Offline map: one OpenStreetMap cut. Example box, west,south,east,north: 9.1,45.4,9.3,45.5"
say "Press enter to skip. A city is tens of MB. A country can be hundreds of MB."
if [[ "$YES" -eq 1 ]]; then
  bbox=""
else
  read -r -p "Bounding box, or enter to skip: " bbox
fi
if [[ -n "${bbox}" ]]; then
  [[ "$bbox" =~ ^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$ ]] || die "Box must be four numbers: west,south,east,north"
fi

wifi_iface=""
if command -v iw >/dev/null 2>&1; then
  while read -r iface; do
    [[ -n "$iface" ]] || continue
    phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ { print "phy"$2; exit }')"
    if [[ -n "$phy" ]] && iw phy "$phy" info 2>/dev/null | grep -q '\* AP'; then
      wifi_iface="$iface"
      break
    fi
  done < <(iw dev 2>/dev/null | awk '$1=="Interface" { print $2 }')
fi
do_wifi=0
if [[ -n "$wifi_iface" ]]; then
  say ""
  say "Optional Wi-Fi access point. The console does not need it. Adapter that can do it: ${wifi_iface}"
  if confirm_default "Create a Wi-Fi named Nodo on ${wifi_iface}?" "n"; then
    do_wifi=1
  fi
else
  say "No Wi-Fi adapter that can be an access point. Skipping that. The console still works on the normal network card."
fi

do_kiosk=0
if confirm_default "Open the dashboard fullscreen at boot?" "y"; then
  do_kiosk=1
fi

install -d -m 0755 \
  /etc/nodo /var/lib/nodo/models /var/lib/nodo/maps \
  /var/lib/nodo/chats /var/lib/nodo/files /var/lib/nodo/www \
  /opt/nodo /usr/local/sbin /run/nodo

cat > /var/lib/nodo/files/README.txt <<'EOF'
Put PDF files you already own in this folder.
The installer does not download paid books, and it does not download Hesperian PDFs.
EOF

fetch() {
  local url="$1" dest="$2"
  if [[ -s "$dest" ]]; then
    say "already present: $dest"
    return 0
  fi
  install -d -m 0755 "$(dirname "$dest")"
  say "downloading $url"
  curl -fL --retry 5 --retry-delay 2 -o "${dest}.partial" "$url"
  mv "${dest}.partial" "$dest"
}

hf() {
  local repo="$1" file="$2" dest="$3"
  fetch "https://huggingface.co/${repo}/resolve/main/${file}" "$dest"
}

if [[ "$model" != "skip" ]]; then
  if [[ "$model" == "1.5" || "$model" == "3" || "$model" == "7" || "$model" == "14" ]]; then
    if [[ "$model" == "1.5" ]]; then
      hf bartowski/Qwen2.5-1.5B-Instruct-GGUF Qwen2.5-1.5B-Instruct-Q4_K_M.gguf /var/lib/nodo/models/qwen2.5-1.5b-q4.gguf
      ln -sfn /var/lib/nodo/models/qwen2.5-1.5b-q4.gguf /var/lib/nodo/models/active.gguf
    fi
    if [[ "$model" == "3" || "$model" == "7" || "$model" == "14" ]]; then
      hf bartowski/Qwen2.5-3B-Instruct-GGUF Qwen2.5-3B-Instruct-Q4_K_M.gguf /var/lib/nodo/models/qwen2.5-3b-q4.gguf
      ln -sfn /var/lib/nodo/models/qwen2.5-3b-q4.gguf /var/lib/nodo/models/active.gguf
      ln -sfn /var/lib/nodo/models/qwen2.5-3b-q4.gguf /var/lib/nodo/models/small.gguf
    fi
    if [[ "$model" == "7" ]]; then
      hf bartowski/Qwen2.5-7B-Instruct-GGUF Qwen2.5-7B-Instruct-Q4_K_M.gguf /var/lib/nodo/models/qwen2.5-7b-q4.gguf
      ln -sfn /var/lib/nodo/models/qwen2.5-7b-q4.gguf /var/lib/nodo/models/active.gguf
    fi
    if [[ "$model" == "14" ]]; then
      hf bartowski/Qwen2.5-14B-Instruct-GGUF Qwen2.5-14B-Instruct-Q4_K_M.gguf /var/lib/nodo/models/qwen2.5-14b-q4.gguf
      ln -sfn /var/lib/nodo/models/qwen2.5-14b-q4.gguf /var/lib/nodo/models/active.gguf
    fi
  fi
fi

llama_bin=""
if command -v llama-server >/dev/null 2>&1; then
  llama_bin="$(command -v llama-server)"
fi
if [[ -z "$llama_bin" && "$model" != "skip" ]]; then
  say "Debian has no llama-server package. Building llama.cpp."
  if [[ ! -d /opt/nodo/src/llama.cpp/.git ]]; then
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /opt/nodo/src/llama.cpp
  fi
  cmake_args=(-B /opt/nodo/src/llama.cpp/build -S /opt/nodo/src/llama.cpp)
  if [[ "$gpu" == "nvidia" ]]; then
    cmake_args+=(-DGGML_CUDA=ON)
  else
    cmake_args+=(-DGGML_CUDA=OFF)
  fi
  cmake "${cmake_args[@]}"
  cmake --build /opt/nodo/src/llama.cpp/build --target llama-server -j"$(nproc)"
  llama_bin="/opt/nodo/src/llama.cpp/build/bin/llama-server"
fi

if [[ "$library" != "skip" ]]; then
  "${ROOT}/install/fetch-library.sh" "$library"
fi

say "Voice: Piper, and whisper.cpp base. Both can stay unused."
fetch https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz /opt/nodo/src/piper.tar.gz
if [[ ! -x /opt/nodo/piper/piper ]]; then
  tar -xzf /opt/nodo/src/piper.tar.gz -C /opt/nodo
fi
fetch https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx /var/lib/nodo/voices/en_US-lessac-medium.onnx
fetch https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json /var/lib/nodo/voices/en_US-lessac-medium.onnx.json
fetch https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/paola/medium/it_IT-paola-medium.onnx /var/lib/nodo/voices/it_IT-paola-medium.onnx
fetch https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/paola/medium/it_IT-paola-medium.onnx.json /var/lib/nodo/voices/it_IT-paola-medium.onnx.json
fetch https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin /var/lib/nodo/voices/ggml-base.bin

if [[ ! -x /opt/nodo/whisper/build/bin/whisper-cli && ! -x /opt/nodo/src/whisper.cpp/build/bin/whisper-cli ]]; then
  if [[ ! -d /opt/nodo/src/whisper.cpp/.git ]]; then
    git clone --depth 1 --branch v1.9.6 https://github.com/ggml-org/whisper.cpp.git /opt/nodo/src/whisper.cpp
  fi
  cmake -B /opt/nodo/src/whisper.cpp/build -S /opt/nodo/src/whisper.cpp
  cmake --build /opt/nodo/src/whisper.cpp/build -j"$(nproc)"
fi

fetch https://github.com/protomaps/go-pmtiles/releases/download/v1.31.2/go-pmtiles_1.31.2_Linux_x86_64.tar.gz /opt/nodo/src/pmtiles.tar.gz
if [[ ! -x /usr/local/bin/pmtiles ]]; then
  tar -xzf /opt/nodo/src/pmtiles.tar.gz -C /usr/local/bin pmtiles
  chmod 755 /usr/local/bin/pmtiles
fi

if [[ -n "${bbox}" ]]; then
  planet=""
  for offset in 1 2 3 4 5 6 7; do
    day="$(date -u -d "-${offset} days" +%Y%m%d)"
    url="https://build.protomaps.com/${day}.pmtiles"
    if curl -fsI -o /dev/null "$url"; then
      planet="$url"
      break
    fi
  done
  [[ -n "$planet" ]] || die "Could not find a Protomaps daily build from the last week."
  say "Cutting the map from ${planet}. The planet file itself is not saved here."
  pmtiles extract "$planet" /var/lib/nodo/maps/region.pmtiles --bbox="$bbox" --maxzoom=15
fi

python3 -m venv /opt/nodo/venv
/opt/nodo/venv/bin/pip install -U pip
/opt/nodo/venv/bin/pip install meshtastic || say "warning: meshtastic Python package did not install. The map will show no nodes until it does."
mesh_src=""
if [[ -f "${ROOT}/install/nodo-mesh-nodes.py" ]]; then
  mesh_src="${ROOT}/install/nodo-mesh-nodes.py"
elif [[ -f "${ROOT}/nodo-mesh-nodes.py" ]]; then
  mesh_src="${ROOT}/nodo-mesh-nodes.py"
else
  die "Missing nodo-mesh-nodes.py next to the installer."
fi
install -m 0755 "$mesh_src" /usr/local/sbin/nodo-mesh-nodes
portal_src=""
if [[ -f "${ROOT}/install/nodo-portal.py" ]]; then
  portal_src="${ROOT}/install/nodo-portal.py"
elif [[ -f "${ROOT}/nodo-portal.py" ]]; then
  portal_src="${ROOT}/nodo-portal.py"
else
  die "Missing nodo-portal.py next to the installer."
fi
install -m 0755 "$portal_src" /usr/local/sbin/nodo-portal.py
if [[ ! -f "${ROOT}/install/www/index.html" ]]; then
  die "Missing install/www/index.html. That file is the console."
fi
install -m 0644 "${ROOT}/install/www/index.html" /var/lib/nodo/www/index.html
mkdir -p /var/lib/nodo/www/vendor
cp -a "${ROOT}/install/www/vendor/." /var/lib/nodo/www/vendor/

cat > /etc/nodo/nodo.env <<EOF
NODO_CHAT_DIR=/var/lib/nodo/chats
NODO_LIBRARY=/var/lib/nodo/library
NODO_FILES=/var/lib/nodo/files
NODO_MAP=/var/lib/nodo/maps/region.pmtiles
NODO_MODEL=${model}
NODO_GPU=${gpu}
EOF
chmod 644 /etc/nodo/nodo.env

if [[ "$do_kiosk" -eq 1 ]]; then
  printf 'on\n' > /etc/nodo/kiosk
else
  printf 'off\n' > /etc/nodo/kiosk
fi

if [[ -n "$llama_bin" && -e /var/lib/nodo/models/active.gguf ]]; then
  gpu_args=""
  if [[ "$gpu" == "nvidia" ]]; then
    gpu_args="--n-gpu-layers 99"
  fi
  cat > /etc/systemd/system/nodo-llm.service <<EOF
[Unit]
Description=Nodo local model
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/nodo/nodo.env
ExecStart=${llama_bin} -m /var/lib/nodo/models/active.gguf --host 127.0.0.1 --port 8081 -c 4096 ${gpu_args}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable nodo-llm.service
fi

cat > /etc/systemd/system/nodo-mesh.service <<'EOF'
[Unit]
Description=Record Meshtastic nodes this radio can hear
After=network.target

[Service]
Type=oneshot
Environment=NODO_NODES=/run/nodo/nodes.json
ExecStart=/opt/nodo/venv/bin/python /usr/local/sbin/nodo-mesh-nodes
EOF

cat > /etc/systemd/system/nodo-mesh.timer <<'EOF'
[Unit]
Description=Refresh Meshtastic nodes every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF

primary_ip="$(ip -4 -o addr show scope global | awk '{ print $4 }' | cut -d/ -f1 | head -n 1)"
[[ -n "$primary_ip" ]] || primary_ip="127.0.0.1"

cat > /etc/systemd/system/nodo-portal.service <<'EOF'
[Unit]
Description=Nodo console API
After=network.target

[Service]
Type=simple
Environment=NODO_CHAT_DIR=/var/lib/nodo/chats
Environment=NODO_LLM_URL=http://127.0.0.1:8081/v1/chat/completions
ExecStart=/usr/bin/python3 /usr/local/sbin/nodo-portal.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/nginx/sites-available/nodo <<'EOF'
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root /var/lib/nodo/www;
  location /api/ {
    proxy_pass http://127.0.0.1:8090/;
    proxy_read_timeout 300s;
  }
  location /maps/ {
    alias /var/lib/nodo/maps/;
    default_type application/octet-stream;
  }
  location / {
    try_files $uri $uri/ /index.html;
  }
}
EOF
ln -sfn /etc/nginx/sites-available/nodo /etc/nginx/sites-enabled/nodo
rm -f /etc/nginx/sites-enabled/default

if [[ "$do_wifi" -eq 1 ]]; then
  apt-get install -y hostapd dnsmasq
  cat > /etc/nodo/hostapd.conf <<EOF
interface=${wifi_iface}
driver=nl80211
ssid=Nodo
country_code=IT
ieee80211d=1
hw_mode=g
channel=6
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
EOF
  chmod 600 /etc/nodo/hostapd.conf
  cat > /etc/nodo/dnsmasq.conf <<EOF
interface=${wifi_iface}
bind-interfaces
listen-address=10.41.0.1
dhcp-range=10.41.0.50,10.41.0.200,255.255.255.0,12h
dhcp-option=option:router,10.41.0.1
dhcp-option=option:dns-server,10.41.0.1
address=/nodo.local/10.41.0.1
no-resolv
EOF
  cat > /etc/systemd/system/nodo-wifi.service <<EOF
[Unit]
Description=Nodo optional Wi-Fi access point
After=network.target

[Service]
Type=simple
ExecStartPre=/sbin/ip link set ${wifi_iface} up
ExecStartPre=/sbin/ip addr replace 10.41.0.1/24 dev ${wifi_iface}
ExecStart=/usr/sbin/hostapd /etc/nodo/hostapd.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl disable --now hostapd.service >/dev/null 2>&1 || true
  systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true
  systemctl enable nodo-wifi.service
fi

if [[ "$do_kiosk" -eq 1 ]]; then
  "${ROOT}/install/enable-kiosk.sh" || say "warning: fullscreen did not start. Run sudo ./install/enable-kiosk.sh"
else
  printf 'off\n' > /etc/nodo/kiosk
  systemctl disable --now nodo-kiosk.service >/dev/null 2>&1 || true
fi

systemctl daemon-reload
nginx -t
systemctl enable nginx nodo-portal.service
systemctl restart nodo-portal.service
systemctl restart nginx
systemctl enable --now nodo-mesh.timer
if [[ -x "${ROOT}/install/enable-mesh-ai.sh" ]]; then
  "${ROOT}/install/enable-mesh-ai.sh" || say "warning: /ai on the radio did not start. sudo ./install/enable-mesh-ai.sh"
fi
if [[ -n "$llama_bin" && -e /var/lib/nodo/models/active.gguf ]]; then
  systemctl enable nodo-llm.service
  systemctl restart nodo-llm.service || say "warning: the model service did not start. journalctl -u nodo-llm"
fi
if [[ "$do_wifi" -eq 1 ]]; then
  systemctl restart nodo-wifi.service || say "warning: the Wi-Fi access point did not start."
fi

say ""
say "Installed. The console starts at boot on port 80."
say "From another computer open http://${primary_ip}/"
say "The chat is the LLMs tab on that same page. Nothing is published on another port."
say "Fullscreen at boot needs a graphical login. A server with no screen still serves the page."
say "iFixit and wikiHow are non-commercial. Do not sell this image while they are installed."
