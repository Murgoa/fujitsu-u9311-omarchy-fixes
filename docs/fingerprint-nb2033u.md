# NEXT Biometrics NB-2033-U fingerprint reader on Linux

Getting the fingerprint reader of a **Fujitsu LIFEBOOK U9311** to work on Arch /
Omarchy, end to end: out-of-tree kernel-less driver build, driver tuning, fprintd,
PAM wiring (sudo / polkit / lock screen) and the Omarchy lock-screen blanking bug
that makes a failed attempt look like a crash.

Everything below was executed and measured on one machine. Numbers are from real
runs, not estimates. Where an approach failed, it is written down — those were the
expensive lessons.

**Tested on:** Fujitsu LIFEBOOK U9311 (i7-1165G7), Arch Linux, kernel 6.x,
Omarchy 4.x, `fprintd 1.94.5`, `libfprint` 1.94.100.

---

## TL;DR

1. The sensor is USB `298d:2033` — **NEXT Biometrics NB-2033-U**, a *thermal* press
   sensor, 256×180 px, 508 dpi. Neither `libfprint` 1.94.100 nor Arch's pinned
   `libfprint-git` has a driver for it.
2. The driver exists as an **open merge request** (libfprint MR !574). Build it from
   that branch, install it under `/usr/local/lib`, and force `fprintd` to prefer it.
3. Ship a udev rule so the device node is usable by your user.
4. The upstream driver works, but its matching quality on this sensor is mediocre
   (~40 % per press). Four driver-level changes bring it to ~75 % per press; the rest
   of the gap is thermal-sensor physics, so raise PAM `max-tries` instead of chasing
   it.
5. The Omarchy lock screen blanks the panel **5 s** after the lock is armed — during
   a fingerprint attempt. Clone the lock plugin and fix the timer, then **restart the
   shell** (editing the QML alone is not enough).

---

## 1. Identify the hardware

```bash
for d in /sys/bus/usb/devices/*/product; do
  v=$(dirname "$d"); printf '%s: %s [%s:%s]\n' "$v" "$(cat "$d")" \
    "$(cat "$v/idVendor" 2>/dev/null)" "$(cat "$v/idProduct" 2>/dev/null)"
done
```

```
/sys/bus/usb/devices/3-5: NB-2033-U [298d:2033]
```

| Property | Value |
|---|---|
| Vendor / product | `298d:2033` — NEXT Biometrics |
| Sensor type | thermal, press (not swipe) |
| Frame | 256 × 180 px, 8-bit grayscale |
| Resolution | 508 dpi → **20 px/mm** |
| Image transport | bulk USB, 180 rows of 256 bytes |

Symptom in the stock system: `fprintd` starts fine, reports **“No devices
available”**, and `omarchy setup security fingerprint` says “No fingerprint sensor
detected” — because `omarchy-hw-fingerprint` only whitelists a handful of vendor IDs
(`27c6 138a 06cb 08ff 1c7a 147e`) and product strings.

## 2. Why it does not work out of the box

```bash
strings /usr/lib/libfprint-2.so.2.0.0 | grep -ci nb2033    # → 0
```

Two independent reasons:

* **Upstream has no driver.** `libfprint` MR !574 (“nb2033: Add support for NB-2033-U
  fingerprint reader”, LGPL-2.1+) is still **open**, so no release contains it.
* **Arch/Omarchy ships `libfprint-git`** — a *pinned snapshot* (`1:1.94.100.r10`), not
  git master. Even “the git package” does not carry the driver, and a `pacman -Syu`
  will happily overwrite anything you drop into `/usr/lib`.

## 3. Build the driver from the merge request

The build is a normal meson build; the traps are all in the *host* dependencies.

```bash
git init libfprint && cd libfprint
git remote add origin https://gitlab.freedesktop.org/libfprint/libfprint.git
git fetch --depth 1 origin merge-requests/574/head
git checkout FETCH_HEAD          # libfprint/drivers/nb2033.c is now present
```

### Trap 1 — `glib-mkenums` is not where the `.pc` file says it is

On current Arch, `glib-mkenums` and `g-ir-scanner` live in `glib2-devel`, which a
plain desktop install does not have. Meson fails with the unhelpful
*“This is a distributor issue”*. Two ways out — the first one requires no root:

```bash
# extract the devel package without installing it
curl -O https://geo.mirror.pkgbuild.com/core/os/x86_64/glib2-devel-2.90.1-1-x86_64.pkg.tar.zst
tar -xf glib2-devel-2.90.1-1-x86_64.pkg.tar.zst -C ./glib-devel

# glib-2.0.pc hardcodes /usr/bin/glib-mkenums — shadow it with a patched copy
mkdir -p pc
sed "s|^glib_mkenums=.*|glib_mkenums=$PWD/glib-devel/usr/bin/glib-mkenums|" \
    /usr/lib/pkgconfig/glib-2.0.pc > pc/glib-2.0.pc
```

```bash
export PKG_CONFIG_PATH=$PWD/pc:/usr/lib/pkgconfig:/usr/share/pkgconfig
export PATH=$PWD/glib-devel/usr/bin:$PATH
```

### Trap 2 — meson 1.12 rejects a one-variable `foreach` over a dict

`tests/meson.build` iterates `drivers_tests` (a dict) with a single loop variable,
which newer meson refuses. Only needed when introspection is off:

```diff
-    foreach driver_test: drivers_tests
-        test(driver_test,
+    foreach _k, driver_test: drivers_tests
+        test(_k,
```

### Configure and build

```bash
meson setup build -Ddoc=false -Dintrospection=false   # introspection needs g-ir-scanner
ninja -C build
```

`-Dintrospection=false` is safe: only Python bindings need it, `fprintd` does not.

### Verify before installing

```bash
ninja -C build examples/enroll        # ships an enroll/verify/img-capture trio
build/examples/enroll                 # should print: claimed by nb2033 driver
```

If the driver claims the device, the rest is plumbing.

## 4. Make the device node usable

```bash
# /etc/udev/rules.d/60-nb2033.rules
SUBSYSTEM=="usb", ATTRS{idVendor}=="298d", ATTRS{idProduct}=="2033", MODE="0666", TAG+="uaccess"
```

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
ls -l /dev/bus/usb/003/003    # → crw-rw-rw-+
```

Without this you get `libusb couldn't open USB device … errno=13`, which looks like a
driver bug but is a permissions bug.

## 5. Install so a package upgrade cannot break it

`pacman` owns `/usr/lib/libfprint-2.so.2.0.0`; every `libfprint-git` upgrade reverts
your driver. Installing into `/usr/local/lib` is not enough either — `/usr/local/lib`
is not in the dynamic linker search path on Arch.

The reliable combination is *both*: keep a copy at `/usr/lib` (so `fprintd` links
against it even before any override) **and** pin `fprintd` to `/usr/local/lib` with a
drop-in, which survives package upgrades.

```bash
sudo cp build/libfprint/libfprint-2.so.2.0.0 /usr/local/lib/
sudo cp build/libfprint/libfprint-2.so.2.0.0 /usr/lib/
sudo ldconfig

sudo mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=LD_LIBRARY_PATH=/usr/local/lib\n' |
  sudo tee /etc/systemd/system/fprintd.service.d/20-nb2033-lib.conf
sudo systemctl daemon-reload && sudo systemctl restart fprintd
```

Confirm the *running daemon* actually loaded your build — this is the check that
matters, not the file on disk:

```bash
sudo grep -o '/[^ ]*libfprint[^ ]*' /proc/$(pgrep -x fprintd)/maps | sort -u
# → /usr/local/lib/libfprint-2.so.2.0.0
```

```bash
fprintd-list "$USER"
# → Fingerprints for user … on NextBiometrics NB-2033-U (press):
```

> **Pitfall:** if you ever run `meson` under `sudo`, the build directory becomes
> root-owned and the next `ninja` fails with exit code 13. `sudo chown -R you: build/`.

## 6. Driver tuning — what actually moved the needle

The stock MR driver captures a frame and hands it to bozorth3 unchanged. On this
thermal sensor that yields roughly **2 of 5 presses** verifying. Five changes, in
order of impact:

| # | Change | Why |
|---|---|---|
| 1 | `img->ppmm = 20.0` | The driver never set it, so NBIS minutiae extraction ran with a scale of **0**. Ridge-spacing expectations are scale-parameterised; this alone was the difference between “sometimes” and “usually”. |
| 2 | Row-mean removal + local contrast normalisation | The sensor output carries strong horizontal banding plus a slow brightness gradient. See §6.1 — the blur radius is the whole trick. |
| 3 | `NB2033_CAPTURE_DWELL` = 600 ms after finger-detect | Thermal image contrast keeps building for a moment after contact. Capturing the instant the detect level crosses the threshold gave washed-out frames. |
| 4 | Quality gate: drop frames with variance < 90, retake (≤ 3) | Handing a blank frame to the matcher is worse than waiting: it burns an attempt the user cannot see. |
| 5 | `bz3_threshold` 40 → 22 | The MR chose a strict threshold. 22 measured best; 18 gave no further gain and widens false-accept risk. |

Also raised: `NB2033_SETTLE_DELAY` 1500 → 2500 ms, because the first capture after
opening the device is otherwise unreliable.

Measured per-press verify rate, same finger, same session:

| Build | Result |
|---|---|
| MR driver, no changes | ~2/5 |
| + `ppmm`, pre-processing, dwell, gate, threshold 22 | **6/8** |
| threshold 18 | 5/8 (no gain → reverted) |
| gradient-based quality gate instead of variance | 2/6, three attempts hit the 30 s timeout (reverted) |

Remaining failures are physical: contact area, finger moisture, and the fact that a
thermal sensor's contrast decays once the finger stops moving.

### 6.1 The blur radius mistake (worth its own section)

The normalisation subtracts a box-blurred copy of the frame:

```c
/* Radius must span several ridge periods (~10 px each at 20 px/mm);
 * a window near one period erases the ridges it is meant to keep. */
const int radius = 40;
```

First attempt used `radius = 8`. At 20 px/mm a ridge period is ~10 px, so a 17 px
window averages **across the ridges themselves** — the “enhancement” low-passed the
fingerprint into a grey blob and matching got *worse*. A background estimate must be
an order of magnitude wider than the feature you want to keep (several ridge periods,
here 40 px ≈ 2 mm).

Band removal and background subtraction are both done on a **summed-area table**, so
the whole 256×180 pass costs microseconds:

```c
data[y][x] = clamp(128 + (data[y][x] - local_box_mean) * gain);
```

## 7. Wiring it into PAM (via Omarchy's own wizard)

Omarchy ships `omarchy setup security fingerprint`, which installs `fprintd`, writes
the PAM stacks and adds a clamshell gate (`pam_exec … omarchy-hw-laptop-closed`) so a
closed lid skips the reader instead of blocking. Use it — but it refuses to run
because of the vendor whitelist in `omarchy-hw-fingerprint`.

The whitelist check honours an environment override, so a throw-away directory is
enough to get past it without patching system files:

```bash
mkdir -p /tmp/fpdev/nb2033
echo "Fingerprint Reader" > /tmp/fpdev/nb2033/product
OMARCHY_USB_DEVICES_PATH=/tmp/fpdev omarchy-setup-security-fingerprint
```

What it writes:

| Path | Content |
|---|---|
| `/etc/pam.d/sudo`, `/etc/pam.d/polkit-1` | `auth sufficient pam_fprintd.so` + clamshell gate |
| `/etc/pam.d/omarchy-lock-fingerprint` | `auth required pam_fprintd.so` |
| `/etc/systemd/system/fprintd.service.d/10-stop-timeout.conf` | bounded stop timeout |
| `~/.config/omarchy/hooks/post-update.d/setup-fingerprint.hook` | re-apply after updates |

**Do not use `omarchy remove security fingerprint` to “temporarily” disable it** — it
deletes the PAM files *and* your enrolled templates. To disable, comment the
`pam_fprintd.so` lines instead.

## 8. PAM tuning for a thermal sensor

Default `pam_fprintd` allows 3 presses per verification, and Omarchy's lock UI adds a
back-off before it starts the next attempt — which reads as “press, wait, press,
wait”. Since a single press verifies ~75 % of the time, more tries *inside one attempt*
is the right lever:

```pam
# /etc/pam.d/omarchy-lock-fingerprint
auth       required   pam_fprintd.so max-tries=6 timeout=30
```

With p ≈ 0.75, six tries fail with probability 0.25⁶ ≈ 0.02 %. The wizard resets this
file to defaults, so re-apply it after any re-run.

## 9. The lock screen blanks while you are still touching the reader

Symptom: you lock the screen, touch the reader, the attempt fails — and the panel goes
black immediately, needing a keypress to come back. It looks like a crash; it is a
timer race.

Root cause is in Omarchy's session lock service (`omarchy.lock`, Quickshell):

```qml
Timer {
  id: idleBlankTimer
  interval: 5000            // ← blanks 5 s after the lock is armed / after a wake
  onTriggered: {
    ...
    if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
  }
}
```

It only holds the display for a **password** check. A fingerprint verification
(claim → detect → dwell → capture → match) routinely takes longer than 5 s, so the
panel is switched off mid-attempt. `runBlank()` also pauses the reader
(`pauseFingerprint()`), which is why the next touch does nothing until you press a key.

Fix it in a **cloned** plugin, never by editing `/usr/share/omarchy`:

```bash
omarchy plugin clone omarchy.lock      # → ~/.config/omarchy/plugins/<user>.lock
```

```qml
Timer {
  id: idleBlankTimer
  interval: 30000          // was 5000: a failed attempt used to race this countdown
  onTriggered: {
    if (Date.now() - armedAt > interval + 2000) { root.armBlankTimer(); return }
    if (root.lockRequested && root.fingerprintAuthenticating) {
      root.armBlankTimer(); return          // never blank mid-attempt; retry the countdown
    }
    if (root.lockRequested && !root.authenticatingPassword) root.runBlank()
  }
}
```

> **Pitfall that cost an hour:** the lock service is `keepLoaded`. Saving the QML (or
> `omarchy-shell shell rescanPlugins`) does **not** replace the already-loaded
> instance — the old 5 s timer keeps running and it looks like the fix did nothing.
> Run `omarchy restart shell`.

Instrument it, because “the screen went black” has several possible authors (lock
timer, `hypridle` DPMS listener, brightness shims):

```qml
function runBlank() { logEvent("blank"); /* … */ }
```

```bash
grep "omarchy lock" "$(ls -td /run/user/$UID/quickshell/by-id/*/ | head -1)/log.log"
```

`blank` lines carry timestamps; if the panel goes dark with no `blank` line, the
culprit is outside the lock plugin (look at `hypridle`'s `dpms` listener).

## 10. Recovery after an accidental removal

`omarchy remove security fingerprint` deletes `fprintd`, the PAM files and the
templates — but it does **not** touch `/usr/local/lib` or `~/.config/omarchy/plugins`.
So the rebuild is:

```bash
sudo pacman -S --noconfirm libfprint-git fprintd
sudo cp /usr/local/lib/libfprint-2.so.2.0.0 /usr/lib/ && sudo ldconfig
sudo systemctl restart fprintd

mkdir -p /tmp/fpdev/nb2033 && echo "Fingerprint Reader" > /tmp/fpdev/nb2033/product
OMARCHY_USB_DEVICES_PATH=/tmp/fpdev omarchy-setup-security-fingerprint
# then re-apply the PAM max-tries tuning from §8
```

## 11. Maintenance checklist

After every system update:

```bash
# 1. does the running daemon still use our library?
sudo grep -o '/[^ ]*libfprint[^ ]*' /proc/$(pgrep -x fprintd)/maps | sort -u
# 2. does the driver still know the device?
fprintd-list "$USER"
# 3. is the lock-screen clone still enabled?
grep -A2 disabledPlugins ~/.config/omarchy/shell.json
```

If a `libfprint`/`libfprint-git` upgrade ever *does* land nb2033 upstream, drop the
drop-in and the copies — the packaged driver is then the right one.

## 12. Files in this repo

| Path | Purpose |
|---|---|
| `patches/nb2033-u9311-tuning.patch` | the four driver changes described in §6, as a diff against MR !574 |
| `scripts/u9311-fingerprint-setup.sh` | build + deploy + PAM setup, start to finish |
| `docs/fingerprint-nb2033u.zh-CN.md` | 中文版本 |

## References

* libfprint MR !574 — `nb2033: Add support for NB-2033-U fingerprint reader`
  (<https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/574>)
* Reverse-engineering notes for this sensor: *NEXT Biometrics NB-2033-U:
  Reverse Engineering eines Fingerabdrucklesers für Linux*
  (<https://www.kernel-error.de/2026/03/17/next-biometrics-nb-2033-u-reverse-engineering-fingerabdruckleser-linux>)
* libfprint API docs — `FpImageDevice`, `bz3_threshold`, `img->ppmm`
* Omarchy plugin model — `omarchy plugin clone`, `~/.config/omarchy/plugins/`
