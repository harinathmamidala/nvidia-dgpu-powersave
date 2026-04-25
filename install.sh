#!/usr/bin/env bash
# install.sh — Manual installer for nvidia-dgpu-powersave
# Usage: sudo bash install.sh
# Tested on: Arch Linux, Manjaro, EndeavourOS

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root: sudo bash install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing gpu-power.sh..."
install -Dm755 "$SCRIPT_DIR/src/gpu-power.sh" /usr/local/bin/gpu-power.sh

echo "==> Installing systemd units..."
install -Dm644 "$SCRIPT_DIR/systemd/gpu-power.service" \
    /etc/systemd/system/gpu-power.service
install -Dm644 "$SCRIPT_DIR/systemd/gpu-power-boot.service" \
    /etc/systemd/system/gpu-power-boot.service

echo "==> Installing udev rule..."
install -Dm644 "$SCRIPT_DIR/udev/99-gpu-power.rules" \
    /etc/udev/rules.d/99-gpu-power.rules

echo "==> Enabling boot service..."
systemctl daemon-reload
systemctl enable --now gpu-power-boot.service

echo "==> Reloading udev rules..."
udevadm control --reload-rules
udevadm trigger --subsystem-match=power_supply

echo ""
echo "✓ Installation complete."
echo "  Plug/unplug your AC adapter and watch: journalctl -t gpu-power -f"
