#!/usr/bin/env bash
# WiFi Watchdog for Raspberry Pi 5 (brcmfmac/CYW43455)
# Detects WiFi firmware lockups and recovers via module reload or reboot.

set -euo pipefail

# --- Configuration ---
STATE_DIR="/run/wifi-watchdog"
COUNTER_FILE="$STATE_DIR/fail_count"
LAST_REBOOT_FILE="$STATE_DIR/last_reboot"
DISABLE_FILE="$STATE_DIR/manual_disable"

MAX_FAILURES=3           # consecutive ping failures before action
PING_TIMEOUT=2           # seconds to wait for ping reply
RELOAD_WAIT=30           # seconds to wait for reconnection after module reload
RELOAD_POLL_INTERVAL=5   # seconds between connectivity checks during reload wait
REBOOT_COOLDOWN=3600     # minimum seconds between watchdog-triggered reboots (1 hour)

# --- Logging ---
log_info()  { echo "INFO:  $*"; }
log_warn()  { echo "WARN:  $*"; }
log_error() { echo "ERROR: $*"; }

# --- State helpers ---
read_counter() {
    if [[ -f "$COUNTER_FILE" ]]; then
        local val
        val=$(<"$COUNTER_FILE")
        if [[ "$val" =~ ^[0-9]+$ ]]; then
            echo "$val"
            return
        fi
    fi
    echo 0
}

write_counter() {
    echo "$1" > "$COUNTER_FILE.tmp"
    mv "$COUNTER_FILE.tmp" "$COUNTER_FILE"
}

# --- Connectivity check ---
get_gateway() {
    ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'
}

ping_gateway() {
    local gw="$1"
    ping -c 1 -W "$PING_TIMEOUT" "$gw" &>/dev/null
}

# --- Recovery ---
reload_modules() {
    log_warn "Unloading brcmfmac driver stack..."
    modprobe -r brcmfmac_cyw 2>/dev/null || true
    modprobe -r brcmfmac     2>/dev/null || true
    modprobe -r brcmutil      2>/dev/null || true
    sleep 2

    log_warn "Reloading brcmfmac driver..."
    if ! modprobe brcmfmac; then
        log_error "Failed to reload brcmfmac module"
        return 1
    fi

    log_info "Module reloaded, waiting up to ${RELOAD_WAIT}s for reconnection..."
    local elapsed=0
    while (( elapsed < RELOAD_WAIT )); do
        sleep "$RELOAD_POLL_INTERVAL"
        elapsed=$(( elapsed + RELOAD_POLL_INTERVAL ))

        local gw
        gw=$(get_gateway)
        if [[ -n "$gw" ]] && ping_gateway "$gw"; then
            log_info "Connectivity restored after ${elapsed}s"
            return 0
        fi
        log_info "  ...still waiting (${elapsed}/${RELOAD_WAIT}s)"
    done

    log_error "Connectivity NOT restored after module reload"
    return 1
}

safe_reboot() {
    if [[ -f "$LAST_REBOOT_FILE" ]]; then
        local last_reboot now elapsed
        last_reboot=$(<"$LAST_REBOOT_FILE")
        now=$(date +%s)
        elapsed=$(( now - last_reboot ))
        if (( elapsed < REBOOT_COOLDOWN )); then
            local remaining=$(( REBOOT_COOLDOWN - elapsed ))
            log_error "Reboot cooldown active (${remaining}s remaining). NOT rebooting."
            log_error "Manual intervention required. To disable watchdog: touch $DISABLE_FILE"
            return 1
        fi
    fi

    log_error "Rebooting system to recover WiFi firmware..."
    date +%s > "$LAST_REBOOT_FILE"
    sync
    systemctl reboot
}

# --- Main ---
main() {
    mkdir -p "$STATE_DIR"

    # Manual disable check
    if [[ -f "$DISABLE_FILE" ]]; then
        log_info "Watchdog disabled ($DISABLE_FILE exists). Skipping."
        exit 0
    fi

    # Get gateway
    local gateway
    gateway=$(get_gateway)
    if [[ -z "$gateway" ]]; then
        log_warn "No default gateway found — WiFi may be completely down"
        local count
        count=$(read_counter)
        count=$(( count + 1 ))
        write_counter "$count"
        log_warn "Failure count: $count/$MAX_FAILURES (no gateway)"

        if (( count >= MAX_FAILURES )); then
            log_warn "Threshold reached — attempting module reload (no gateway)"
            if reload_modules; then
                write_counter 0
                exit 0
            else
                write_counter 0
                safe_reboot
            fi
        fi
        exit 0
    fi

    # Ping check
    if ping_gateway "$gateway"; then
        local prev_count
        prev_count=$(read_counter)
        if (( prev_count > 0 )); then
            log_info "Connectivity OK (gateway=$gateway). Resetting counter from $prev_count to 0."
        fi
        write_counter 0
        exit 0
    fi

    # Ping failed
    local count
    count=$(read_counter)
    count=$(( count + 1 ))
    write_counter "$count"
    log_warn "Ping to $gateway failed. Failure count: $count/$MAX_FAILURES"

    if (( count >= MAX_FAILURES )); then
        log_warn "=== RECOVERY: $MAX_FAILURES consecutive failures ==="
        if reload_modules; then
            write_counter 0
            log_info "=== RECOVERY SUCCESSFUL via module reload ==="
        else
            write_counter 0
            log_error "=== RECOVERY FAILED — escalating to reboot ==="
            safe_reboot
        fi
    fi
}

main "$@"
