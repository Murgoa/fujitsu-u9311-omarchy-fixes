# Technical analysis: eDP link training failure after resume on Fujitsu U9311

This document records the full investigation behind the fix described in the
[README](../README.md). It is written so that someone hitting the same symptom can
skip dead ends and reproduce the reasoning.

**Target machine:** Fujitsu LIFEBOOK U9311, Intel Tiger Lake-LP Iris Xe (`0000:00:02.0`),
internal panel Sharp LQ133M1JW42 (`1920x1080@60`, eDP-1, DDI A / PHY A).
Distro: Arch-based (Omarchy), kernel 6.x/7.x series, Hyprland, systemd-boot-equivalent
UKI boot via Limine, LUKS + btrfs root.

---

## 1. The symptom, precisely

After suspend → resume:

- backlight is at full brightness
- the panel shows nothing
- but everything else works: SSH, ping, compositor, DRM

This last point is what makes the bug hard to pin down, and it invalidates two
widely-recommended diagnostic methods:

1. **`hyprctl monitors` says `dpmsStatus: 1`.** The compositor thinks it is driving the output.
   A compositor-level DPMS bug would show `0` here.
2. **Screenshots show a perfect desktop.** `grim` captures what the compositor renders, not what
   the panel receives. When the eDP link is down, the framebuffer is still perfectly valid.

So: *do not* use screenshot output or compositor state to judge whether the panel is lit.
Only the physical panel matters, and only `journalctl -k` tells you about the link.

### Second trap: the error log is delayed and does not mean "still black"

`Failed to enable link training` is emitted when a training attempt fails, but i915 retries.
A *successful* retry logs nothing. In practice:

- the resume-time failure is logged immediately
- a *second* copy of the same message can appear **12–13 seconds later**
- occasionally the panel is already lit while that second message is being written

Consequence: counting error lines is not a valid success metric for any recovery logic. An
early version of the recovery helper used "did the error counter increase?" as the success
test, concluded "failed", issued *another* `disable → enable`, and thereby turned a
screen that had just lit up black again. This produced the (accurate) user report
"it lit up twice and then went black again".

---

## 2. Confirmed log evidence

### Suspend (reproduced on every single suspend)

```
PM: suspend entry (s2idle)
i915 0000:00:02.0: [drm] i915 raw-wakerefs=1 wakelocks=1 on cleanup
WARNING: drivers/gpu/drm/i915/intel_runtime_pm.c:522
         at intel_runtime_pm_driver_release+0x87/0xc0 [i915]
  i915_pm_suspend_late+0xfe/0x130 [i915]      # s2idle path
  i915_pm_freeze_late+0xd6/0xf0 [i915]        # hibernate path
```

Exactly **one** leaked wakeref, every time, in the display path.

### Resume

```
ACPI: PM: Waking up from system sleep state S3
i915 0000:00:02.0: vgaarb: VGA decodes changed: olddecodes=io,decodes=io:owns=io+mem
i915 0000:00:02.0: [drm] *ERROR* [CONNECTOR:588:eDP-1][ENCODER:587:DDI A/PHY A][DPRX]
                          Failed to enable link training
PM: suspend exit
          ... ~12 s later ...
i915 ... *ERROR* [...][DPRX] Failed to enable link training
```

### The clue that narrowed it down

On the LTS kernel, the boot log contained:

```
i915 0000:00:02.0: [drm] drm_WARN_ON(intel_dp->pps.vdd_wakeref)
```

`pps` = **Panel Power Sequencing**. This moved the suspicion from "eDP link / training
algorithm" to "panel power rail state", which is exactly what the ACPI table controls.

Also observed once, when forcing a lower link rate:

```
i915 ... *ERROR* Can't reduce link training parameters after failure
```

i915 tries to fall back to a lower rate, and cannot — consistent with the link partner
(panel) not being powered in the way the driver expects.

### Hardware state during the black screen

```
/sys/class/drm/card1-eDP-1/status   : connected
/sys/class/drm/card1-eDP-1/enabled  : enabled
/sys/class/drm/card1-eDP-1/dpms     : On
/sys/class/backlight/intel_backlight/brightness : 91428 (== max)
```

`i915_display_info` shows plane 1A with a valid framebuffer and `visible=yes`.
Everything the software side can report is "fine".

---

## 3. What was tried, and what it proved

| # | Attempt | Result | Conclusion |
|---|---|---|---|
| 1 | `i915.enable_psr=0` | still black | PSR not involved |
| 2 | `i915.enable_dc=0` | still black | DC not involved |
| 3 | `i915.enable_guc=0` (already 0) | still black | GuC not involved |
| 4 | `mem_sleep=deep` (S3) vs `s2idle` | identical failure | not a sleep-mode issue |
| 5 | `linux-lts` 6.x A/B, same cmdline | identical failure, but exposed `pps.vdd_wakeref` | **not a kernel regression** |
| 6 | `echo 1 > i915_dp_force_link_retrain` | flag accepted, nothing changes | link retrain alone insufficient |
| 7 | `force_link_rate=324000`, `force_lane_count=2` + retrain | still black, then `Can't reduce...` | not a rate/lane problem |
| 8 | `hyprctl` eDP `disable → enable` (1 round) | **sometimes works** | userspace recovery is probabilistic |
| 9 | same, 5 rounds in a row | all failed (error counter 6→11) | repetition does not help |
| 10 | `chvt` VT switch | no new DRM activity | no modeset triggered |
| 11 | `rtcwake -m mem -s 8` (forced resume cycle) | no change | not a resume-ordering issue |
| 12 | `systemctl hibernate` (S4) | **works, zero errors** | S4 re-initialises i915 from scratch → the "restore existing display state" path is the broken one |
| 13 | ACPI `IgfxSsdt` override, **revision only** | boots fine, **still black** | override mechanism OK; revision bump alone is not the fix |
| 14 | ACPI `IgfxSsdt` override, **revision + delete both VDDE blocks** | **fixed** | the VDDE logic is the cause |

### Why #12 is informative

Hibernate restores a disk image and re-runs device initialisation, so i915 programs the
display from a clean state. Suspend/resume instead *restores* previously programmed state.
The fact that only the "clean re-init" path works is consistent with a latent inconsistency
being introduced earlier (by firmware) and merely *surfacing* at resume.

### Why #13 / #14 together are the key evidence

#13 proves the deployment mechanism works (the override loads, the machine boots, only the
revision changed). #14 differs from #13 by exactly one thing: two ASL blocks were deleted.
The outcome flips. That is a proper A/B control, and much stronger than "the log warning
disappeared after we changed something".

This also retroactively explains an earlier false negative: the very first attempt at this
patch "failed to boot". That failure was **not** caused by the AML — it was a broken
initramfs build (see §5). Without the revision-only control experiment, the patch would
have been incorrectly written off.

---

## 4. The ACPI patch

Table: `SSDT`, OEM ID `INTEL`, OEM Table ID `IgfxSsdt`, OEM Revision `0x00003000`,
file `/sys/firmware/acpi/tables/SSDT4` (the only candidate containing the string `IgfxSsdt`).

Two occurrences of this block exist, both inside `If ((PDRD () == Zero))`
(one inside `Method (_DOD)`, one in another display method):

```asl
If ((PDRD () == Zero))
{
    If ((VDDE == One))
    {
        VDDE = Zero
        Sleep (0x01F4)
    }
}
```

After patching (revision `0x00003001`):

```asl
If ((PDRD () == Zero)){}
```

The enclosing conditional is preserved; only the VDD power-down is removed.

### Verification performed

- `iasl -sa`: 0 Errors, 0 Warnings (24 remarks, 3 optimizations — informational only)
- re-disassembled the compiled AML: `VDDE = Zero` count 0, `Sleep (0x01F4)` count 0,
  `PDRD () == Zero` count still 2, OEM revision `0x00003001`
- confirmed the AML is embedded at offset ~1 KB inside the initrd's early CPIO
- confirmed at runtime that the kernel actually accepted it:

```
ACPI: SSDT ACPI table found in initrd [kernel/firmware/acpi/IgfxSsdt.aml][0x31f3]
ACPI: Table Upgrade: override [SSDT-INTEL -IgfxSsdt]
ACPI: SSDT ... (v02 INTEL  IgfxSsdt 00003001 INTEL 20251212)
```

### Results after the patch

Suspend/resume cycles (including one of 10 min 13 s) produced:

```
Failed to enable link training : 0
raw-wakerefs / vdd_wakeref     : 0
```

Both counters had been non-zero on **every** suspend before the patch. The panel comes back
instantly.

---

## 5. Build-chain pitfalls

These are the reasons a correct patch can appear not to work.

### 5.1 Early CPIO size

Measured production initrd layout:

```
[0, 20,057,208)           uncompressed CPIO, 577 entries (microcode + all firmware)
[20,057,208, 20,057,332)  TRAILER!!!
      → 20,060,160        padding
[20,060,160, 37,261,443)  zstd main initramfs (17,201,283 bytes)
```

`grep -abo` finds `\x28\xb5\x2f\xfd` first at offset **114,448** — inside a `.zst` firmware
blob, not at the main image boundary. Slicing there yields a corrupt initrd and:

```
Kernel panic - not syncing: Unable to mount root fs on unknown-block(0,0)
```

Correct approach: walk the CPIO entry chain (110-byte header, `namesize`, `filesize`,
4-byte alignment for both), stop at `TRAILER!!!`, then skip zero padding.

### 5.2 objcopy section replacement

`objcopy --update-section .initrd=...` does not resize a PE section. It writes only as many
bytes as the section originally held and silently drops the rest, returning 0.
Measured: intended 37,274,483 bytes, stored 37,261,443, lost 13,040 bytes.

Use `ukify build`, then verify by extracting the section back and comparing with `cmp`.

### 5.3 Distribution UKI != plain mkinitcpio

| Build | initrd size |
|---|---|
| default hooks | 27,045,446 |
| `-S autodetect` | 230,754,114 |
| production | 37,261,443 |

Neither matches production, so the distro uses its own tooling/templates. Do not try to
reproduce it; modify the existing initrd instead.

### 5.4 Insertion details

- archive format: `newc` (`070701`), header 110 bytes
- path: `kernel/firmware/acpi/<name>.aml`
- must appear **before** `TRAILER!!!`
- any CPIO traversal must honour 4-byte alignment of name and data, otherwise the walk
  desynchronises and you "find" garbage entries

---

## 6. Reproduction checklist for other machines

1. Reproduce the black screen; keep SSH access.
2. `journalctl -b -k | grep -E "link training|raw-wakerefs|vdd_wakeref"`.
   All three signatures → likely this bug.
3. Find the `IgfxSsdt` table; verify OEM revision and **exactly two** matching blocks
   inside `If ((PDRD () == Zero))`.
   **If the structure differs, stop** — the patch is table-specific.
4. Deploy a **revision-only** override first. It must boot and log
   `Table Upgrade: override`, and it must still show the bug. This proves your deployment
   path works, and gives you a control.
5. Only then deploy the patched AML.
6. Verify `Failed to enable link training` stays 0 across several suspends, including a long one.

Steps 4 and 5 are what separate "it seems fixed" from "we know what fixed it".

---

## 7. Remaining open questions

- Why exactly does a firmware-modified VDD rail state manifest specifically as *link training*
  failure rather than, say, a panel power error? The current explanation is consistent with
  the observations but is not a line-by-line proof.
- `drm_WARN_ON(intel_dp->pps.vdd_wakeref)` also fires at boot on this machine, i.e. the
  reference imbalance exists before any suspend. Whether an i915-side fix (reconciling a
  BIOS-enabled VDD without leaking its wakeref) would be a cleaner long-term solution is
  plausible but was not needed here, since the ACPI fix resolves all observed symptoms.
- Whether the same ASL pattern exists in other Fujitsu Tiger Lake models with a *different*
  surrounding structure (U9312, E5411 are reported to share the ArchWiki fix).

---

## 8. Environment notes (for reproducibility)

- `iasl` from `acpica`; `ukify` from `systemd-ukify` (versions matter only for UKI packaging)
- `CONFIG_ACPI_TABLE_UPGRADE=y`, lockdown `[none]`, Secure Boot disabled in this setup
- With a distro-supplied two-kernel setup, the patched and unpatched UKIs were built from the
  **same** `vmlinuz` (`.linux` sections byte-identical); only the initrd differs by one CPIO entry.
