# nvidia-dgpu-powersave

> Automatically power-gate the NVIDIA dGPU on hybrid laptops when running on battery — and bring it back the moment you plug in.

---

## The Problem

Modern hybrid laptops ship with two GPUs: an integrated GPU (iGPU) baked into the CPU, and a discrete NVIDIA GPU (dGPU) soldered alongside it. On Windows, NVIDIA's driver and Optimus technology manage this transparently. On Linux, the story is messier.

Even when you are not running any 3D application, the NVIDIA dGPU frequently remains fully powered on (D0 state). The reasons are subtle:

- The `nvidia` kernel module loads at boot and binds to the GPU, keeping it active.
- Display managers like GDM and SDDM probe `/dev/nvidia*` nodes at startup, preventing the driver from suspending.
- `nvidia-persistenced`, if running, holds the GPU awake deliberately.
- Tools like PRIME synchronisation require the dGPU to be bound even when it is not rendering anything to your screen.

The real-world consequence is significant. A bound, idle NVIDIA dGPU typically draws **5–15 W** continuously. On a 60 Wh laptop battery that alone represents 1–3 hours of battery life silently evaporating, even while you are just writing text or browsing the web.

Runtime power management (`nvidia.NVreg_DynamicPowerManagement=0x02`) exists and helps, but it is unreliable across driver generations, BIOS revisions, and laptop vendors. Many users find the GPU refuses to reach D3cold (the deep power-off state) even with runtime PM enabled, because _something_ somewhere is keeping a file descriptor open.

The nuclear option — and the most reliable one — is to simply **unbind the NVIDIA driver from the GPU entirely** when you do not need it.

---

## How This Solves It

`nvidia-dgpu-powersave` is a small, auditable set of shell script + systemd units + a udev rule that implements a clean bind/unbind lifecycle:

```
Unplug AC  →  udev fires  →  gpu-power.service runs gpu-power.sh
                              ├─ Finds all processes using the GPU
                              ├─ Sends SIGTERM, waits 5s, SIGKILLs survivors
                              ├─ Enables runtime PM on the PCI device
                              ├─ Unbinds the nvidia driver
                              └─ Confirms the GPU reaches D3cold (power rail cut by ACPI/BIOS)

Plug AC in  →  udev fires  →  gpu-power.service runs gpu-power.sh
                              ├─ Re-binds the nvidia driver
                              ├─ Disables runtime PM (keeps GPU in D0 on AC)
                              └─ /dev/nvidia* nodes reappear for applications
```

On boot, `gpu-power-boot.service` runs once to set the correct state based on whatever the current power source is — so the logic survives reboots and suspend/resume cycles.

### What "D3cold" means and why it matters

PCI power states run from D0 (fully on) to D3cold (power rail physically cut). When the NVIDIA driver is unbound:

1. The driver releases its hold on the device.
2. Linux puts the PCI device into D3hot (clock-gated, still powered).
3. Your laptop's ACPI firmware detects no driver is attached and cuts the dGPU's power rail entirely, transitioning it to **D3cold**.

At D3cold the GPU draws effectively **0 W**. The script polls for this confirmation after unbinding. On most hardware this happens within 1–3 seconds.

---

## Prerequisites

Before installing, make sure the following are in place.

### Required

| Requirement | Why |
|---|---|
| **Arch Linux** (or derivative: Manjaro, EndeavourOS, etc.) | The package targets `pacman`. Manual install works on any systemd-based distro. |
| **systemd** | Services and boot-time activation depend on it. |
| **NVIDIA proprietary driver** (`nvidia` package) | The script binds/unbinds the `nvidia` kernel module. The open-source `nouveau` driver is not supported. |
| **`pciutils`** (`lspci`) | Used to dynamically detect the dGPU PCI ID at runtime. |
| **`psmisc`** (`fuser`) | Finds processes holding `/dev/nvidia*` open so they can be terminated before unbind. |
| **Hybrid GPU laptop** | A machine with both an Intel/AMD iGPU and an NVIDIA dGPU (PRIME/Optimus setup). Single-GPU machines have nothing to gain from this. |

### Recommended

| Recommendation | Why |
|---|---|
| **`nvidia-utils`** (provides `nvidia-smi`) | Adds a second layer of process detection — catches compute and graphics workloads that `fuser` alone may miss. Falls back gracefully if absent. |

### Verify Your Setup

Run these before installing to confirm your system is compatible:

```bash
# 1. Confirm you have an NVIDIA dGPU
lspci | grep -i nvidia

# 2. Confirm the nvidia driver is bound to it
lspci -D | awk '/NVIDIA/{print $1}' | xargs -I{} ls -la /sys/bus/pci/devices/{}/driver

# 3. Confirm you have a battery and AC adapter
ls /sys/class/power_supply/

# 4. Confirm systemd is your init system
systemctl --version
```




### 1. Hide NVIDIA Globally

Edit `/etc/environment`:

    sudo nano /etc/environment

Add:

    # Force Vulkan to only use Intel
    VK_DRIVER_FILES=/usr/share/vulkan/icd.d/intel_icd.x86_64.json

    # Force EGL (OpenGL) to only use Mesa (Intel)
    __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json

Reboot:

    sudo reboot

---

### 2. Update prime-run

Edit:

    sudo nano /usr/bin/prime-run

Set:

    #!/bin/bash
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __VK_LAYER_NV_optimus=NVIDIA_only
    export __GLX_VENDOR_LIBRARY_NAME=nvidia

    # Override global Intel-only settings
    export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/nvidia_icd.json
    export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json

    exec "$@"

Make executable:

    sudo chmod +x /usr/bin/prime-run

---

### Usage

    prime-run <application>

Example:

    prime-run steam
    prime-run glxinfo | grep "OpenGL renderer"
    prime-run vulkaninfo


---

## Installation

The package will automatically enable `gpu-power-boot.service` and reload udev rules.

### Option A — Manual (any systemd-based distro)

```bash
git clone https://github.com/YOURUSERNAME/nvidia-dgpu-powersave.git
cd nvidia-dgpu-powersave
sudo bash install.sh
```

### Option B — Build from PKGBUILD

```bash
git clone https://github.com/YOURUSERNAME/nvidia-dgpu-powersave.git
cd nvidia-dgpu-powersave/packaging
makepkg -si
```

---

## Uninstallation

```bash
# If installed manually
sudo bash uninstall.sh
```

---

## Verifying It Works

After installation, unplug your AC adapter and watch the log in real time:

```bash
journalctl -t gpu-power -f
```

You should see output like:

```
gpu-power: Power source → battery (GPU: 0000:01:00.0)
gpu-power: No processes using GPU
gpu-power: Unbinding GPU (pre-unbind state: D0)
gpu-power: GPU unbound successfully
gpu-power: Waiting for D3cold confirmation...
gpu-power: GPU reached D3cold after 2s ✓
gpu-power: Done
```

To confirm D3cold independently:

```bash
GPU_ID=$(lspci -D | awk '/NVIDIA/{print $1; exit}')
cat /sys/bus/pci/devices/$GPU_ID/power_state
# Should output: D3cold
```

Plug AC back in and re-run the above — it should return `D0`.

---

## How It Works — File by File

```
nvidia-dgpu-powersave/
├── src/
│   └── gpu-power.sh              # Core logic: detect AC state, kill GPU procs, bind/unbind
├── systemd/
│   ├── gpu-power.service         # Oneshot service triggered by udev on AC change
│   └── gpu-power-boot.service    # Oneshot service that runs once at boot
├── udev/
│   └── 99-gpu-power.rules        # Watches power_supply subsystem, fires gpu-power.service
├── packaging/
│   ├── PKGBUILD                  # Arch Linux package definition
│   └── nvidia-dgpu-powersave.install  # pacman install/remove hooks
├── install.sh                    # Manual installer for non-AUR systems
├── uninstall.sh                  # Clean removal script
└── README.md
```

**`gpu-power.sh`** is the heart of the project. It:

1. Acquires a lock (`flock`) so rapid AC plug/unplug events don't race.
2. Detects the NVIDIA GPU PCI ID dynamically via `lspci` — no hardcoded addresses.
3. Reads the AC adapter state from `/sys/class/power_supply/`.
4. On **battery**: kills all processes using the GPU (SIGTERM → 5s grace → SIGKILL), enables PCI runtime PM, unbinds the driver, then polls for D3cold confirmation.
5. On **AC**: re-enumerates the PCI path if needed, binds the driver, disables runtime PM to keep the GPU in D0.

**`99-gpu-power.rules`** uses udev's `TAG+="systemd"` + `ENV{SYSTEMD_WANTS}` pattern to start `gpu-power.service` without blocking the udev event queue.

**`gpu-power-boot.service`** ensures the correct state is applied on boot — so if you boot on battery, the GPU starts unbound, and if you boot on AC, it starts bound.

---

## Caveats and Known Limitations

**External monitors via HDMI/DisplayPort on some laptops**
On certain laptop models, HDMI and DisplayPort outputs are wired through the dGPU rather than the iGPU. If this applies to your machine, unbinding the dGPU will drop any connected external display. The monitor will reappear when you plug AC back in. You can verify your wiring with `xrandr --listproviders` or by checking which GPU drives external outputs in your laptop's service manual.

**Wayland compositors may behave differently**
Some Wayland compositors keep a DRM file descriptor open to the GPU. If `gpu-power.sh` logs a warning that it could not kill all GPU processes, the compositor is the likely culprit. Stopping it before unplug (or configuring it to release the GPU) will resolve this.


**BIOS/ACPI variations**
D3cold depends on your laptop's ACPI firmware cutting the power rail after the driver releases the device. On some machines this does not happen automatically. The script will log a note if D3cold is not confirmed — the GPU will still be unbound and drawing less power, but the full power rail cutoff may not occur.

**NVIDIA driver version**
Tested against the current `nvidia` package on Arch. Older driver series (470.xx, 390.xx) are not tested. Contributions welcome.

---

## Contributing

Pull requests are welcome. Please test on hardware before submitting, and include `journalctl -t gpu-power` output in the PR description to show the bind/unbind cycle working correctly.

---

## License

MIT — see [LICENSE](LICENSE).
