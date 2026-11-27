#!/bin/bash
# Bring up the Nodo Wi-Fi on a spare Debian 12 or 13 machine.
# Address 10.41.0.1, network name Nodo. No internet sharing.
# The interactive console is not part of this script yet.
set -euo pipefail

WIFI=""
CHANNEL="6"
COUNTRY="IT"
PASSPHRASE=""
CHECK=0

die() {
  printf 'nodo-install: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'nodo-install: warning: %s\n' "$1" >&2
}

usage() {
  cat <<'EOF'
Usage: sudo ./nodo-install.sh --wifi IFACE [options]

  --wifi IFACE     Adapter that becomes the Nodo access point
  --channel N      1 to 13 (default 6)
  --country CC     Regulatory country, two letters (default IT)
  --passphrase S   Optional WPA2 passphrase, 8 to 63 characters.
                   Without it the Wi-Fi is open. The console still
                   expects the owner to accept each person.
  --check          Print the plan and exit. Changes nothing.
  --help

Do not run this on a computer you use every day.
Use a spare Debian 12 or 13 machine. --check is safe anywhere.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wifi)
      [[ $# -ge 2 ]] || die "Missing the name after --wifi."
      WIFI="$2"
      shift 2
      ;;
    --channel)
      [[ $# -ge 2 ]] || die "Missing the number after --channel."
      CHANNEL="$2"
      shift 2
      ;;
    --country)
      [[ $# -ge 2 ]] || die "Missing the code after --country."
      COUNTRY="$2"
      shift 2
      ;;
    --passphrase)
      [[ $# -ge 2 ]] || die "Missing the text after --passphrase."
      PASSPHRASE="$2"
      shift 2
      ;;
    --check)
      CHECK=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$WIFI" ]] || die "Pass --wifi with the adapter name. List adapters with: iw dev"
[[ "$WIFI" =~ ^[A-Za-z][A-Za-z0-9._-]{0,14}$ ]] || die "Interface name is not usable."
[[ "$CHANNEL" =~ ^[0-9]+$ ]] || die "Channel must be a number from 1 to 13."
if ((CHANNEL < 1 || CHANNEL > 13)); then
  die "Channel must be a number from 1 to 13."
fi
[[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || die "Country must be two capital letters, for example IT."
if [[ -n "$PASSPHRASE" ]]; then
  passphrase_length="${#PASSPHRASE}"
  if ((passphrase_length < 8 || passphrase_length > 63)); then
    die "Passphrase must be 8 to 63 characters."
  fi
  [[ "$PASSPHRASE" != *$'\n'* ]] || die "Passphrase cannot contain a newline."
  [[ "$PASSPHRASE" =~ ^[A-Za-z0-9\ !@#%^*_=+.,:-]+$ ]] || die "Passphrase has a character this installer will not write into a config file."
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
www_src="${script_dir}/www"
[[ -f "${www_src}/index.html" ]] || die "Missing ${www_src}/index.html next to this script."

plan() {
  local access="open"
  if [[ -n "$PASSPHRASE" ]]; then
    access="WPA2 (passphrase not printed)"
  fi
  cat <<EOF
Nodo installer plan
  Wi-Fi adapter: ${WIFI}
  Name: Nodo
  Address: 10.41.0.1/24
  DHCP: 10.41.0.50–10.41.0.200
  Channel: ${CHANNEL}
  Country: ${COUNTRY}
  Access: ${access}
  DNS name: nodo.local
  Page: the short notice in install/www (the console is not installed)
  Internet sharing: no
Packages, only on a real run: hostapd dnsmasq iw wireless-regdb nginx iproute2
EOF
}

if [[ ! -e "/sys/class/net/${WIFI}" ]]; then
  if [[ "$CHECK" -eq 1 ]]; then
    warn "No adapter named ${WIFI} on this machine. The plan below is still valid."
  else
    die "No adapter named ${WIFI}."
  fi
fi

if [[ "$CHECK" -eq 1 ]]; then
  plan
  if [[ "$(id -u)" -ne 0 ]]; then
    printf 'A real run must be root.\n'
  fi
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "12" ]]; then
      printf 'A real run accepts Debian 12 or 13 only. This machine is %s.\n' "${PRETTY_NAME:-unknown}"
    fi
  fi
  printf 'Check only. Nothing was changed.\n'
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "Run as root, or pass --check."
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" && ( "${VERSION_ID:-}" == "12" || "${VERSION_ID:-}" == "13" ) ]] || die "This installer supports Debian 12 or 13 only. Found ${PRETTY_NAME:-unknown}."

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y hostapd dnsmasq iw wireless-regdb nginx iproute2

if command -v iw >/dev/null 2>&1 && iw dev "${WIFI}" info >/dev/null 2>&1; then
  phy="$(iw dev "${WIFI}" info | awk '/wiphy/ { print "phy"$2; exit }')"
  if [[ -n "${phy}" ]] && ! iw phy "${phy}" info | grep -q '\* AP'; then
    die "${WIFI} does not advertise access-point mode. Another adapter is required."
  fi
fi

install -d -m 0755 /etc/nodo /var/lib/nodo/www /usr/local/sbin /etc/systemd/system

{
  printf 'interface=%s\n' "${WIFI}"
  printf '%s\n' \
    'driver=nl80211' \
    'ssid=Nodo' \
    "country_code=${COUNTRY}" \
    'ieee80211d=1' \
    'hw_mode=g' \
    "channel=${CHANNEL}" \
    'wmm_enabled=1' \
    'auth_algs=1' \
    'ignore_broadcast_ssid=0'
  if [[ -n "$PASSPHRASE" ]]; then
    printf '%s\n' 'wpa=2' 'wpa_key_mgmt=WPA-PSK' 'rsn_pairwise=CCMP'
    printf 'wpa_passphrase=%s\n' "${PASSPHRASE}"
  fi
} > /etc/nodo/hostapd.conf
chmod 600 /etc/nodo/hostapd.conf

cat > /etc/nodo/dnsmasq.conf <<EOF
interface=${WIFI}
bind-interfaces
listen-address=10.41.0.1
dhcp-range=10.41.0.50,10.41.0.200,255.255.255.0,12h
dhcp-option=option:router,10.41.0.1
dhcp-option=option:dns-server,10.41.0.1
domain=local
local=/local/
address=/nodo.local/10.41.0.1
address=/connectivitycheck.gstatic.com/10.41.0.1
address=/connectivitycheck.android.com/10.41.0.1
address=/captive.apple.com/10.41.0.1
address=/www.msftconnecttest.com/10.41.0.1
no-resolv
no-hosts
EOF
chmod 644 /etc/nodo/dnsmasq.conf

cat > /usr/local/sbin/nodo-prep <<EOF
#!/bin/bash
set -euo pipefail
if command -v nmcli >/dev/null 2>&1; then
  nmcli device set '${WIFI}' managed no || true
fi
ip link set '${WIFI}' up
iw reg set '${COUNTRY}' || true
EOF
chmod 755 /usr/local/sbin/nodo-prep

cat > /etc/systemd/system/nodo-hostapd.service <<EOF
[Unit]
Description=Nodo Wi-Fi access point
After=network.target
Before=nodo-addr.service

[Service]
Type=forking
PIDFile=/run/nodo-hostapd.pid
ExecStartPre=/usr/local/sbin/nodo-prep
ExecStart=/usr/sbin/hostapd -B -P /run/nodo-hostapd.pid /etc/nodo/hostapd.conf
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/nodo-addr.service <<EOF
[Unit]
Description=Nodo access point address
After=nodo-hostapd.service
Requires=nodo-hostapd.service
Before=nodo-dnsmasq.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 1
ExecStart=/usr/sbin/ip addr replace 10.41.0.1/24 dev ${WIFI}

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/nodo-dnsmasq.service <<EOF
[Unit]
Description=Nodo DHCP and DNS
After=nodo-addr.service
Requires=nodo-addr.service

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/nodo/dnsmasq.conf --pid-file=/run/nodo-dnsmasq.pid
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/nginx/sites-available/nodo <<'EOF'
server {
  listen 10.41.0.1:80;
  server_name nodo.local 10.41.0.1;
  root /var/lib/nodo/www;
  index index.html;
  location / {
    try_files $uri $uri/ /index.html;
  }
}
EOF
ln -sfn /etc/nginx/sites-available/nodo /etc/nginx/sites-enabled/nodo

rm -rf /var/lib/nodo/www
install -d -m 0755 /var/lib/nodo/www
cp -a "${www_src}/." /var/lib/nodo/www/

systemctl disable --now hostapd.service >/dev/null 2>&1 || true
systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true
systemctl daemon-reload
nginx -t
systemctl enable nodo-hostapd.service nodo-addr.service nodo-dnsmasq.service
systemctl restart nginx
systemctl restart nodo-hostapd.service
systemctl restart nodo-addr.service
systemctl restart nodo-dnsmasq.service

printf 'Nodo Wi-Fi is configured. Phones join Nodo and open http://10.41.0.1\n'
printf 'The page there only says the network is up. The console is not installed yet.\n'
