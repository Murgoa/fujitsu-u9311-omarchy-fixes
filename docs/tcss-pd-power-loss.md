# Second, unrelated bug on the same machine: S3 resume kills USB-C PD, battery drains while plugged in

This is a **different** problem from the eDP black screen documented in the main README.
Both are Fujitsu U9311 firmware defects that surface around suspend/resume, which makes them
easy to confuse. Here the machine is not black because of the panel — it black-screens because
**the battery actually ran flat while the charger was connected**.

## Symptoms

- Laptop is on USB-C power, user is confident the cable is connected.
- After a suspend/resume cycle, the machine keeps running on battery.
- Battery drains all the way down, then at ~2% systemd performs a protective hibernate.
- Machine is now **fully powered off** (hibernate = power off). From outside: no ping, no SSH,
  no ARP reply. Looks exactly like a hard hang.
- Pressing the power button restores from the hibernation image, and charging works again —
  because hibernate restore re-initialises everything from scratch.

## How to recognise it

Suspicious if the battery drains much faster than expected while "plugged in", and:

```bash
# AC is reported offline even though the cable is connected
cat /sys/class/power_supply/AC/online          # 0 = no external power seen
cat /sys/class/power_supply/BAT*/status        # Discharging while plugged in

# And in the kernel log after a resume:
sudo journalctl -b -k | grep -i "xHC error in resume"
# xhci_hcd 0000:00:0d.0: xHC error in resume, USBSTS 0x401, Reinit
# usb usb1: root hub lost power or was reset
```

Also useful — UPower keeps a charge/discharge history:

```bash
sudo tail -30 /var/lib/upower/history-charge-*.dat
# timestamps, percentage, state (charging / discharging / pending-charge)
```

If it shows a long `discharging` run while the machine was supposedly on AC, this is the bug.

## Root cause

`0000:00:0d.0` is the **Thunderbolt 4 / Type-C Subsystem (TCSS) xHCI controller**
(`Intel Tiger Lake-LP Thunderbolt 4 USB Controller`, `8086:9a13`).

On S3 (`deep`) resume the kernel logs:

```
xhci_hcd 0000:00:0d.0: xHC error in resume, USBSTS 0x401, Reinit
```

i915-independent, and the PCH xHCI (`0000:00:14.0`) is unaffected. The kernel then resets and
re-initialises the xHCI, but **only the USB part**. The USB Power Delivery negotiation state,
which is owned by the embedded controller through UCSI (`ucsi_acpi`), is not restored.
The EC keeps believing there is no external supply, so the machine runs on battery.

Measured on the affected machine:

| boot | `deep` sleeps | `s2idle` sleeps | `xHC error` occurrences |
|---|---|---|---|
| A | 2 | 8 | **2** |
| B | 14 | 43 | **7** |
| C | 8 | 8 | **3** |
| D | 0 | 6 | **0** |

**Whenever `deep` (S3) is used, the error appears. Pure `s2idle` boots never show it.**
So the trigger is S3 entering/exiting, not the charging hardware.

## Fix

Two layers, both persistent.

### 1. Keep the TCSS xHCI out of D3

Hypothesis: if the controller is in D3 when S3 is entered, the firmware fails to restore its
context on resume. Forcing D0 avoids that path.

```bash
# /etc/udev/rules.d/99-u9311-tcss-power.rules
ACTION=="add|change", SUBSYSTEM=="pci", KERNEL=="0000:00:0d.0", ATTR{power/control}="on"
```

Apply immediately:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger --action=change --sysname-match="0000:00:0d.0"
cat /sys/bus/pci/devices/0000:00:0d.0/power/control   # -> on
```

Cost: TCSS stays powered while idling (~0.2–0.5 W). Irrelevant during S3, where the platform
is off anyway.

### 2. Re-establish PD negotiation after a resume that failed

Belt and braces: if the error still happens (this fix is empirical — the D3 theory may be
incomplete), re-bind UCSI so the EC redoes PD negotiation.

```bash
# /usr/lib/systemd/system-sleep/50-u9311-tcss-recover.sh
```

Logic:
1. `pre` phase: do nothing.
2. `post` phase: check the last 3 minutes of the kernel log for `xHC error in resume`.
3. If absent → exit (normal resume is never touched).
4. If present → unbind/bind `ucsi_acpi`, which makes the EC redo PD; if AC is still offline,
   reload the module.

Verified behaviour on the affected machine: `unbind`/`bind` of `ucsi_acpi` does **not**
interrupt charging, and `typec port1` re-enumerates within a few seconds.

Script: [`../scripts/50-u9311-tcss-recover.sh`](../scripts/50-u9311-tcss-recover.sh)

Log: `journalctl -t u9311-tcss`

## Alternative: avoid S3 entirely

If the goal is simply "never hit this", use `s2idle` for all sleep states:

```bash
# /etc/systemd/sleep.conf
[Sleep]
MemorySleepMode=s2idle
```

Or drop any per-power-source selector and just keep `/sys/power/mem_sleep` at `s2idle`.
`s2idle` (Modern Standby) is what Intel recommends for Tiger Lake; S3 support on this platform
is legacy and demonstrably broken here.

Trade-off: idle sleep power goes from ~0.3 W to ~1–1.5 W. On a 44 Wh battery that is roughly
10–20 % over an 8-hour night, versus a small but real risk of waking up with an empty battery.

## Notes and open questions

- The D0 hypothesis is plausible but not proven — it needs several S3 cycles to confirm.
  The recovery hook is what makes the setup safe regardless.
- Whether the same defect affects other Fujitsu Tiger Lake models with a TCSS is unknown.
- A BIOS update from Fujitsu could fix the S3/TCSS interaction itself; check the vendor's
  release notes before assuming a software workaround is needed.
