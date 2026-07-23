#!/usr/bin/env bash
set -euo pipefail
source /opt/prepperpi/config/network.conf
PREFIX="${SUBNET##*/}"
ip link set "$WIFI_INTERFACE" up
ip addr replace "${PI_IP}/${PREFIX}" dev "$WIFI_INTERFACE"
echo "Static IP ${PI_IP}/${PREFIX} applied to ${WIFI_INTERFACE}"
