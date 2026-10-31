#!/usr/bin/env bash
#
# u9311-rebuild-uki.sh
#
# Rebuild a patched UKI after a kernel update, by taking the *current production UKI*
# and inserting exactly one ACPI table into its initrd.
#
# Why this exists:
#   Fujitsu U9311 firmware ships an IgfxSsdt ACPI table whose _DOD method powers off the
#   eDP panel VDD rail (VDDE = Zero + Sleep(0x1F4)). That desynchronises i915's Panel Power
#   Sequencing state, and after a suspend/resume cycle the panel comes back with backlight on
#   but no picture ("Failed to enable link training").
#   The fix is an ACPI table override carrying a patched IgfxSsdt.
#
# Why not just mkinitcpio:
#   Distributions that boot UKIs often build them with their own tooling (custom hooks,
#   prebuilt templates). Reproducing that with plain `mkinitcpio -P` usually yields a
#   different initramfs. Modifying the existing initrd is far safer.
#
# What this script does:
#   1. extract .initrd / .cmdline / .uname from the production UKI
#   2. locate the matching vmlinuz under /usr/lib/modules/<release>/
#   3. walk the initrd's CPIO entries to find TRAILER!!!, then insert one
#      kernel/firmware/acpi/<name>.aml entry before it
#   4. repack a UKI with `ukify`, verify the .initrd section round-trips byte-for-byte
#   5. only then atomically replace the output file
#
# Usage:
#   sudo ./u9311-rebuild-uki.sh [-p PROD_UKI] [-o OUT_UKI] [-a AML] [-k KERNELRELEASE]
#
# Defaults:
#   PROD = /boot/EFI/Linux/omarchy_linux-omarchy.efi
#   OUT  = /boot/EFI/Linux/u9311-acpi-vdd-fix.efi
#   AML  = /etc/initcpio/acpi_override/IgfxSsdt.aml
#   KERNELRELEASE = value of .uname inside PROD
#
# Requirements: binutils (objcopy), systemd-ukify, python3
#
# License: MIT

set -euo pipefail

PROD=${PROD:-/boot/EFI/Linux/omarchy_linux-omarchy.efi}
OUT=${OUT:-/boot/EFI/Linux/u9311-acpi-vdd-fix.efi}
AML=${AML:-/etc/initcpio/acpi_override/IgfxSsdt.aml}
KREL=${KREL:-}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

while getopts ":p:o:a:k:h" opt; do
    case $opt in
        p) PROD=$OPTARG ;;
        o) OUT=$OPTARG ;;
        a) AML=$OPTARG ;;
        k) KREL=$OPTARG ;;
        h) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option -$OPTARG (use -h)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run as root (it writes into the EFI partition)"
for bin in objcopy ukify python3 cmp; do
    command -v "$bin" >/dev/null || die "missing dependency: $bin"
done
[[ -f $PROD ]] || die "production UKI not found: $PROD"
[[ -f $AML  ]] || die "patched AML not found: $AML"

TMP=$(mktemp -d /tmp/u9311-rebuild.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

say "1/5 extracting from production UKI"
objcopy -O binary --only-section=.initrd  "$PROD" "$TMP/prod.initrd"
objcopy -O binary --only-section=.cmdline "$PROD" "$TMP/prod.cmdline"
objcopy -O binary --only-section=.uname   "$PROD" "$TMP/prod.uname"

[[ -z $KREL ]] && KREL=$(tr -d '\0' < "$TMP/prod.uname")
VMLINUZ="/usr/lib/modules/$KREL/vmlinuz"
[[ -f $VMLINUZ ]] || die "kernel image not found: $VMLINUZ (kernel modules for '$KREL' installed?)"
printf '    kernel release : %s\n' "$KREL"
printf '    initrd         : %s bytes\n' "$(stat -c %s "$TMP/prod.initrd")"

say "2/5 checking kernel/module consistency"
MODDIR="/usr/lib/modules/$KREL"
[[ -d $MODDIR ]] || die "module directory missing: $MODDIR"
printf '    modules dir    : %s\n' "$MODDIR"

say "3/5 inserting AML into the early CPIO"
python3 - "$TMP" "$AML" <<'PY'
import sys

tmp, aml_path = sys.argv[1], sys.argv[2]
data = open(f'{tmp}/prod.initrd', 'rb').read()


def align4(x):
    return (x + 3) & ~3


def newc(name: str, payload: bytes, ino: int = 999) -> bytes:
    nb = name.encode() + b'\0'
    hdr = b'070701'
    for value in (ino, 0o100644, 0, 0, 1, 0, len(payload), 0, 0, 0, 0, len(nb), 0):
        hdr += b'%08X' % value
    assert len(hdr) == 110, len(hdr)
    entry = hdr + nb
    entry += b'\0' * ((-len(entry)) % 4)
    entry += payload
    entry += b'\0' * ((-len(entry)) % 4)
    return entry


# Walk the CPIO chain to find TRAILER!!! and the start of the compressed main image.
# Note: alignment matters. Both the name field and the data field are padded to a
# multiple of 4 relative to the start of the archive, and getting this wrong makes the
# walk desynchronise (it then "discovers" bogus entries inside firmware blobs).
off = 0
trailer_start = None
main_start = None
count = 0
while off + 110 <= len(data):
    if data[off:off + 6] not in (b'070701', b'070702'):
        break
    hdr = data[off:off + 110]
    namesize = int(hdr[94:102], 16)
    filesize = int(hdr[54:62], 16)
    name = data[off + 110:off + 110 + namesize - 1].decode('utf-8', 'replace')
    entry_start = off
    off = align4(off + 110 + namesize)
    off = align4(off + filesize)
    count += 1
    if name == 'TRAILER!!!':
        trailer_start = entry_start
        probe = off
        while probe < len(data) and data[probe] == 0:
            probe += 1
        main_start = probe
        break
    if count > 1_000_000:
        raise SystemExit('error: CPIO walk did not terminate')

if trailer_start is None or main_start is None:
    raise SystemExit('error: CPIO TRAILER not found in initrd')

if data[main_start:main_start + 4] != b'\x28\xb5\x2f\xfd':
    # Not fatal, but worth flagging: the main image is expected to be zstd here.
    print(f'    note: main image does not start with a zstd magic '
          f'({data[main_start:main_start + 4]!r}) - continuing anyway')

payload = open(aml_path, 'rb').read()
entry = newc('kernel/firmware/acpi/IgfxSsdt.aml', payload)
out = data[:trailer_start] + entry + data[trailer_start:main_start] + data[main_start:]
open(f'{tmp}/new.initrd', 'wb').write(out)

print(f'    CPIO entries   : {count} (trailer at {trailer_start}, main image at {main_start})')
print(f'    AML            : {len(payload)} bytes')
print(f'    initrd         : {len(data)} -> {len(out)} (+{len(out) - len(data)})')
PY

say "4/5 repacking UKI with ukify"
ukify build \
    --linux="$VMLINUZ" \
    --initrd="$TMP/new.initrd" \
    --cmdline="$(tr -d '\0' < "$TMP/prod.cmdline")" \
    --os-release=@/etc/os-release \
    --uname="$KREL" \
    --output="$TMP/out.efi"

say "5/5 verifying, then installing"
objcopy -O binary --only-section=.initrd "$TMP/out.efi" "$TMP/verify.initrd"
if ! cmp -s "$TMP/verify.initrd" "$TMP/new.initrd"; then
    die "verification failed: .initrd in the new UKI differs from the input (truncated?)"
fi
printf '    initrd round-trip: OK\n'

# sanity: the AML really is reachable by path
python3 - "$TMP/verify.initrd" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
path = b'kernel/firmware/acpi/IgfxSsdt.aml'
if path not in d:
    raise SystemExit('error: AML path not found in rebuilt initrd')
print('    AML path present : yes')
PY

install -m 600 "$TMP/out.efi" "$OUT"
printf '\ninstalled: %s\n' "$OUT"
printf 'kernel   : %s\n' "$KREL"
sha256sum "$OUT"

cat <<'EOM'

next steps:
  - make sure your bootloader entry points at the file above
  - keep an entry pointing at the UNPATCHED UKI for rollback
  - after booting, confirm the override loaded:
        sudo journalctl -b -k | grep -iE 'Table Upgrade|IgfxSsdt'
    it must contain:  ACPI: Table Upgrade: override [SSDT-INTEL -IgfxSsdt]
EOM
