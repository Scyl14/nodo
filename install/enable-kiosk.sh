#!/bin/bash
# Open the console fullscreen on the machine's own screen at boot.
set -euo pipefail
[[ "$(id -u)" -eq 0 ]] || { printf 'Run as root: sudo ./install/enable-kiosk.sh\n' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y chromium cage || apt-get install -y chromium-browser cage

browser="$(command -v chromium || command -v chromium-browser)"
[[ -n "$browser" ]] || { printf 'Chromium did not install.\n' >&2; exit 1; }
[[ -x /usr/bin/cage ]] || { printf 'cage did not install.\n' >&2; exit 1; }

install -d -m 0755 /etc/nodo /usr/local/sbin
printf 'on\n' > /etc/nodo/kiosk
cat > /usr/local/sbin/nodo-kiosk-session <<EOF
#!/bin/bash
exec ${browser} --kiosk --ozone-platform=wayland --no-first-run --disable-translate --noerrdialogs --disable-infobars http://127.0.0.1/
EOF
chmod 755 /usr/local/sbin/nodo-kiosk-session

cat > /etc/systemd/system/nodo-kiosk.service <<'EOF'
[Unit]
Description=Nodo fullscreen dashboard
After=nginx.service
Conflicts=getty@tty1.service
ConditionPathExists=/etc/nodo/kiosk

[Service]
Type=simple
TTYPath=/dev/tty1
StandardInput=tty
ExecStartPre=/bin/grep -qx on /etc/nodo/kiosk
ExecStart=/usr/bin/cage -s -- /usr/local/sbin/nodo-kiosk-session
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl set-default multi-user.target
systemctl enable nodo-kiosk.service
systemctl restart nodo-kiosk.service || true
printf 'Fullscreen is on. It starts at boot on this machine'\''s screen.\n'
printf 'From another computer the page stays http://this-machine/\n'
