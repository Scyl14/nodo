#!/bin/bash
# Build a bootable Nodo live ISO on a Debian machine.
# The image is Debian 13. It runs from USB and does not install onto the disk.
# This script is not run from the preview. Run it yourself, on Debian, as root.
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

FRESH=0
CHECK=0

die() {
  printf 'build-iso: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo ./build-iso.sh [--check] [--fresh]

  --check   Print what the build needs and exit. Changes nothing.
  --fresh   Delete a previous nodo-live-work directory first.
  --help

Run this on Debian 13, with internet and at least 12 GB free.
A virtual machine is the right place. Not a daily computer.
The ISO is Debian 13 (trixie), amd64. It does not install itself
onto the hard disk. Booting it leaves the computer unchanged
after you remove the USB stick.

Ubuntu cannot build this image. The tool is Debian's live-build.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --fresh) FRESH=1; shift ;;
    --help | -h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
work="${repo_root}/nodo-live-work"
out="${repo_root}/nodo-amd64.iso"

[[ -f "${script_dir}/www/index.html" ]] || die "Missing install/www/index.html"
[[ -f "${script_dir}/live/nodo-live-start" ]] || die "Missing install/live/nodo-live-start"

avail_kb="$(df -Pk "${repo_root}" | awk 'NR==2 { print $4 }')"
avail_gb="$((avail_kb / 1024 / 1024))"

host_name="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  host_name="${PRETTY_NAME:-unknown}"
fi

cat <<EOF
Nodo ISO build
  Image: Debian 13 (trixie), amd64, live USB
  Writes onto the disk: no
  Work directory: ${work}
  Result: ${out}
  Free space here: ${avail_gb} GB
  This machine: ${host_name}
EOF

if [[ "$CHECK" -eq 1 ]]; then
  [[ "$(id -u)" -eq 0 ]] || printf 'A real build must be root.\n'
  if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
    printf 'A real build must be Debian 13. This machine is %s.\n' "${host_name}"
  fi
  [[ "${avail_kb}" -ge $((12 * 1024 * 1024)) ]] || printf 'Need at least 12 GB free.\n'
  printf 'Check only. Nothing was changed.\n'
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "Run as root. --check is safe without it."
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] || die "Build this on Debian 13. Found ${host_name}. Debian 12 and Ubuntu do not have the live-build used here."
[[ "${avail_kb}" -ge $((12 * 1024 * 1024)) ]] || die "Need at least 12 GB free in ${repo_root}."
command -v curl >/dev/null 2>&1 || die "Install curl first: apt-get install -y curl ca-certificates"
curl -fsI --max-time 20 http://deb.debian.org/debian/ >/dev/null || die "Cannot reach deb.debian.org. The build needs internet."

if [[ -d "$work" ]]; then
  [[ "$FRESH" -eq 1 ]] || die "Work directory already exists. Pass --fresh to replace it: ${work}"
  rm -rf "$work"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y live-build debootstrap ca-certificates curl

mkdir -p "$work"
cd "$work"
lb config \
  --distribution trixie \
  --parent-distribution trixie \
  --archive-areas "main non-free-firmware" \
  --parent-archive-areas "main non-free-firmware" \
  --mirror-bootstrap http://deb.debian.org/debian/ \
  --mirror-chroot http://deb.debian.org/debian/ \
  --mirror-binary http://deb.debian.org/debian/ \
  --mirror-binary-security http://deb.debian.org/debian-security/ \
  --security true \
  --binary-images iso-hybrid \
  --debian-installer none \
  --architectures amd64 \
  --linux-flavours amd64 \
  --bootappend-live "boot=live components hostname=nodo username=nodo" \
  --image-name nodo \
  --iso-application "Nodo" \
  --iso-volume "Nodo" \
  --iso-publisher "Nodo" \
  --memtest none \
  --win32-loader false \
  --firmware-chroot true \
  --firmware-binary true \
  --apt-recommends true \
  --system live

mkdir -p config/package-lists config/apt config/includes.chroot/usr/local/sbin \
  config/includes.chroot/etc/nodo \
  config/includes.chroot/etc/nginx/sites-available \
  config/includes.chroot/etc/systemd/system/multi-user.target.wants \
  config/includes.chroot/usr/share/nodo/www \
  config/includes.chroot/var/lib/nodo/www

cat > config/package-lists/nodo.list.chroot <<'EOF'
hostapd
dnsmasq
iw
wireless-regdb
nginx
iproute2
sudo
curl
ca-certificates
EOF

# VMware NAT and some mirrors return a stale index with the same size
# and a different hash. Apt then stops. These options make it refetch.
cat > config/apt/apt.conf <<'EOF'
Acquire::By-Hash "no";
Acquire::Retries "5";
Acquire::http::Pipeline-Depth "0";
Acquire::https::Pipeline-Depth "0";
Acquire::http::No-Cache "true";
Acquire::https::No-Cache "true";
Acquire::BrokenProxy "true";
EOF

cp -a "${script_dir}/www/." config/includes.chroot/usr/share/nodo/www/
cp -a "${script_dir}/www/." config/includes.chroot/var/lib/nodo/www/
cp "${script_dir}/live/live.env" config/includes.chroot/etc/nodo/live.env
cp "${script_dir}/live/nodo.nginx" config/includes.chroot/etc/nginx/sites-available/nodo
install -m 0755 "${script_dir}/live/nodo-live-start" config/includes.chroot/usr/local/sbin/nodo-live-start
cp "${script_dir}/live/nodo-live.service" config/includes.chroot/etc/systemd/system/nodo-live.service
ln -sfn /etc/systemd/system/nodo-live.service \
  config/includes.chroot/etc/systemd/system/multi-user.target.wants/nodo-live.service
ln -sfn /dev/null config/includes.chroot/etc/systemd/system/hostapd.service
ln -sfn /dev/null config/includes.chroot/etc/systemd/system/dnsmasq.service

if ! lb build; then
  printf 'build-iso: first pass failed while downloading Debian. Trying once more.\n'
  lb build
fi

iso="$(find "$work" -maxdepth 1 -type f -name '*.hybrid.iso' -print -quit)"
[[ -n "$iso" ]] || die "live-build finished but no hybrid ISO was found in ${work}"
cp -f "$iso" "$out"
printf 'ISO ready: %s\n' "$out"
printf 'It boots a live system. It does not install onto the hard disk.\n'
