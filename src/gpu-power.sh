#!/bin/bash
# gpu-power.sh — Bind/unbind NVIDIA dGPU on AC/battery transitions
# Triggered by udev via gpu-power.service. Safe for repeated rapid calls.
#
# Install:
#   sudo cp gpu-power.sh /usr/local/bin/gpu-power.sh
#   sudo chmod 755 /usr/local/bin/gpu-power.sh

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
LOG_TAG="gpu-power"
LOCK_FILE="/run/gpu-power.lock"
D3COLD_POLL_INTERVAL=1   # seconds between D3cold checks (post-unbind)
D3COLD_POLL_MAX=15       # wait up to 15 s for D3cold after unbind

# Detect dGPU PCI ID dynamically (first NVIDIA device found)
GPU_ID=$(lspci -D 2>/dev/null | awk '/NVIDIA/{print $1; exit}')
if [[ -z "$GPU_ID" ]]; then
    logger -t "$LOG_TAG" "ERROR: No NVIDIA GPU found in lspci output"
    exit 1
fi

GPU_DEV="/sys/bus/pci/devices/$GPU_ID"
NVIDIA_BIND="/sys/bus/pci/drivers/nvidia/bind"
NVIDIA_UNBIND="$GPU_DEV/driver/unbind"
# ──────────────────────────────────────────────────────────────────────────────

log() { logger -t "$LOG_TAG" "$*"; echo "[$(date '+%H:%M:%S')] $*"; }

# ── Lock: prevent concurrent or rapid-fire duplicate runs ─────────────────────
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "Already running — skipping duplicate trigger"
    exit 0
fi

# ── Locate AC adapter ─────────────────────────────────────────────────────────
AC_ONLINE=""
for ps in /sys/class/power_supply/*; do
    [[ -f "$ps/type" ]] || continue
    if grep -q "Mains" "$ps/type" 2>/dev/null; then
        AC_ONLINE="$ps/online"
        break
    fi
done

if [[ -z "$AC_ONLINE" ]]; then
    log "ERROR: No AC adapter found under /sys/class/power_supply"
    exit 1
fi

AC_STATUS=$(< "$AC_ONLINE")

# ── Helper: is the GPU currently bound to a driver? ───────────────────────────
gpu_is_bound() { [[ -L "$GPU_DEV/driver" ]]; }

# ── Helper: current PCI power state ──────────────────────────────────────────
gpu_power_state() {
    local f="$GPU_DEV/power_state"
    if [[ -f "$f" ]]; then
        local s
        s=$(< "$f")
        echo "${s:-unknown}"
    else
        echo "no-power_state-file"
    fi
}

# ── Helper: kill all processes using the GPU ──────────────────────────────────
# Uses nvidia-smi (authoritative for compute/graphics) + fuser (catches
# processes holding /dev/nvidia* open without submitting work).
# Strategy: SIGTERM → 5 s grace → SIGKILL survivors.
# Skips PID 1 and our own PID.
kill_gpu_processes() {
    local pids=""

    if command -v nvidia-smi &>/dev/null; then
        local compute graphics
        compute=$(nvidia-smi --query-compute-apps=pid \
                             --format=csv,noheader,nounits 2>/dev/null || true)
        graphics=$(nvidia-smi --query-accounted-apps=pid \
                              --format=csv,noheader,nounits 2>/dev/null || true)
        pids=$(printf '%s\n%s\n' "$compute" "$graphics" \
               | grep -E '^[0-9]+$' | sort -u \
               | grep -v "^$$\$" | grep -v "^1$" || true)

        # Supplement: catch processes holding device nodes open (e.g. display
        # managers probing the GPU) that nvidia-smi doesn't report.
        local fuser_pids
        fuser_pids=$(fuser /dev/nvidia* /dev/nvidia-modeset /dev/nvidia-uvm \
                         2>/dev/null \
                     | tr ' ' '\n' | grep -E '^[0-9]+$' \
                     | grep -v "^$$\$" | grep -v "^1$" || true)
        pids=$(printf '%s\n%s\n' "$pids" "$fuser_pids" \
               | sort -u | grep -v '^$' || true)
    else
        log "nvidia-smi not found — falling back to fuser"
        pids=$(fuser /dev/nvidia* /dev/nvidia-modeset /dev/nvidia-uvm \
                   2>/dev/null \
               | tr ' ' '\n' | grep -E '^[0-9]+$' \
               | grep -v "^$$\$" | grep -v "^1$" || true)
    fi

    if [[ -z "$pids" ]]; then
        log "No processes using GPU"
        return 0
    fi

    log "GPU processes to terminate:"
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        local name cmd
        name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        cmd=$(ps -p "$pid" -o args= 2>/dev/null | cut -c1-60 || echo "")
        log "  PID $pid  $name  $cmd"
    done <<< "$pids"

    # SIGTERM
    log "Sending SIGTERM..."
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$pids"

    # 5 s grace period
    local waited=0
    while [[ $waited -lt 5 ]]; do
        local still_alive=""
        while IFS= read -r pid; do
            [[ -z "$pid" ]] && continue
            kill -0 "$pid" 2>/dev/null && still_alive+="$pid "
        done <<< "$pids"
        [[ -z "$still_alive" ]] && break
        sleep 1
        (( waited++ )) || true
    done

    # SIGKILL survivors
    local survivors=""
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        kill -0 "$pid" 2>/dev/null && survivors+="$pid "
    done <<< "$pids"

    if [[ -n "$survivors" ]]; then
        log "Sending SIGKILL to: $survivors"
        for pid in $survivors; do
            kill -KILL "$pid" 2>/dev/null || true
        done
        sleep 0.5
    fi

    # Final check
    local remaining=""
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        kill -0 "$pid" 2>/dev/null && remaining+="$pid "
    done <<< "$pids"

    if [[ -n "$remaining" ]]; then
        log "WARNING: Could not kill PIDs: $remaining — unbind may still fail"
    else
        log "All GPU processes terminated"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
if [[ "$AC_STATUS" -eq 0 ]]; then
# ── BATTERY: unbind GPU ───────────────────────────────────────────────────────
    log "Power source → battery (GPU: $GPU_ID)"

    if ! gpu_is_bound; then
        log "GPU already unbound — nothing to do"
        exit 0
    fi

    # Step 1: kill processes holding the GPU open so the driver can release cleanly.
    kill_gpu_processes

    # Step 2: enable runtime PM so the nvidia driver can suspend cleanly.
    if [[ -f "$GPU_DEV/power/control" ]]; then
        echo "auto" > "$GPU_DEV/power/control"
    fi

    # Step 3: unbind the driver.
    #
    # IMPORTANT: D3cold is a *consequence* of unbinding, not a precondition.
    # On hybrid laptops ACPI cuts the dGPU power rail only after the driver
    # releases the device. Waiting for D3cold BEFORE unbind will always time
    # out because the driver actively holds the device in D0/D3hot.
    # We unbind first, then confirm D3cold arrived (optional sanity check).
    log "Unbinding GPU (pre-unbind state: $(gpu_power_state))"
    if echo -n "$GPU_ID" > "$NVIDIA_UNBIND" 2>/dev/null; then
        log "GPU unbound successfully"
    else
        log "ERROR: Failed to unbind GPU — is something still holding it?"
        exit 1
    fi

    # Step 4: confirm D3cold (informational — does not block or fail).
    log "Waiting for D3cold confirmation..."
    for (( i=1; i<=D3COLD_POLL_MAX; i++ )); do
        state=$(gpu_power_state)
        if [[ "$state" == "D3cold" ]]; then
            log "GPU reached D3cold after ${i}s ✓"
            break
        fi
        if [[ $i -eq $D3COLD_POLL_MAX ]]; then
            log "NOTE: D3cold not confirmed after ${D3COLD_POLL_MAX}s (state: $state)."
            log "      This is normal if your ACPI/BIOS manages the rail independently."
        fi
        sleep "$D3COLD_POLL_INTERVAL"
    done

else
# ── AC: bind GPU ──────────────────────────────────────────────────────────────
    log "Power source → AC (GPU: $GPU_ID)"

    if gpu_is_bound; then
        log "GPU already bound — nothing to do"
        exit 0
    fi

    # GPU stays enumerated in PCI topology even when unbound — no rescan needed.
    # Only do a targeted rescan if the sysfs path has vanished (very rare).
    if [[ ! -d "$GPU_DEV" ]]; then
        log "GPU device path missing — triggering targeted rescan"
        PARENT=$(dirname "$GPU_DEV")
        echo 1 > "$PARENT/rescan" 2>/dev/null || true
        sleep 1
    fi

    if [[ ! -f "$NVIDIA_BIND" ]]; then
        log "ERROR: nvidia driver bind path not found — is the nvidia module loaded?"
        exit 1
    fi

    if echo -n "$GPU_ID" > "$NVIDIA_BIND" 2>/dev/null; then
        sleep 0.5   # give udev time to create /dev/nvidia* nodes
        if gpu_is_bound; then
            log "GPU bound successfully (driver: $(basename "$(readlink "$GPU_DEV/driver")"))"
        else
            log "WARNING: bind command succeeded but driver symlink is missing"
        fi
    else
        log "ERROR: Failed to bind GPU"
        exit 1
    fi

    # Keep GPU in D0 while on AC — disable runtime suspend.
    if [[ -f "$GPU_DEV/power/control" ]]; then
        echo "on" > "$GPU_DEV/power/control"
    fi

fi
# ══════════════════════════════════════════════════════════════════════════════

log "Done"
exit 0
