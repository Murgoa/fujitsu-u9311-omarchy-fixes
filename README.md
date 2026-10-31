# Fujitsu LIFEBOOK U9311 on Linux / Arch / Omarchy — fixes & field notes

[![Platform](https://img.shields.io/badge/platform-Arch%20%7C%20Omarchy-informational)](https://archlinux.org)
[![Kernel](https://img.shields.io/badge/kernel-6.x%20%2F%207.x-informational)](#)
[![Status](https://img.shields.io/badge/status-fixed-success)](#)
[![中文](https://img.shields.io/badge/lang-中文-red)](README.zh-CN.md)

Hardware-level fixes for a Fujitsu LIFEBOOK **U9311** running Arch / Omarchy.
Everything here was found, applied and verified on one real machine — not
copied from a wiki. Each fix documents the root cause, the dead ends that
wasted time, and the way to verify it actually worked.

## What's in this repository

| # | Problem | Root cause | Write-up |
|---|---|---|---|
| 1 | **Backlight on, panel black after lid-open / resume** — needs a reboot | BIOS ACPI table `IgfxSsdt` powers down the eDP VDD rail behind i915's back, desynchronising Panel Power Sequencing | [below](#fix-1--edp-panel-black-after-resume) + [docs/technical-analysis.md](docs/technical-analysis.md) |
| 2 | **Fingerprint reader not detected at all** (`298d:2033` NEXT Biometrics NB-2033-U) | The driver exists only as an open libfprint merge request, and Arch ships a pinned `libfprint-git` that does not contain it | [docs/fingerprint-nb2033u.md](docs/fingerprint-nb2033u.md) |
| 3 | **Lock screen goes black right after a failed fingerprint attempt** | Omarchy's session lock blanks the panel 5 s after arming, while a fingerprint verification is still in flight | [docs/fingerprint-nb2033u.md § Lock screen](docs/fingerprint-nb2033u.md#9-the-lock-screen-blanks-while-you-are-still-touching-the-reader) |

Recommended reading order is by symptom, not by number: fix 1 is a boot-time
firmware patch, fixes 2–3 are a userspace stack (driver → fprintd → PAM → lock UI).

## Repo layout

```
acpi/                          reference AML/DSL for the eDP fix
patches/                       local driver patches applied on top of upstream
scripts/u9311-rebuild-uki.sh   inject the ACPI override into an existing UKI
scripts/u9311-fingerprint-setup.sh   build + deploy the NB-2033-U fingerprint stack
docs/technical-analysis.md     eDP failure: full log-level analysis
docs/fingerprint-nb2033u.md    fingerprint reader: full write-up (EN)
docs/fingerprint-nb2033u.zh-CN.md   same, 中文
```

---

## Fix 1 — eDP panel black after resume

Fix for the **backlight on, screen black** issue on Fujitsu LIFEBOOK U9311 (and related
Tiger Lake Fujitsu laptops) after resuming from suspend.

**Root cause: the BIOS ACPI table `IgfxSsdt` forcibly powers down the eDP panel VDD,
which desynchronises i915's Panel Power Sequencing state.**

> **TL;DR** — Patch the `IgfxSsdt` ACPI table: bump the OEM revision to `0x00003001` and
> delete two `If ((VDDE == One)) { VDDE = Zero; Sleep (0x01F4) }` blocks inside
> `If ((PDRD () == Zero))`. Ship it via an ACPI table override in the initramfs.

---

### Table of contents

- [Symptoms](#symptoms)
- [Is this your bug?](#is-this-your-bug)
- [Root cause](#root-cause)
- [Before you start: what does NOT work](#before-you-start-what-does-not-work)
- [The fix](#the-fix)
- [Verification](#verification)
- [Automating the fix for kernel updates](#automating-the-fix-for-kernel-updates)
- [Pitfalls (read this before building anything)](#pitfalls-read-this-before-building-anything)
- [Rollback](#rollback)
- [References](#references)

---

### Symptoms

After closing the lid (suspend) and opening it again:

- **Backlight is fully on, but the screen shows nothing** — a black panel, not a dark one.
- The machine is alive and well:
  - responds to `ping` and SSH
  - `hyprctl monitors` reports `enabled`, `dpmsStatus: 1`, correct mode
  - `grim` (or any screenshot tool) captures a **perfectly normal desktop**, video playing and all
  - the DRM framebuffer holds a valid, visible plane

In other words: the compositor renders fine, but the picture never reaches the panel over eDP.

The only way back is a reboot.

### Is this your bug?

Run this **after reproducing the black screen** (the machine must still be reachable over SSH):

```bash
sudo journalctl -b -k | grep -E "Failed to enable link training|raw-wakerefs|vdd_wakeref"
```

You very likely have this exact bug if you see **all three**:

```
i915 ... [drm] i915 raw-wakerefs=1 wakelocks=1 on cleanup
WARNING: ... intel_runtime_pm.c:522 at intel_runtime_pm_driver_release ... i915_pm_suspend_late
i915 ... *ERROR* [CONNECTOR:...:eDP-1][ENCODER:...:DDI A/PHY A][DPRX] Failed to enable link training
```

And confirm the ACPI table exists:

```bash
sudo sh -c 'for f in /sys/firmware/acpi/tables/SSDT*; do
  grep -a -q "IgfxSsdt" "$f" && echo "FOUND: $f"; done'
```

**Known affected:** Fujitsu LIFEBOOK U9311 (i5-1145G7 / i7-1165G7, Tiger Lake, Sharp LQ133M1JW42 panel).
The same ArchWiki patch is documented for U9312 and E5411 series.

**Note:** a very similar looking symptom can also come from a compositor-level DPMS bug
(the panel is simply left DPMS-off after resume). Check `hyprctl monitors` first — if it says
`dpmsStatus: 0`, that is a different, much simpler problem.

### Root cause

The BIOS-provided SSDT named `IgfxSsdt` (OEM ID `INTEL`, OEM Table ID `IgfxSsdt`,
OEM Revision `0x00003000`) contains, in `_DOD` and one other method, inside
`If ((PDRD () == Zero))`:

```asl
If ((PDRD () == Zero))
{
    If ((VDDE == One))
    {
        VDDE = Zero       // turn OFF the eDP panel VDD rail
        Sleep (0x01F4)    // wait 500 ms
    }
}
```

`VDDE` is **VDD Enable** for the eDP panel. Meanwhile i915's `intel_pps`
(Panel Power Sequencing) takes over that same rail during init and holds an AUX
power-domain wakeref for it.

The two never agree on who owns the rail. It stays latent until suspend/resume, where it
surfaces as:

1. a leaked runtime-PM reference at `i915_pm_suspend_late`
   (`raw-wakerefs=1 wakelocks=1 on cleanup`)
2. a failed eDP link training on resume (`Failed to enable link training`)
3. backlight on, no picture

A related kernel warning points straight at the panel power sequencer:

```
i915 ... [drm] drm_WARN_ON(intel_dp->pps.vdd_wakeref)
```

> This is the causal chain as best as it can be established from logs plus an A/B experiment.
> The precise reason why the VDD rail state desynchronises *link training* specifically is not
> fully explained. What *is* reproducible: removing the two ASL blocks removes all three symptoms.

### Before you start: what does NOT work

Save yourself the time. All of the following were tested on real hardware and did **not** help:

| Attempt | Why it fails |
|---|---|
| `i915.enable_psr=0`, `enable_dc=0`, `enable_fbc=0`, `enable_guc=0` | Driver-side power features. The root cause is in ACPI, not in i915's power policy. |
| Switching kernel (`linux`, `linux-lts`, `linux-zen`) | The patch lives in the firmware table, not in the kernel. |
| `mem_sleep` → `deep` (S3) instead of `s2idle` | Both resume paths re-train eDP, both fail. |
| `i915_dp_force_link_retrain` (debugfs) | Panel power is already inconsistent; forcing a retrain does not help. |
| Forcing a lower link rate / lane count | Same. Emits `Can't reduce link training parameters after failure`. |
| Userspace `eDP-1 disable → enable` | **Occasionally** works — which is exactly what makes this bug so confusing. Not reliable. |
| `hibernate` (S4) | **Does work** (S4 restores from a disk image and re-initialises i915 from scratch), but a ~2 minute resume is not acceptable for daily use. |
| Just raising the ACPI OEM revision without changing AML | Starts fine, still black on resume. This is the crucial control experiment — see [docs/technical-analysis.md](docs/technical-analysis.md). |

### The fix

#### Step 1 — Identify and verify the table

```bash
sudo sh -c 'for f in /sys/firmware/acpi/tables/SSDT*; do
  grep -a -q "IgfxSsdt" "$f" && echo "$f"; done'
```

**Exactly one** candidate must be found. Then dump and disassemble it:

```bash
sudo cat /sys/firmware/acpi/tables/SSDT4 > IgfxSsdt-original.aml   # adjust the number
iasl -d IgfxSsdt-original.aml
head -30 IgfxSsdt-original.dsl
```

Verify in the `DefinitionBlock` line: OEM Table ID `IgfxSsdt`, OEM Revision `0x00003000`.
And verify the two target blocks exist **exactly twice**, both inside `If ((PDRD () == Zero))`:

```bash
grep -c "VDDE = Zero"        IgfxSsdt-original.dsl        # must be 2
grep -c "Sleep (0x01F4)"     IgfxSsdt-original.dsl        # must be 2
grep -c "PDRD () == Zero"    IgfxSsdt-original.dsl        # must be >= 2
```

**If any of these do not match, stop.** This patch is table-specific. Do not "adapt" it by
similarity — a wrong ACPI table can prevent the machine from booting.

#### Step 2 — Patch and compile

Edit a **copy** of the `.dsl`:

1. In the `DefinitionBlock (...)` line, change `0x00003000` → `0x00003001`.
2. Delete both `If ((VDDE == One)) { VDDE = Zero; Sleep (0x01F4) }` blocks (the whole `If`,
   keep the enclosing `If ((PDRD () == Zero)) {}`).

Then:

```bash
iasl -sa IgfxSsdt-patched.dsl        # must report 0 Errors
```

Re-disassemble the result and confirm: no `VDDE = Zero` left, no `Sleep (0x01F4)` left,
revision is `0x00003001`, and the rest of the table is untouched.

`acpi/IgfxSsdt-patched.dsl` in this repo is a reference of what the patched result looks like
(taken from a U9311 with BIOS-provided table revision `0x3000`). **Do not ship someone else's
AML — always rebuild from your own dump**, even if the diff looks identical.

#### Step 3 — Put the AML into the initramfs

The kernel reads ACPI overrides from `kernel/firmware/acpi/*.aml` inside the **early,
uncompressed** part of the initramfs.

**Option A — mkinitcpio with the `acpi_override` hook (standard Arch setups):**

```bash
sudo mkdir -p /etc/initcpio/acpi_override
sudo cp IgfxSsdt-patched.aml /etc/initcpio/acpi_override/IgfxSsdt.aml
# add acpi_override to HOOKS in /etc/mkinitcpio.conf, before kms:
#   HOOKS=(base systemd autodetect microcode modconf acpi_override kms ...)
sudo mkinitcpio -P
```

**Option B — do not rebuild the initramfs at all (safer for custom UKI setups):**

Take your existing production UKI, insert one CPIO entry into its initrd, and repack with
`ukify`. This is what [scripts/u9311-rebuild-uki.sh](scripts/u9311-rebuild-uki.sh) does.
Read [Pitfalls](#pitfalls-read-this-before-building-anything) first — naive approaches here
produce an unbootable image.

#### Step 4 — Boot and confirm the override actually loaded

```bash
sudo journalctl -b -k | grep -iE "Table Upgrade|IgfxSsdt"
```

You must see:

```
ACPI: SSDT ACPI table found in initrd [kernel/firmware/acpi/IgfxSsdt.aml][0x31f3]
ACPI: Table Upgrade: override [SSDT-INTEL -IgfxSsdt]
ACPI: SSDT ... (v02 INTEL  IgfxSsdt 00003001 ...)
```

**"The AML is in the initramfs" is not proof.** Only the `Table Upgrade: override` line is.

### Verification

```bash
# before suspending, note the counters
sudo journalctl -b -k | grep -c "Failed to enable link training"

systemctl suspend            # or just close the lid
# ... wake up ...

sudo journalctl -b -k | grep -cE "Failed to enable link training|raw-wakerefs|vdd_wakeref"
```

The counter must stay at **0** after several suspend/resume cycles, including a long one
(10+ minutes). Test with the lid as well as with an explicit `systemctl suspend`, since
lid-triggered suspend usually has a debounce delay.

### Automating the fix for kernel updates

If you used **Option A** (mkinitcpio hook), the fix survives kernel updates automatically.

If you used **Option B** (standalone patched UKI), you must regenerate that UKI after every
kernel update:

```bash
sudo u9311-rebuild-uki.sh
```

The script extracts `.initrd` / `.cmdline` / `.uname` from the **current production UKI**,
locates the matching `vmlinuz`, inserts the AML before the CPIO `TRAILER!!!`, repacks with
`ukify`, verifies the result byte-for-byte, and only then replaces the file.

Always check afterwards that the patched UKI really uses the **new** kernel:

```bash
objcopy -O binary --only-section=.uname /boot/EFI/Linux/<patched>.efi /dev/stdout
```

### Pitfalls (read this before building anything)

Each of these cost hours and produced misleading "the patch doesn't work" conclusions.

#### 1. The early CPIO is ~20 MB, not ~114 KB

A typical U9311 initrd looks like this:

```
[0, 20,057,208)           uncompressed CPIO — 577 entries: microcode + ALL firmware (*.zst)
[20,057,208, ...)         CPIO TRAILER!!!
      → 20,060,160        zero padding
[20,060,160, 37,261,443)  zstd-compressed main initramfs
```

The offset `114,448` also contains `\x28\xb5\x2f\xfd` (the zstd magic) — because
**individual firmware files are themselves zstd-compressed**. Splitting on "the first zstd
magic" slices through the firmware CPIO and produces:

```
Kernel panic - not syncing: Unable to mount root fs on unknown-block(0,0)
```

**Parse the CPIO properly** (remember 4-byte alignment on both name and data) until you hit
`TRAILER!!!`; the first non-zero byte after it is the start of the compressed main image.

#### 2. `objcopy --update-section` may silently truncate

```bash
objcopy --update-section .initrd=new.initrd in.efi out.efi   # dangerous
```

On PE/COFF it overwrites only the prefix of the existing section length and **discards the
tail**, while returning exit code 0. Measured here: wrote 37,274,483 bytes, kept 37,261,443,
lost 13,040 bytes of the compressed main image.

Use `ukify build` and **always** verify:

```bash
objcopy -O binary --only-section=.initrd out.efi check.initrd
cmp check.initrd new.initrd        # must be silent
```

#### 3. You cannot reproduce a distro's UKI with plain `mkinitcpio`

| Build | resulting initrd |
|---|---|
| default (with `autodetect` hook) | 27,045,446 |
| `-S autodetect` (skip autodetect) | 230,754,114 |
| actual production UKI | **37,261,443** |

Neither matches. Distro tooling (`limine-mkinitcpio`, `prebuilt-uki.efi` templates, extra
drop-ins) differs from upstream defaults. Prefer modifying the existing production initrd.

#### 4. The AML entry must sit before `TRAILER!!!`

Appending after the trailer is silently ignored. Use newc (magic `070701`), 110-byte header,
name and data each padded to a multiple of 4.

### Rollback

| Scope | How |
|---|---|
| One boot only | Pick the unpatched entry in the bootloader menu |
| Permanent | Point the default entry back to the unpatched one |
| Full removal | Delete the patched UKI / remove the `acpi_override` hook and AML, rebuild initramfs |

If you keep both a patched and an unpatched UKI built from the **same** kernel, the unpatched
one is a complete rollback for the ACPI change — no extra kernel installation is needed.

> Keeping an *older* kernel as a "rollback" is **not** equivalent: its module tree may be gone
> after a package update.

### References

- ArchWiki — Fujitsu Lifebook U9311: <https://wiki.archlinux.org/title/Fujitsu_Lifebook_U9311>
- Linux kernel — ACPI initrd table override: <https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html>
- Omarchy issue #9628 / PR #9637 (lid-open DPMS recovery) — a *different* bug with a similar symptom
- Omarchy issue #12193 (logind/Hyprland suspend race)
- Upstream ACPI patch project for U9311: <https://github.com/suikan4github/u9311-acpi-patch>

### Detailed write-up

See [docs/technical-analysis.md](docs/technical-analysis.md) for the full investigation,
the reference experiment matrix, log excerpts, and the reasoning behind each conclusion.

### License

MIT — see [LICENSE](LICENSE). Use at your own risk; ACPI overrides can prevent boot.
