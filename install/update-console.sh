#!/bin/bash
# Replace the console page only. Does not download models or the library.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(id -u)" -eq 0 ]] || { printf 'Run as root: sudo ./install/update-console.sh\n' >&2; exit 1; }
[[ -f "${ROOT}/install/www/index.html" ]] || { printf 'Missing install/www/index.html\n' >&2; exit 1; }
[[ -f "${ROOT}/install/nodo-portal.py" ]] || { printf 'Missing install/nodo-portal.py\n' >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
if ! command -v nginx >/dev/null 2>&1; then
  apt-get update
  apt-get install -y nginx
fi

install -d -m 0755 /var/lib/nodo/www /var/lib/nodo/chats /usr/local/sbin /etc/nodo
install -m 0644 "${ROOT}/install/www/index.html" /var/lib/nodo/www/index.html
install -m 0755 "${ROOT}/install/nodo-portal.py" /usr/local/sbin/nodo-portal.py

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
  location / {
    try_files $uri $uri/ /index.html;
  }
}
EOF
ln -sfn /etc/nginx/sites-available/nodo /etc/nginx/sites-enabled/nodo
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl daemon-reload
systemctl enable nginx nodo-portal.service
systemctl restart nodo-portal.service
systemctl restart nginx

ip="$(ip -4 -o addr show scope global | awk '{ print $4 }' | cut -d/ -f1 | head -n 1)"
printf 'Console updated. Open http://%s/\n' "${ip:-127.0.0.1}"
printf 'It starts at boot. The chat is the LLMs tab on this same page.\n'
