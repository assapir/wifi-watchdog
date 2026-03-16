#!/usr/bin/env bash
# Install/uninstall WiFi watchdog for Raspberry Pi 5
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: sudo $0 {install|uninstall|status}"
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: must run as root (sudo)"
        exit 1
    fi
}

do_install() {
    check_root
    echo "Installing wifi-watchdog..."

    install -Dm755 "$SCRIPT_DIR/wifi-watchdog.sh"      /usr/local/bin/wifi-watchdog.sh
    install -Dm644 "$SCRIPT_DIR/wifi-watchdog.service"  /etc/systemd/system/wifi-watchdog.service
    install -Dm644 "$SCRIPT_DIR/wifi-watchdog.timer"    /etc/systemd/system/wifi-watchdog.timer

    systemctl daemon-reload
    systemctl enable --now wifi-watchdog.timer

    echo ""
    echo "✓ Installed and started."
    echo ""
    do_status
}

do_uninstall() {
    check_root
    echo "Uninstalling wifi-watchdog..."

    systemctl disable --now wifi-watchdog.timer  2>/dev/null || true
    systemctl stop wifi-watchdog.service         2>/dev/null || true

    rm -f /usr/local/bin/wifi-watchdog.sh
    rm -f /etc/systemd/system/wifi-watchdog.service
    rm -f /etc/systemd/system/wifi-watchdog.timer
    rm -rf /run/wifi-watchdog

    systemctl daemon-reload

    echo "✓ Uninstalled."
}

do_status() {
    echo "=== Timer ==="
    systemctl list-timers wifi-watchdog.timer --no-pager 2>/dev/null || echo "(not active)"
    echo ""
    echo "=== Recent logs ==="
    journalctl -u wifi-watchdog --no-pager -n 10 2>/dev/null || echo "(no logs yet)"
    echo ""
    if [[ -f /run/wifi-watchdog/fail_count ]]; then
        echo "Failure counter: $(cat /run/wifi-watchdog/fail_count)"
    else
        echo "Failure counter: 0 (no state file)"
    fi
    if [[ -f /run/wifi-watchdog/manual_disable ]]; then
        echo "⚠ Watchdog is MANUALLY DISABLED (touch /run/wifi-watchdog/manual_disable)"
    fi
}

case "${1:-}" in
    install)   do_install   ;;
    uninstall) do_uninstall ;;
    status)    do_status    ;;
    *)         usage        ;;
esac
