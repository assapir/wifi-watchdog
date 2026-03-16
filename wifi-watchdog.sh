#!/usr/bin/env bash
# WiFi Watchdog for Raspberry Pi 5 (brcmfmac/CYW43455)
# Detects WiFi firmware lockups and recovers via module reload or reboot.

set -euo pipefail

DISABLE_FILE="/run/wifi-watchdog/manual_disable"
LAST_REBOOT_FILE="/run/wifi-watchdog/last_reboot"
REBOOT_COOLDOWN=3600  # max 1 watchdog-triggered reboot per hour

log_info()  { echo "INFO:  $*"; }
log_warn()  { echo "WARN:  $*"; }
log_error() { echo "ERROR: $*"; }

get_gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

check_connectivity() {
    local gw
    gw=$(get_gateway)
    [[ -n "$gw" ]] && ping -c 3 -W 2 "$gw" &>/dev/null
}

reload_modules() {
    log_warn "Unloading brcmfmac driver stack..."
    modprobe -r brcmfmac_cyw 2>/dev/null || true
    modprobe -r brcmfmac     2>/dev/null || true
    modprobe -r brcmutil      2>/dev/null || true
    sleep 2

    log_warn "Reloading brcmfmac..."
    if ! modprobe brcmfmac; then
        log_error "Failed to load brcmfmac module"
        return 1
    fi

    log_info "Waiting up to 30s for reconnection..."
    for i in $(seq 1 6); do
        sleep 5
        if check_connectivity; then
            log_info "Connectivity restored after $((i * 5))s"
            return 0
        fi
    done

    log_error "Connectivity NOT restored after module reload"
    return 1
}

safe_reboot() {
    mkdir -p "$(dirname "$LAST_REBOOT_FILE")"
    if [[ -f "$LAST_REBOOT_FILE" ]]; then
        local elapsed=$(( $(date +%s) - $(<"$LAST_REBOOT_FILE") ))
        if (( elapsed < REBOOT_COOLDOWN )); then
            log_error "Reboot cooldown active ($((REBOOT_COOLDOWN - elapsed))s remaining). NOT rebooting."
            return 1
        fi
    fi

    log_error "Rebooting to recover WiFi firmware..."
    date +%s > "$LAST_REBOOT_FILE"
    sync
    systemctl reboot
}

# --- Main ---
if [[ -f "$DISABLE_FILE" ]]; then
    log_info "Disabled ($DISABLE_FILE exists). Skipping."
    exit 0
fi

if check_connectivity; then
    exit 0
fi

log_warn "WiFi is down — attempting module reload"
if reload_modules; then
    log_info "=== RECOVERED via module reload ==="
else
    log_error "=== Module reload failed — rebooting ==="
    safe_reboot
fi
