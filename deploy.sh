#!/usr/bin/env bash
# Push local scripts/webapp/configs/systemd changes to a running PrepperPi
# Pi and restart the affected services, for fast test iteration without a
# git commit/push/pull round trip.
#
# Does NOT touch config/network.conf, kiwix.conf, or system.conf (live,
# Pi-specific settings) and does NOT restart hostapd/dnsmasq (would drop
# the AP and disconnect anyone on it).
#
# Usage:
#   ./deploy.sh                          # deploy to pi@192.168.50.30
#   PI_HOST=pi@10.10.0.1 ./deploy.sh      # deploy to a different host
#   ./deploy.sh pi@192.168.50.30          # host as an argument
set -euo pipefail

PI_HOST="${1:-${PI_HOST:-pi@192.168.50.30}}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="/tmp/prepperpi-deploy-$$"

# accept-new: auto-trust a host key on first connection (normal case), but
# still hard-fail if a previously-known host's key ever unexpectedly changes.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

echo "[deploy] Checking SSH connectivity to ${PI_HOST}..."
ssh "${SSH_OPTS[@]}" "$PI_HOST" true \
    || { echo "[deploy] Could not reach ${PI_HOST} over SSH." >&2; exit 1; }

echo "[deploy] Staging scripts/, webapp/, configs/, systemd/ on the Pi..."
ssh "${SSH_OPTS[@]}" "$PI_HOST" "mkdir -p '$STAGE'"
scp -rq "${SSH_OPTS[@]}" "$REPO_DIR/scripts" "$REPO_DIR/webapp" "$REPO_DIR/configs" "$REPO_DIR/systemd" "${PI_HOST}:${STAGE}/"

echo "[deploy] Applying files and restarting services..."
ssh -t "${SSH_OPTS[@]}" "$PI_HOST" bash -s -- "$STAGE" <<'REMOTE'
set -euo pipefail
STAGE="$1"

sudo cp -r "$STAGE/scripts/."  /opt/prepperpi/scripts/
sudo cp -r "$STAGE/webapp/."   /opt/prepperpi/webapp/
sudo cp -r "$STAGE/configs/."  /opt/prepperpi/configs/
sudo cp -r "$STAGE/systemd/."  /opt/prepperpi/systemd/
rm -rf "$STAGE"

sudo find /opt/prepperpi/scripts -name "*.sh" -exec dos2unix -q {} \;
sudo chmod +x /opt/prepperpi/scripts/*.sh
sudo chown -R prepperpi:prepperpi /opt/prepperpi/scripts /opt/prepperpi/webapp

# Re-apply the configs that live outside /opt/prepperpi
sudo cp /opt/prepperpi/configs/nginx/prepperpi.conf /etc/nginx/sites-available/prepperpi
sudo nginx -t && sudo systemctl reload nginx

sudo cp /opt/prepperpi/configs/systemd/*.service /opt/prepperpi/configs/systemd/*.timer /etc/systemd/system/ 2>/dev/null || true
sudo cp /opt/prepperpi/systemd/*.service /opt/prepperpi/systemd/*.timer /etc/systemd/system/ 2>/dev/null || true
[[ -f /opt/prepperpi/systemd/prepperpi-kiwix.service.d/override.conf ]] && \
    sudo cp /opt/prepperpi/systemd/prepperpi-kiwix.service.d/override.conf /etc/systemd/system/prepperpi-kiwix.service.d/override.conf
[[ -f /opt/prepperpi/configs/polkit/49-prepperpi.rules ]] && \
    sudo cp /opt/prepperpi/configs/polkit/49-prepperpi.rules /etc/polkit-1/rules.d/49-prepperpi.rules

sudo systemctl daemon-reload
sudo systemctl try-restart polkit 2>/dev/null || true

sudo systemctl restart prepperpi-web.service
sudo systemctl restart prepperpi-monitor.service
sudo systemctl restart prepperpi-kiwix.service

echo "[deploy] Service status:"
systemctl is-active prepperpi-web prepperpi-monitor prepperpi-kiwix nginx
REMOTE

echo "[deploy] Done."
