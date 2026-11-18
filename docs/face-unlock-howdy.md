# IR camera & Windows-Hello-style face unlock on the U9311

Getting the **Fujitsu LIFEBOOK U9311** camera to actually unlock Arch / Omarchy with your face —
on the lock screen, for `sudo`, at the SDDM greeter, and through polkit (which is where
1Password's verification lives).

Same rule as the fingerprint write-up: everything below was executed and measured on one real
machine, and the approaches that failed are included. Those are the expensive part.

**Tested on:** Fujitsu LIFEBOOK U9311 (i7-1165G7), Arch Linux, kernel 6.x, Omarchy 4.x,
`howdy-next 3.4.2`, OpenCV 5.0.0.

> 中文完整版：[face-unlock-howdy.zh-CN.md](face-unlock-howdy.zh-CN.md)

---

## TL;DR

1. **This machine has an IR camera.** `lsusb` shows a single `FJ Camera`, but that one USB device
   registers **four** video nodes, and `/dev/video2` has `Card type: FJ Camera: IR Camera` with
   `GREY` 640×360. **Do not use the colour node** — colour face recognition can be fooled by a
   photograph; IR cannot.
2. Use `howdy-next` from the AUR (C++ rewrite, OpenCV YuNet + SFace). No dlib, ~10 min to build,
   and far less trouble than the original Python howdy.
3. **`timeout` must be raised to 20.** howdy-next gives the compare child an `RLIMIT_CPU` of
   `timeout + 5 s` (soft) / `timeout + 10 s` (hard), with a 15 s floor. The default `timeout = 4`
   leaves 9 s of CPU; IR frames burn through that during SFace inference and the process is killed
   by `SIGXCPU`, surfacing as `Face verification timed out` **with no output at all**.
   Raising it to 20 took the pass rate from 1/6 to 8/8.
4. Enrol **3–5** models. One model scores 0.60–0.70 (threshold 0.6942) — marginal. With four,
   scores land at 0.67–0.94 and it just works.
5. `howdy test` is an **interactive preview window** that hangs until timeout. It cannot be used
   for scripted verification. To read a score you must set `end_report` and run
   `/usr/lib/howdy/howdy-compare <user>` directly.
6. **1Password's verification goes through polkit, not its own PAM.** To make 1Password prefer
   your face, edit `/etc/pam.d/polkit-1`. Nothing in 1Password's settings will help.
7. **`/dev/v4l/by-id/...-video-index0` is not a stable path.** The `indexN` in that name is the
   sysfs `index` value, not a node number, and this camera's colour and IR sensors both report
   `index=0` — so after a reboot the link moves from the IR node to the colour node and face auth
   dies with `cannot open configured camera`. **This bit me in production.** Identify by sysfs
   `name` + `index` and re-pin at boot (§1).

---

## 1. Identifying the hardware: the IR node `lsusb` hides

My first pass nearly concluded "no IR here, colour only":

```bash
$ lsusb
Bus 003 Device 004: ID 04f2:b703 Chicony Electronics Co., Ltd FJ Camera
```

One camera, no second infrared device. Looks like a plain RGB webcam.

**That conclusion was wrong.** A single UVC device registers several video nodes — capture,
metadata, and a **separate IR sensor**. You have to ask each node what it is:

```bash
$ for d in /dev/video*; do
    printf '%-12s %s\n' "$d" "$(v4l2-ctl -d "$d" --info 2>/dev/null | grep 'Card type')"
  done
```

```
/dev/video0  Card type        : FJ Camera: FJ Camera
/dev/video1  Card type        : FJ Camera: FJ Camera
/dev/video2  Card type        : FJ Camera: IR Camera      ← this one
/dev/video3  Card type        : FJ Camera: IR Camera
```

The formats make the difference obvious:

```bash
$ v4l2-ctl -d /dev/video2 --list-formats-ext
[0]: 'GREY' (8-bit Greyscale)
        Size: Discrete 640x360
            Interval: Discrete 0.033s (30.000 fps)
```

**Greyscale only, one resolution, no MJPG/YUYV** — that is the IR channel. The colour node offers
`MJPG` 1280×720 and `YUYV` 640×480.

Grab a frame to confirm (`</dev/null` is mandatory, or ffmpeg waits on stdin until it times out):

```bash
ffmpeg -f v4l2 -video_size 640x360 -input_format gray \
       -i /dev/video2 -frames:v 1 -update 1 -y /tmp/ir.jpg </dev/null
```

**Why IR matters:** photographs and LCD panels do not emit infrared. Visible-light face
recognition is essentially texture matching — a printed photo, or even a photo on a phone screen,
can pass. An IR image only shows reflectance under active illumination, and a photo of a face is
black in that band. This is exactly why Windows Hello uses IR, and it is the only correct choice
here.

### Do not use `by-id`, and do not hard-code `/dev/videoN`

This section is the single most important correction in this write-up. The first revision of this
document recommended `/dev/v4l/by-id/`. That was wrong, and wrong in a way that hides: it works
right up until some reboot.

The links look like this:

```bash
$ ls -la /dev/v4l/by-id/
usb-SunplusIT_Inc_FJ_Camera_01.00.00-video-index0 -> ../../video2
usb-SunplusIT_Inc_FJ_Camera_01.00.00-video-index1 -> ../../video3
```

`index0` reads as "the zeroth capture node", stable and reliable. **But the `indexN` in that name is
not a node number — it is the value of the sysfs `index` file:**

```bash
$ for f in /sys/class/video4linux/video*/index; do echo "$f = $(cat $f)"; done
/sys/class/video4linux/video0/index = 0     # colour capture
/sys/class/video4linux/video1/index = 1     # colour metadata
/sys/class/video4linux/video2/index = 0     # IR capture     ← collides with video0
/sys/class/video4linux/video3/index = 1     # IR metadata
```

**This camera has two sensors — colour and IR — and both report `index=0`.** So which node
`...-video-index0` points at is decided by enumeration order. Measured here:

| | `...-video-index0` points at | Result |
|---|---|---|
| day of setup | `video2` (IR) | fine, 8/8 |
| **after one reboot** | **`video0` (colour)** | `Failed to open camera device` |

Face unlock died on the first reboot, with this in the log:

```
pam_howdy(sudo:auth): Face verification failed: cannot open configured camera
```

The worse case is silent: had the colour node opened, face auth would have **quietly switched to the
colour camera** — apparently working, but no longer IR, which was the entire reason for choosing it.

### The right way: identify by sysfs name + index, and re-derive it at boot

```bash
for d in /sys/class/video4linux/video*; do
  [[ $(cat "$d/name") == *"IR Camera"* && $(cat "$d/index") == 0 ]] \
    && echo "/dev/$(basename "$d")"
done
# → /dev/video2
```

`name` is the string the driver reports and `index` separates capture from metadata; together they
are unique and do not move with enumeration order. The **number** in `/dev/videoN` still moves, so it
must not be hard-coded either — it gets rewritten at boot.
`scripts/u9311-face-unlock-setup.sh --pin` installs a systemd oneshot plus a udev rule to do exactly
that:

```bash
# the core of it, installed as /usr/local/bin/u9311-ir-camera-pin
ir=""
for d in /sys/class/video4linux/video*; do
  [[ $(cat "$d/name") == *"IR Camera"* ]] || continue
  [[ $(cat "$d/index") == 0 ]] || continue
  ir="/dev/$(basename "$d")"; break
done
[[ $(sed -n 's/^device_path = //p' /etc/howdy/config.ini) == "$ir" ]] || howdy set device_path "$ir"
```

The udev rule also fires on resume / re-enumeration:

```
ACTION=="add", SUBSYSTEM=="video4linux", ATTR{name}=="*IR Camera*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="u9311-ir-camera-pin.service"
```

> Aside: the vendor string is **SunplusIT** while `lsusb` reports Chicony — both are correct. One
> comes from the USB descriptor's `iManufacturer`, the other from the `idVendor` vendor database.

---

## 2. Why not the original howdy

The original `howdy` (boltgolt/howdy) is Python + `dlib`: building dlib takes 30–60 minutes and
frequently breaks on CUDA/AVX, it needs `pam-python` (a Python 2 era artefact), and the model
chain is dlib's `shape_predictor_68_face_landmarks` plus a ResNet.

`howdy-next` is a C++ reimplementation of the same idea:

| | howdy (original) | howdy-next |
|---|---|---|
| Language | Python | C++ |
| Detection | dlib HOG/CNN | OpenCV **YuNet** (ONNX) |
| Embedding | dlib ResNet | OpenCV **SFace** (ONNX) |
| Dependencies | `python-dlib`, `pam-python` | `opencv`, `pam`, `libinih`, `yyjson` |
| Build time | 30–60 min | ~10 min |
| PAM module | `pam_python.so` calling back into Python | native `pam_howdy.so` |

```bash
yay -S howdy-next
sudo howdy download-models     # YuNet + SFace → /usr/share/howdy/models
```

The package prints a SETUP checklist on install; follow it.

> There is also `visagate` (RGB+IR for Logitech webcams), but it only supports Logitech hardware.

---

## 3. Configuration

`howdy set` accepts **bare key names only** — not `section.key`:

```bash
sudo howdy set device_path video.device_path       # ✗ Could not find a "video.device_path" config option
sudo howdy set device_path /dev/video2             # ✓
```

Negative values must be escaped with `--`, or they are parsed as flags:

```bash
sudo howdy set frame_width -1          # ✗ error: unexpected argument '-1' found
sudo howdy set frame_width -- -1       # ✓
```

The working configuration (`/etc/howdy/config.ini`):

```ini
[core]
abort_if_lid_closed = false    # must still unlock when docked with the lid shut
disabled = false

[video]
device_path = /dev/video2        # re-pinned at boot; never hard-code this — see §1
timeout = 20                   # ← critical, see §4
max_height = 320               # downscale for speed; 320 is plenty for YuNet
frame_width = 640
frame_height = 360
dark_threshold = 85            # IR overexposes at close range; below 80 you get false "too dark"
clahe_enabled = true           # contrast enhancement for low-contrast IR frames — helps
exposure = -1                  # keep auto-exposure
rotate = 0

[face]
yunet_score_threshold = 0.6    # default 0.8845 is too strict for overexposed frames
sface_threshold = 0.60         # temporarily relaxed while only one model exists
```

---

## 4. The expensive one: `Face verification timed out` is really a CPU limit

This cost the most hours of the whole exercise.

Symptom: PAM fails with a single line

```
pam_howdy(howdy-test:auth): Face verification timed out
```

and running the compare process directly produces **no output at all**, exit code 11
(`kTimeoutReached`):

```bash
$ sudo /usr/lib/howdy/howdy-compare murgo
[ WARN:0@0.010] global net_impl_backend.cpp:345 setPreferableTarget Targets are not supported...
[ WARN:0@0.043] ...
$ echo $?
11
```

Yet the same command sometimes succeeds and prints a perfectly healthy report:

```
Total time: 3758ms
Frames searched: 38
Black frames ignored: 19
Winning score: 0.739385
```

Succeeding one moment and timing out the next looks like flaky hardware, or the IR illuminator
stuttering. **Neither.**

### Root cause

`sandbox.cpp` in howdy-next sets a set of rlimits on the compare child before dropping privileges.
CPU time is computed like this:

```cpp
constexpr rlim_t kCpuSoftMargin = 5;
constexpr rlim_t kCpuHardMargin = 10;
constexpr rlim_t kCpuSoftFloor  = 15;

preferred_cpu_soft = max(timeout_seconds + kCpuSoftMargin, kCpuSoftFloor);
preferred_cpu_hard = max(timeout_seconds + kCpuHardMargin, kCpuHardFloor);
```

With the default `timeout = 4`, that is a **9 s soft** and 14 s hard limit.

The IR pipeline is "capture several frames → YuNet detect → SFace encode each face → cosine
match", and none of that is cheap at 640×360. Once CPU time hits the soft limit the kernel sends
`SIGXCPU` and the process dies on the spot — **no output, exit code 152 (128+24)**.

The crucial detail: **on failure it never reaches the "timeout" branch; it is killed by a signal.**
The PAM layer then maps an abnormal child exit onto the `kTimeoutReached` message. The log lies.

Which also explains the flakiness: on an idle machine with few frames it lands inside 9 s and
succeeds; a handful of extra frames pushes it over.

### Measurements

Same position, same lighting, only `timeout` changed, 2 s between runs:

| `timeout` | CPU soft limit | Pass rate | Notes |
|---|---|---|---|
| 4 (default) | 9 s | **1 / 6** | every failure was a silent exit |
| 8 | 13 s | 3 / 5 | |
| 12 | 17 s | 5 / 6 | one `code=152`, `CPU time limit exceeded` |
| **20** | **25 s** | **8 / 8** | |

The single failure at `timeout = 12` gave the game away via the shell:

```
/usr/bin/bash: line 1: 959159 CPU time limit exceeded    sudo /usr/lib/howdy/howdy-compare murgo
```

> **How to tell if this is your bug:** run `howdy-compare` directly and look at the exit code.
> `0` matched / `11` genuine timeout / `152` killed by `SIGXCPU` / `13` too dark /
> `14` camera unopenable / `10` no enrolled model. **With default settings, "11" is almost always
> a mis-reported 152.**

---

## 5. Enrolling: use several

```bash
sudo howdy add --plain -y     # repeat 3–5 times, varying distance and angle
sudo howdy list
```

```
0   2026-11-12 22:24:47  Model #0
1   2026-11-12 22:42:46  Model #1
2   2026-11-12 22:42:51  Model #2
3   2026-11-12 22:42:57  Model #3
```

SFace matches "compare against every enrolled embedding, keep the best", so extra samples at
different poses raise the ceiling directly:

| Models | Score range | vs. threshold 0.6942 |
|---|---|---|
| 1 | 0.60 – 0.70 | marginal, coin-flip |
| 4 | 0.67 – 0.94 | reliably passes |

**Distance during enrolment matters.** At close range (< 20 cm) the IR illuminator blows the face
out into a white blob:

| Distance | Frame | Recognisable |
|---|---|---|
| up against the lens | all white, only the spectacle reflections left | barely — via outline and frames, but ugly |
| **40–60 cm** | features clear, lenses black (IR does not pass glass) | **best** |
| > 1 m | face too small, YuNet misses it | no |

---

## 6. Verification: `howdy test` fools people

`howdy test` opens an OpenCV HighGUI preview window (Qt/Wayland) and **hangs until you close it or
time out**. In a non-interactive shell it prints nothing useful, which reads as "stuck":

```bash
$ timeout 25 sudo howdy test -U murgo
qt.qpa.wayland.textinput: ... Trying to disable 0x55c411284c00 but 0x0 is focused
$ echo $?
124        # killed by timeout, not a self-exit
```

**The right way** is to call the compare entry point with `end_report` on:

```bash
sudo howdy set end_report true

for i in 1 2 3; do
  sudo /usr/lib/howdy/howdy-compare murgo
  echo "exit=$?"
  sleep 2
done

sudo howdy set end_report false     # remember to turn it back off
```

On success:

```
Total time: 1364ms
Frames searched: 2
Black frames ignored: 1
Dark frames ignored: 0
Winning score: 0.93688
Winning model: 0 ("Model #0")
```

`Frames searched: 2` and 1.3 s mean it **does not** wait out `timeout` — it returns as soon as a
frame matches. `timeout = 20` is only ever consumed when there is no face to be found.

### At the PAM layer, `pamtester` needs `-v`

```bash
yay -S pamtester
pamtester -v <service> murgo authenticate </dev/null
```

**Without `-v` even a success only prints a bare `pamtester: successfully authenticated`**, and a
failure says nothing useful — easy to misdiagnose. With `-v` you get `Face matched user murgo`.

Also test in a no-TTY environment, which is what the lock screen actually is:

```bash
setsid pamtester -v <service> murgo authenticate </dev/null
```

---

## 7. Wiring into PAM: four entry points

The rule is the same everywhere: **`sufficient`, with the password always as a fallback.** A face
miss must never leave you worse off than not having face unlock at all.

> **Open a root shell before you touch any of this** (`sudo -i`, or log in as root on another TTY).
> A broken PAM stack leaves you unable to `sudo` *and* unable to log into the desktop, and only a
> root shell or a live USB gets you back. This is not hypothetical — every change in `scripts/`
> keeps a `.bak.<timestamp>` for exactly that moment.

### 7.1 `sudo`

This machine already has fingerprint on `sudo` (`pam_fprintd.so`). Face goes **first**, with the
fingerprint demoted to a fallback:

```bash
# /etc/pam.d/sudo
auth      [success=2 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_howdy.so
auth      sufficient pam_fprintd.so
#%PAM-1.0
auth      include    system-auth
account   include    system-auth
session   include    system-auth
session   optional   pam_systemd.so class=none
```

**`success=1` must become `success=2`.** That line means "when the lid is closed, return success and
skip the next N modules, falling straight to password". There are now two biometric modules above
it, so N is 2. Get it wrong and a closed lid skips only one, landing on the fingerprint line —
which reads as "closing the lid brought the fingerprint back".

**Know what face-first costs:** the camera opens on every invocation and a scan may run for the
full `timeout` (20 s). Sitting in front of the screen that is 1.3–2 s and fine; but if you step away
right after `sudo -k`, it will spend the full 20 s before falling through to the fingerprint reader.

If you would rather have "fingerprint first, face as backup", swap the two lines and put `success`
back to 1 — both are legitimate. This machine chose face-first because almost every `sudo` happens
in front of the screen.

> The stock file has `#%PAM-1.0` on line 3 because something prepended to it. Leave it — PAM does
> not require it to be the first line.

### 7.2 Lock screen

A dedicated service, sitting alongside `omarchy-lock-fingerprint`:

```bash
# /etc/pam.d/omarchy-lock-face
#%PAM-1.0
auth       sufficient                  pam_howdy.so
account    include                     system-local-login
```

### 7.3 SDDM login

```bash
# /etc/pam.d/sddm
auth        sufficient  pam_howdy.so
auth        include     system-login
```

### 7.4 polkit — this is where 1Password lives

The second counter-intuitive finding in this write-up: **1Password's "unlock with system
authentication" does not use its own PAM, it uses polkit.** The evidence is in 1Password's own log:

```
$ journalctl -b | grep -A2 "1password"
1password[1281]: [1P:app/op-app/src/app/backend/auth_prompt.rs:147] invoked system auth unlock in locked state
polkit-agent-helper-1[1042829]: pam_exec(polkit-1:auth): /usr/bin/omarchy-hw-laptop-closed failed: exit code 1
1password[1281]: [1P:iam/op-iam-observability/src/lib.rs:151] event=system_auth outcome=success
```

`polkit-agent-helper-1` is running `/etc/pam.d/polkit-1`. So "make 1Password prefer my face" means
editing `/etc/pam.d/polkit-1`. Rummaging through 1Password's settings will never do it.

```
# /etc/pam.d/polkit-1
auth      [success=2 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_howdy.so
auth      sufficient pam_fprintd.so
auth      include system-auth
```

**`success=1` must become `success=2`.** That line means "if the lid is closed, return success and
skip the next N modules, falling straight through to password". Originally it skipped only
`pam_fprintd`; now that `pam_howdy` was inserted in front, N must increment with it.
**Get this wrong and you get a bizarre result: face works with the lid open, but as soon as you
close the lid it goes back to waiting for a fingerprint.**

> **Side effect:** `polkit-1` is global. After this change *every* desktop authorisation — mounting
> a disk, changing system settings, escalating to install a package — opens the camera first.
> Checked seven days of logs: this machine has 18 polkit authentications in total, essentially all
> from 1Password, so the nuisance cost is low. If it ever bothers you, delete the `pam_howdy.so`
> line.

**Verify the whole dialog path** (`pkexec` uses the same `polkit-1` service name):

```bash
time pkexec true
# a polkit dialog should appear → camera LED on → passes in ~1.5 s
```

---

## 8. Omarchy lock screen: a parallel face channel in the Quickshell plugin

The lock screen here is not `hyprlock`; it is Omarchy's own Quickshell plugin at
`~/.config/omarchy/plugins/murgo.lock/`. Originally it handled only password and fingerprint.

**Key design decision: face must be a separate `PamContext`, not shared with the fingerprint one.**

Because a face scan takes 1–20 s (`timeout`), while a fingerprint is "press once, result in a
second". Sharing one PAM context means a press during a face scan is blocked — the fingerprint path
would be dead.

### What was added

`Service.qml`:

```qml
// 1. Properties (QML property names may not start with a capital — see the trap below)
property bool faceAuthenticating: false
property bool faceConfigured: false
property int faceFailStreak: 0
property bool facePaused: false

readonly property int faceRetryMs: 1500       // gap between scans
readonly property int faceBackoffMs: 8000     // back-off after repeated misses
readonly property int faceUnavailableStreak: 4

// 2. A dedicated PAM context
PamContext {
  id: facePam
  config: "omarchy-lock-face"
  user: root.userName
  onCompleted: function(result) { root.handleFaceFinished(result) }
  onError: function(error) { root.settleFaceAttempt() }
}

// 3. Serialised retry — only one scan at a time
Timer {
  id: faceRetryTimer
  interval: root.faceRetryMs
  repeat: false
  onTriggered: root.startFace()
}
```

### Hooking into the lock lifecycle

| Hook | Action | Why |
|---|---|---|
| `onSecureStateChanged` (secure=true) | `startFace()` | only open the camera once the lock is really up |
| `runWake()` | `resumeFace()` | any input resumes scanning |
| `runBlank()` | `pauseFace()` | the screen is off; do not hold the camera |
| `submitPassword()` | `facePam.abort()` | the user is typing — stop competing |
| `handlePasswordFailure()` | restart `faceRetryTimer` | bad password, give face another round |

**In `submitPassword()`, `abort()` must come after `runWake()`**:

```qml
function submitPassword(value) {
  ...
  runWake()                    // this calls resumeFace(), which starts the timer
  if (facePam.active) facePam.abort()   // so the abort has to come after it
  faceAuthenticating = false
  faceRetryTimer.stop()
  ...
}
```

Reverse the order and `runWake()` restarts the timer you just stopped — the `abort()` is wasted.

### Availability probe

Do not just check that the file exists; confirm howdy actually has a model, or the indicator lies:

```qml
Process {
  id: faceStatusCheckProc
  command: ["bash", "-c",
    "if [[ -f /etc/pam.d/omarchy-lock-face ]] && command -v howdy >/dev/null 2>&1; then " +
    "howdy list 2>/dev/null | grep -q . ; else exit 1; fi"]
  onExited: function(exitCode) { root.applyFaceProbe(exitCode) }
}
```

The lock UI gets a status icon on the **left** of the password field (fingerprint is on the right,
so the field stays symmetric): scanning `󰈈`, idle `󰈉`, camera unusable `󰚃` in red.

### Measured result

```
omarchy lock 2026-11-12T14:49:11.022Z lock-requested
omarchy lock 2026-11-12T14:49:11.185Z face-configured
omarchy lock 2026-11-12T14:49:11.631Z face-scan-start
omarchy lock 2026-11-12T14:49:13.169Z face-matched
omarchy lock 2026-11-12T14:49:13.170Z unlocked
```

Lock to unlock in **1.5–2.1 s**, on two independent runs.

---

## 9. Trap: QML property names cannot start with a capital, and `qmllint` stays silent

My first version followed C convention:

```qml
readonly property int FACE_RETRY_MS: 1500
```

`qmllint` was **completely silent** — exit code 0, only harmless `var in block scope` warnings.
But Quickshell refused to load the plugin:

```
WARN qml: service plugin load failed for murgo.lock:
  Service.qml:85:25: Property names cannot begin with an upper case letter
```

**The entire lock screen disappeared** — not just face unlock, the whole plugin. And this error
exists only in `journalctl`; the UI shows nothing at all.

Renaming to `faceRetryMs` / `faceBackoffMs` / `faceUnavailableStreak` fixed it.

> **Lesson:** after editing a Quickshell plugin and running `omarchy-restart-shell`, you **must**
> grep `journalctl --user | grep "plugin load failed"`. `qmllint` passing does not mean it loads.

Also: QML changes require `omarchy-restart-shell`. Saving the file is not enough — the log shows
`Local plugin changed, reloading`, but hot-reloading a plugin that failed to load is not reliable.

---

## 10. Troubleshooting matrix

| Symptom | Root cause | Fix |
|---|---|---|
| `Face verification timed out`, no output | **Killed by `SIGXCPU`** (exit 152) | `sudo howdy set timeout 20` |
| Frame is a white blob | IR illuminator overexposure at close range | back off to 40–60 cm, or tune `exposure` |
| Frame is all black | illuminator not lit / not settled | wait 1–2 s; re-check with `howdy snapshot` |
| `Configured camera device does not exist` | `/dev/videoN` numbering changed | install the pin service (`--pin`); do not use by-id |
| Scores hovering at 0.60 | only one enrolled model | enrol 3–4 more |
| `howdy test` hangs silently | it is an interactive preview window | use `howdy-compare` + `end_report` |
| `pamtester` says success but shows nothing | missing `-v` | add `-v` |
| 1Password still asks for a finger | wrong service — it uses `polkit-1` | edit `/etc/pam.d/polkit-1` |
| **Face unlock dies after a reboot**, `cannot open configured camera` | the `indexN` in the by-id name re-points at the colour node | run `--pin` to install the pin service; don't use by-id |
| Face "works" but a photo passes too | same cause — silently running on the colour camera | check that `device_path` really is the IR node |
| Lid closed now waits for a fingerprint | lid line's `success=N` does not match the module count | set N to the number of modules you inserted |
| The whole lock screen vanished | QML capital-case property / load failure | `journalctl --user \| grep "plugin load failed"` |

### Verify the degraded path (important)

After touching PAM you must confirm that a broken face pipeline cannot lock you out:

```bash
# camera gone
sudo howdy set device_path /dev/video99
pamtester -v omarchy-lock-face murgo authenticate </dev/null
# → Configured camera device does not exist: /dev/video99
# → pamtester: Permission denied           ← returns immediately, no blocking

# howdy disabled
sudo howdy set disabled true
pamtester -v omarchy-lock-face murgo authenticate </dev/null
# → pamtester: Permission denied           ← returns immediately
```

**In both cases it fails immediately rather than hanging until timeout.** The lock screen password
field, the SDDM password field, and the `sudo` prompt all stay usable.

---

## 11. Maintenance checklist

```bash
# 1. which node is IR, and is howdy pointing at it (the first suspect after a reboot)
for d in /sys/class/video4linux/video*; do
  [[ $(cat $d/name) == *"IR Camera"* && $(cat $d/index) == 0 ]] && echo "IR capture: /dev/$(basename $d)"
done
sudo sed -n 's/^device_path = //p' /etc/howdy/config.ini
systemctl is-enabled u9311-ir-camera-pin.service

# 2. can howdy still run (the single most reliable check — read the exit code)
sudo /usr/lib/howdy/howdy-compare murgo; echo "exit=$?"

# 3. are the models still there
sudo howdy list

# 4. are all four PAM entry points wired
grep -l pam_howdy /etc/pam.d/{sudo,polkit-1,sddm,omarchy-lock-face}

# 5. did the lock plugin load
journalctl --user --since "5 min ago" | grep -i "plugin load failed"
```

### What to redo after upgrades

| Event | Action |
|---|---|
| `howdy-next` upgrade | normally nothing; `/etc/howdy/config.ini` is preserved |
| **Kernel upgrade** | nothing — howdy is userspace, unlike the ACPI fix |
| `omarchy` upgrade | check whether `~/.config/omarchy/plugins/murgo.lock/` was overwritten |
| Reinstall | re-run this whole flow; re-verify `device_path` |

> The fingerprint write-up has a "kernel upgrade requires rebuilding the UKI" trap.
> **Face unlock has no such requirement** — howdy is entirely userspace; it touches neither the
> initramfs nor ACPI.

---

## 12. Rollback

| Scope | How |
|---|---|
| polkit only (1Password) | delete the `pam_howdy.so` line from `/etc/pam.d/polkit-1` |
| sudo only | same, in `/etc/pam.d/sudo` |
| Lock screen | remove the howdy line, or the whole `/etc/pam.d/omarchy-lock-face` |
| Everything | restore the backups: `/etc/pam.d/{sudo,polkit-1,sddm}.bak.*` |
| Full removal | `sudo pacman -Rns howdy-next` + restore PAM backups |

Backups on this machine:

```
/etc/pam.d/sudo.bak.20261118223550     # before switching to face-first
/etc/pam.d/sddm.bak.202611122247xx
/etc/pam.d/polkit-1.bak.20261113004837
~/.config/omarchy/plugins/murgo.lock/Service.qml.bak.20261112224622
```

---

## 13. Security notes

- **IR is not magic.** It defeats photographs and screens, but not a well-made 3D mask or a
  purpose-built IR-emitting prop. Genuine anti-spoofing needs structured light or ToF, which is
  essentially nonexistent in consumer laptops.
- **Always keep the password.** Every PAM config here is `sufficient` — this adds a path, it does
  not replace one.
- `abort_if_ssh` is a convenience, not a boundary: it reads `SSH_CONNECTION` and friends, which the
  caller can unset. **Do not treat it as security.**
- `/etc/howdy/config.ini` and the model directory must stay root-owned and not user-writable.
  The lock screen goes through the root-owned `polkit-agent-helper` here, so no permission
  relaxation was needed.

---

## References

- Howdy Next (the implementation used here): <https://github.com/nathawatc/howdy-next>
- Original Howdy: <https://github.com/boltgolt/howdy>
- OpenCV Zoo — YuNet / SFace models: <https://github.com/opencv/opencv_zoo>
- ArchWiki — Howdy: <https://wiki.archlinux.org/title/Howdy>
- Linux — `SIGXCPU` / `RLIMIT_CPU`: `man 2 setrlimit`, `man 7 signal`
- Quickshell `PamContext`: <https://quickshell.org/docs/v0.2.0/types/Quickshell.Services.Pam/PamContext/>
