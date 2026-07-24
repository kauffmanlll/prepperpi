#!/usr/bin/env bash
# PrepperPi installer for Raspberry Pi OS (Bookworm/Bullseye)
# Usage: sudo bash scripts/install.sh
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[-]${NC} $*" >&2; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash scripts/install.sh"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
info "Repository root: $REPO_DIR"

# ── Bootstrap example configs ─────────────────────────────────────────────────
for f in network.conf kiwix.conf system.conf; do
    if [[ ! -f "$REPO_DIR/config/$f" && -f "$REPO_DIR/config/${f}.example" ]]; then
        cp "$REPO_DIR/config/${f}.example" "$REPO_DIR/config/$f"
        warn "Created config/$f from example — edit values, then re-run this script."
    fi
done

# ── Source network config ─────────────────────────────────────────────────────
[[ -f "$REPO_DIR/config/network.conf" ]] \
    || die "config/network.conf not found. Copy from config/network.conf.example and fill in values."

# shellcheck source=/dev/null
source "$REPO_DIR/config/network.conf"

for var in SSID PASSPHRASE COUNTRY WIFI_INTERFACE SUBNET PI_IP DHCP_RANGE_START DHCP_RANGE_END; do
    [[ -n "${!var:-}" ]] \
        || die "$var is not set in config/network.conf. Compare against config/network.conf.example."
done

[[ "${PASSPHRASE}" != "CHANGE_ME_STRONG_PASSWORD" ]] \
    || die "Set a real PASSPHRASE in config/network.conf before installing."
[[ ${#PASSPHRASE} -ge 8 && ${#PASSPHRASE} -le 63 ]] \
    || die "PASSPHRASE must be 8–63 characters (WPA2 requirement)."

# Derive prefix length from SUBNET (e.g. 10.10.0.0/24 -> 24)
PREFIX="${SUBNET##*/}"

info "Network: SSID=${SSID}  PI_IP=${PI_IP}/${PREFIX}  iface=${WIFI_INTERFACE}"

# ── APT packages ──────────────────────────────────────────────────────────────
info "Installing system packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    hostapd \
    dnsmasq \
    nginx \
    python3-venv \
    python3-pip \
    kiwix-tools \
    dos2unix

# ── System user ───────────────────────────────────────────────────────────────
if ! id -u prepperpi &>/dev/null; then
    info "Creating system user prepperpi..."
    useradd --system --no-create-home --shell /usr/sbin/nologin prepperpi
else
    info "System user prepperpi already exists."
fi

# ── Directory structure ───────────────────────────────────────────────────────
info "Creating directory structure under /opt/prepperpi..."
install -d -m 755 \
    /opt/prepperpi \
    /opt/prepperpi/data \
    /opt/prepperpi/data/zim \
    /opt/prepperpi/logs \
    /opt/prepperpi/backup \
    /opt/prepperpi/scripts \
    /opt/prepperpi/webapp \
    /var/log/prepperpi

# ── Python virtualenv ─────────────────────────────────────────────────────────
info "Setting up Python virtualenv..."
python3 -m venv /opt/prepperpi/venv
/opt/prepperpi/venv/bin/pip install --upgrade pip --quiet
/opt/prepperpi/venv/bin/pip install -r "$REPO_DIR/requirements.txt" --quiet
info "Installed Python packages: $(/opt/prepperpi/venv/bin/pip freeze | paste -sd, -)"

# ── Application files ─────────────────────────────────────────────────────────
info "Copying application files..."
find "$REPO_DIR/scripts" -name "*.sh" -exec dos2unix -q {} \;

if [[ "$REPO_DIR" != "/opt/prepperpi" ]]; then
    rsync -a --delete "$REPO_DIR/webapp/" /opt/prepperpi/webapp/ 2>/dev/null \
        || cp -r "$REPO_DIR/webapp/." /opt/prepperpi/webapp/

    cp "$REPO_DIR/scripts/"*.sh  /opt/prepperpi/scripts/
    cp "$REPO_DIR/scripts/"*.py  /opt/prepperpi/scripts/ 2>/dev/null || true
else
    info "Repository is already at /opt/prepperpi — skipping self-copy."
fi
chmod +x /opt/prepperpi/scripts/*.sh

# ── Release the AP interface from NetworkManager, if present ─────────────────
# On NetworkManager-managed systems (e.g. Debian Trixie), wlan0 otherwise stays
# a DHCP client of whatever Wi-Fi it was last joined to, which conflicts with
# hostapd and leaves the interface without the static AP address dnsmasq needs.
if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; then
    info "NetworkManager detected — marking ${WIFI_INTERFACE} unmanaged so hostapd can control it..."
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/prepperpi-unmanaged.conf << EOF
[keyfile]
unmanaged-devices=interface-name:${WIFI_INTERFACE}
EOF
    nmcli device disconnect "${WIFI_INTERFACE}" 2>/dev/null || true
    nmcli general reload conf 2>/dev/null || true
fi

# ── dnsmasq ───────────────────────────────────────────────────────────────────
info "Writing dnsmasq config..."
# Enable conf-dir inclusion in main dnsmasq.conf if it's commented out
if grep -q '^#conf-dir=/etc/dnsmasq.d' /etc/dnsmasq.conf 2>/dev/null; then
    sed -i 's|^#conf-dir=/etc/dnsmasq.d/,\*.conf|conf-dir=/etc/dnsmasq.d/,*.conf|' /etc/dnsmasq.conf
fi

cat > /etc/dnsmasq.d/prepperpi.conf << EOF
# PrepperPi DHCP/DNS — generated by install.sh; do not edit manually.
# Edit config/network.conf and re-run install.sh to change values.
interface=${WIFI_INTERFACE}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},12h
dhcp-option=3,${PI_IP}
dhcp-option=6,${PI_IP}
domain-needed
bogus-priv
no-resolv
server=1.1.1.1
server=8.8.8.8
log-queries
log-dhcp
EOF

# ── hostapd ───────────────────────────────────────────────────────────────────
info "Configuring hostapd (SSID: ${SSID})..."
# Generate from network.conf values so it stays in sync
cat > /etc/hostapd/hostapd.conf << EOF
country_code=${COUNTRY}
interface=${WIFI_INTERFACE}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${PASSPHRASE}
EOF
chmod 600 /etc/hostapd/hostapd.conf

# Point hostapd at its config and unmask the service
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
systemctl unmask hostapd

# ── polkit ────────────────────────────────────────────────────────────────────
info "Installing polkit rule for web-triggered updates..."
mkdir -p /etc/polkit-1/rules.d
cp "$REPO_DIR/configs/polkit/49-prepperpi.rules" /etc/polkit-1/rules.d/49-prepperpi.rules
systemctl try-restart polkit 2>/dev/null || true

# ── nginx ─────────────────────────────────────────────────────────────────────
info "Configuring nginx..."
cp "$REPO_DIR/configs/nginx/prepperpi.conf" /etc/nginx/sites-available/prepperpi
ln -sf /etc/nginx/sites-available/prepperpi /etc/nginx/sites-enabled/prepperpi
rm -f /etc/nginx/sites-enabled/default
nginx -t || die "nginx config test failed — check configs/nginx/prepperpi.conf"
systemctl restart nginx

# ── systemd units ─────────────────────────────────────────────────────────────
info "Installing systemd units..."
for f in "$REPO_DIR/configs/systemd/"*.service "$REPO_DIR/configs/systemd/"*.timer; do
    [[ -f "$f" ]] && cp "$f" /etc/systemd/system/ && info "  installed $(basename "$f")"
done
for f in "$REPO_DIR/systemd/"*.service "$REPO_DIR/systemd/"*.timer; do
    [[ -f "$f" ]] && cp "$f" /etc/systemd/system/ && info "  installed $(basename "$f")"
done

# prepperpi-kiwix hardening drop-in
mkdir -p /etc/systemd/system/prepperpi-kiwix.service.d
cp "$REPO_DIR/systemd/prepperpi-kiwix.service.d/override.conf" \
   /etc/systemd/system/prepperpi-kiwix.service.d/override.conf

# dnsmasq timing fix: wait for hostapd/wlan0 to be ready before starting
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/override.conf << 'UNIT'
[Unit]
After=network-online.target hostapd.service prepperpi-wlan-static.service
Wants=network-online.target
Requires=prepperpi-wlan-static.service

[Service]
Restart=on-failure
RestartSec=5
UNIT

# ── Enable services ───────────────────────────────────────────────────────────
info "Enabling systemd services..."
systemctl daemon-reload

# Core infrastructure — start now since they don't need a reboot
systemctl enable --now nginx

# AP stack — enable now, will fully activate after reboot
systemctl enable hostapd
systemctl enable prepperpi-wlan-static.service
systemctl enable dnsmasq

# PrepperPi services
systemctl enable prepperpi-web.service
systemctl enable prepperpi-kiwix.service
systemctl enable nat-iptables.service
systemctl enable prepperpi-monitor.service
systemctl enable prepperpi-backup.timer
systemctl enable prepperpi-update.timer
systemctl enable os-update-onboot.service
systemctl enable os-update-weekly.timer

# ── File permissions ──────────────────────────────────────────────────────────
info "Setting file permissions..."
chown -R prepperpi:prepperpi /opt/prepperpi
chown -R prepperpi:prepperpi /var/log/prepperpi
chmod 750 /opt/prepperpi/scripts/*.sh
chmod 640 /opt/prepperpi/webapp/*.py 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
info "PrepperPi installation complete."
info "  WiFi SSID  : ${SSID}"
info "  Pi address : http://${PI_IP}/"
info "  DHCP range : ${DHCP_RANGE_START} – ${DHCP_RANGE_END}"
warn "Reboot to activate the access point: sudo reboot"
