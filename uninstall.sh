#!/usr/bin/env bash
# uninstall.sh — Remove nvidia-dgpu-powersave
# Usage: sudo bash uninstall.sh

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root: sudo bash uninstall.sh"
    exit 1
fi

echo "==> Stopping and disabling services..."
systemctl stop gpu-power.service 2>/dev/null || true
systemctl disable gpu-power-boot.service 2>/dev/null || true

echo "==> Removing files..."
rm -f /usr/local/bin/gpu-power.sh
rm -f /etc/systemd/system/gpu-power.service
rm -f /etc/systemd/system/gpu-power-boot.service
rm -f /etc/udev/rules.d/99-gpu-power.rules

echo "==> Reloading systemd and udev..."
systemctl daemon-reload
udevadm control --reload-rules

echo ""
echo "✓ nvidia-dgpu-powersave removed."
echo "  Your dGPU will remain in its current state until next reboot."
echo "  If the GPU is unbound, rebind manually:"
echo "    GPU_ID=\$(lspci -D | awk '/NVIDIA/{print \$1; exit}')"
echo "    echo -n \"\$GPU_ID\" | sudo tee /sys/bus/pci/drivers/nvidia/bind"
