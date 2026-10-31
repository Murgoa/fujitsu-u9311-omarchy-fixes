# ACPI tables

This directory intentionally does **not** ship a prebuilt `.aml` binary.

An ACPI table override replaces firmware data wholesale. Applying someone else's table to a
different BIOS version, a different model, or even a different firmware revision can prevent
the machine from booting — and unlike a bad kernel, you cannot recover by picking another menu
entry. **Always build the table from your own machine's dump.**

## What the patch does

Source: `/sys/firmware/acpi/tables/SSDT<N>`, the entry whose OEM Table ID is `IgfxSsdt`.

Two changes only:

1. `DefinitionBlock (...)` — OEM revision `0x00003000` → `0x00003001`
2. Delete two occurrences of the following block (the whole `If`, keep the enclosing `If`)

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

Result:

```asl
If ((PDRD () == Zero)){}
```

## Diff sketch

```diff
-DefinitionBlock ("", "SSDT", 2, "INTEL ", "IgfxSsdt", 0x00003000)
+DefinitionBlock ("", "SSDT", 2, "INTEL ", "IgfxSsdt", 0x00003001)

         Method (_DOD, 0, NotSerialized)  // _DOD: Display Output Devices
         {
-            If ((PDRD () == Zero))
-            {
-                If ((VDDE == One))
-                {
-                    VDDE = Zero
-                    Sleep (0x01F4)
-                }
-            }
+            If ((PDRD () == Zero)){}
 
             NDID = 0x02
```

(The second occurrence sits in another display method and looks the same.)

## Pre-flight checks

```bash
# exactly one candidate
sudo sh -c 'for f in /sys/firmware/acpi/tables/SSDT*; do
  grep -a -q "IgfxSsdt" "$f" && echo "$f"; done'

sudo cat /sys/firmware/acpi/tables/SSDT4 > IgfxSsdt-original.aml   # adjust number
sha256sum IgfxSsdt-original.aml
iasl -d IgfxSsdt-original.aml

grep -n "DefinitionBlock" IgfxSsdt-original.dsl     # expect revision 0x00003000
grep -c "VDDE = Zero"     IgfxSsdt-original.dsl     # expect 2
grep -c "Sleep (0x01F4)"  IgfxSsdt-original.dsl     # expect 2
grep -c "PDRD () == Zero" IgfxSsdt-original.dsl     # expect >= 2
```

## Build

```bash
cp IgfxSsdt-original.dsl IgfxSsdt-patched.dsl
# edit the copy: bump the revision, delete the two blocks
iasl -sa IgfxSsdt-patched.dsl        # must be 0 Errors

# verify the result by disassembling it again
cp IgfxSsdt-patched.aml verify.aml && iasl -d verify.aml
grep -c "VDDE = Zero"     verify.dsl   # expect 0
grep -c "Sleep (0x01F4)"  verify.dsl   # expect 0
grep "DefinitionBlock"    verify.dsl   # expect 0x00003001
```

## Deploying

The kernel reads overrides from `kernel/firmware/acpi/*.aml` inside the **early, uncompressed**
part of the initramfs.

- **mkinitcpio (standard Arch)**: put the AML in `/etc/initcpio/acpi_override/`, add the
  `acpi_override` hook to `HOOKS` (before `kms`), run `mkinitcpio -P`.
- **Custom UKI (Limine / ukify)**: use [`../scripts/u9311-rebuild-uki.sh`](../scripts/u9311-rebuild-uki.sh),
  which inserts a single CPIO entry into your existing initrd instead of rebuilding it.

Kernel requirements: `CONFIG_ACPI_TABLE_UPGRADE=y`. Secure Boot lockdown
(`/sys/kernel/security/lockdown` showing `[integrity]` or `[confidentiality]`) blocks table
overrides — check it before you start.

## Confirm at runtime

```bash
sudo journalctl -b -k | grep -iE "Table Upgrade|IgfxSsdt"
```

Required line:

```
ACPI: Table Upgrade: override [SSDT-INTEL -IgfxSsdt]
```

If that line is absent, the override did **not** apply — the AML being present in the initramfs
means nothing on its own. Common causes: wrong initramfs path, AML placed after the CPIO
trailer, or Secure Boot lockdown rejecting the override.
