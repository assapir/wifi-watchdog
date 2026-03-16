# wifi-watchdog

A systemd-based WiFi watchdog for Raspberry Pi 5 (and other boards using the Broadcom `brcmfmac` driver).

## Problem

The Broadcom CYW43455 WiFi chip (BCM4345/6) on the Raspberry Pi 5 uses proprietary closed-source firmware that can enter an **unrecoverable state** after transient authentication failures (e.g., during router reboots). When this happens:

- The `brcmfmac` driver floods the kernel log with `brcmf_set_channel: set chanspec ... fail, reason -52`
- The WiFi radio cannot tune to any channel
- NetworkManager scans endlessly but never connects
- **Only a power cycle recovers the chip**

If WiFi is your only network interface (no Ethernet), the Pi becomes unreachable until physically reset.

## Solution

A systemd timer runs every 5 minutes and:

1. **Pings the default gateway** 3 times to check connectivity
2. **Reloads the brcmfmac kernel module** (`modprobe -r` / `modprobe`) and waits up to 30 seconds for NetworkManager to reconnect
3. **Reboots as a last resort** if the module reload doesn't restore connectivity (the chip may need a full power cycle)
4. **Reboot cooldown** — max 1 reboot per hour to prevent reboot loops

## Install

```bash
git clone https://github.com/assapir/wifi-watchdog.git
cd wifi-watchdog
sudo ./install.sh install
```

## Uninstall

```bash
sudo ./install.sh uninstall
```

## Status

```bash
./install.sh status
# or
systemctl list-timers wifi-watchdog.timer
journalctl -u wifi-watchdog -f
```

## Manual override

To temporarily disable the watchdog without uninstalling:

```bash
# Disable
sudo touch /run/wifi-watchdog/manual_disable

# Re-enable
sudo rm /run/wifi-watchdog/manual_disable
```

This file lives in `/run` (tmpfs), so it auto-clears on reboot.

## Configuration

Edit the variables at the top of `wifi-watchdog.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `REBOOT_COOLDOWN` | `3600` | Minimum seconds between watchdog-triggered reboots |

After editing, re-run `sudo ./install.sh install` to update the installed copy.

## How it works

```
Timer fires (every 5 min)
  → ping -c 3 -W 2 <gateway>
  │
  ├─ Any ping succeeds → exit (WiFi is fine)
  │
  └─ All 3 fail
       → modprobe -r brcmfmac_cyw brcmfmac brcmutil
       → sleep 2s
       → modprobe brcmfmac
       → poll gateway every 5s for 30s
       │
       ├─ Recovered → done
       │
       └─ Still dead → check reboot cooldown
            ├─ OK → reboot
            └─ Too soon → log error, wait for next cycle
```

## Logs

```bash
# Follow live
journalctl -u wifi-watchdog -f

# Last 50 entries
journalctl -u wifi-watchdog -n 50

# Only warnings/errors
journalctl -u wifi-watchdog -p warning
```

## Background

- **Chip**: Broadcom BCM4345/6 (CYW43455), connected via SDIO
- **Firmware**: Cypress/Infineon `cyfmac43455-sdio.bin`, version 7.45.265 (Aug 2023) — proprietary, no source
- **Driver**: `brcmfmac` (Linux kernel module)
- **Root cause**: The firmware's radio state machine corrupts after certain WPA handshake failures. The Linux driver cannot reset the firmware over SDIO — only a chip power cycle (reboot) or module reload (sometimes) can recover it.
- **Error -52** (`EBADE`): The firmware rejects all channel-tuning requests, making scanning and association impossible.

## License

GPL-2.0
