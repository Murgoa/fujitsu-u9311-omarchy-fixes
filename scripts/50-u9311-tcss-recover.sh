#!/usr/bin/env bash
# 50-u9311-tcss-recover.sh
#
# Install to: /usr/lib/systemd/system-sleep/50-u9311-tcss-recover.sh  (chmod 755)
#
# Fujitsu U9311 S3 (deep) resume defect compensation:
#   The Thunderbolt 4 / Type-C subsystem (TCSS) xHCI (0000:00:0d.0) fails to resume:
#       xhci_hcd 0000:00:0d.0: xHC error in resume, USBSTS 0x401, Reinit
#   The kernel re-initialises the USB part only. USB Power Delivery negotiation,
#   owned by the EC via UCSI (ucsi_acpi), is not restored -- so the machine keeps
#   running on battery even though a USB-C charger is connected, until it runs flat
#   and systemd hibernates (which from the outside looks like a hard hang).
#
# This hook re-binds UCSI after such a resume so the EC redoes PD negotiation.
# Verified: unbind/bind of ucsi_acpi does not interrupt charging, and the typec
# port re-enumerates within a few seconds.
#
# Only runs when the xHC resume error is actually present, so normal resumes are
# never touched. Log: journalctl -t u9311-tcss
#
# Uninstall: delete this file.
#
# See docs/tcss-pd-power-loss.md for the full write-up.

set -uo pipefail

log() { logger -t u9311-tcss "$*" 2>/dev/null || true; }

[ "${1:-}" = "post" ] || exit 0

# Only act if this resume actually hit the TCSS defect.
if ! journalctl -k -b --since "-3 min" --no-pager 2>/dev/null | grep -q "xHC error in resume"; then
    exit 0
fi

log "TCSS xHCI resume error detected - recovering PD negotiation"

ac_online() { cat /sys/class/power_supply/AC/online 2>/dev/null; }

# 1) Re-bind UCSI so the EC re-reports PD state.
if [ -e /sys/bus/platform/drivers/ucsi_acpi/USBC000:00 ]; then
    log "rebinding ucsi_acpi"
    echo -n "USBC000:00" > /sys/bus/platform/drivers/ucsi_acpi/unbind 2>/dev/null || true
    sleep 2
    echo -n "USBC000:00" > /sys/bus/platform/drivers/ucsi_acpi/bind 2>/dev/null || true
    sleep 3
fi

# 2) Still no external power: reload the module for a harder reset.
if [ "$(ac_online)" != "1" ]; then
    log "AC still offline after rebind, reloading ucsi_acpi"
    modprobe -r ucsi_acpi 2>/dev/null || true
    sleep 1
    modprobe ucsi_acpi 2>/dev/null || true
    sleep 3
fi

log "recovery done, AC_online=$(ac_online), battery=$(cat /sys/class/power_supply/CMB1/status 2>/dev/null)"
