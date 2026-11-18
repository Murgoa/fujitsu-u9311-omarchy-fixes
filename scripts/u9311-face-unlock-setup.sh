#!/usr/bin/env bash
#
# u9311-face-unlock-setup.sh — IR camera face unlock (Howdy) on Arch / Omarchy
#
# Finds the IR camera node the way `lsusb` will not show you, installs howdy-next,
# writes a working config (including the timeout that decides whether it works at
# all), and wires pam_howdy into sudo / polkit / sddm / the Omarchy lock screen.
#
# PAM is the risky part: every edit is backed up first, every service keeps the
# password as a fallback, and --check never writes anything.
#
#   ./u9311-face-unlock-setup.sh             # detect + install + configure + PAM
#   ./u9311-face-unlock-setup.sh --check     # only report current state
#   ./u9311-face-unlock-setup.sh --pin       # fix after a reboot: re-point + arm the pin service
#   ./u9311-face-unlock-setup.sh --pam-only  # skip install/config, just redo PAM
#   ./u9311-face-unlock-setup.sh --enroll    # also run `howdy add` (interactive)
#
# Requires: sudo, yay (AUR). See docs/face-unlock-howdy.md for the why.
#
# NOTE ON PATHS: do not hard-code any camera path here, not even a by-id one.
# This camera exposes two sensors that both report sysfs index=0, so
# `...-video-index0` silently re-points at the colour node after a reboot.
# Everything is derived from sysfs name+index and re-pinned by a systemd unit.
#
set -euo pipefail

PAM_HOWDY_SERVICES=(sudo polkit-1 sddm omarchy-lock-face)
FACE_PAM=/etc/pam.d/omarchy-lock-face
HOWDY_CONF=/etc/howdy/config.ini

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# Refresh the sudo timestamp once so the dozen `sudo` probes below do not each
# trigger an authentication prompt of their own.
prime_sudo() {
  if ! sudo -n true 2>/dev/null; then
    log "sudo credentials needed once for the read-only probes below"
    sudo -v || die "sudo required"
  fi
}

# ---------------------------------------------------------------- detection

# The whole point of this script: `lsusb` shows one camera, UVC registers four
# nodes, and only some of them are IR. Ask each node what it is.
#
# Match on sysfs `name` + `index` rather than on a device number. index==0 is the
# capture node; index==1 on the same sensor is metadata.
find_ir_node() {
  local d name idx
  for d in /sys/class/video4linux/video*; do
    [[ -e $d/name ]] || continue
    name=$(cat "$d/name" 2>/dev/null) || continue
    idx=$(cat "$d/index" 2>/dev/null) || continue
    [[ $name == *"IR Camera"* && $idx == 0 ]] && { echo "/dev/$(basename "$d")"; return 0; }
  done
  return 1
}

# BELOW IS THE TRAP THIS REPO ALREADY FELL INTO ONCE:
#
# `/dev/v4l/by-id/...-video-indexN` looks stable and is not. The N in that name
# is the value of sysfs `index`, not the device number — and this camera has TWO
# sensors (colour and IR) that both report index=0. So `...-video-index0` points
# at whichever one udev happened to enumerate first, and after a reboot it moved
# from video2 (IR) to video0 (colour). howdy then failed with "cannot open
# configured camera", and had it opened, face auth would have been running on a
# photo-forgeable colour stream.
#
# The only reliable identification is name+index, which is why the node is
# re-pinned at boot instead of being hard-coded to any path.
describe_node() {
  local d
  for d in /sys/class/video4linux/video*; do
    printf '     %-10s name=%-24s index=%s\n' \
      "$(basename "$d")" "$(cat "$d/name" 2>/dev/null)" "$(cat "$d/index" 2>/dev/null)"
  done
}

report_state() {
  local ir pinned
  prime_sudo
  describe_node
  ir=$(find_ir_node || true)
  if [[ -n $ir ]]; then
    log "IR camera     : $ir  (name+index match)"
  else
    warn "IR camera     : NOT FOUND — this machine may really have colour only"
  fi

  log "howdy installed: $(command -v howdy >/dev/null 2>&1 && howdy version 2>/dev/null || echo no)"
  pinned=$(sudo sed -n 's/^device_path = //p' "$HOWDY_CONF" 2>/dev/null || true)
  log "device_path    : ${pinned:-(no config)}"
  if [[ -n $ir && -n $pinned && $pinned != "$ir" ]]; then
    warn "  ^^ MISMATCH: config points somewhere other than the IR capture node."
    warn "     This is the reboot bug — run install/--pin to fix it."
  fi
  log "timeout        : $(sudo sed -n 's/^timeout = //p' "$HOWDY_CONF" 2>/dev/null || echo '-')"
  log "models         : $(sudo howdy list 2>/dev/null | grep -c . || echo 0)"
  log "pin service    : $(systemctl is-enabled u9311-ir-camera-pin.service 2>/dev/null || echo 'not installed')"

  local svc
  for svc in "${PAM_HOWDY_SERVICES[@]}"; do
    if [[ -f /etc/pam.d/$svc ]] && grep -q pam_howdy "/etc/pam.d/$svc"; then
      log "pam[$svc]    : wired"
    else
      log "pam[$svc]    : not wired"
    fi
  done

  if command -v howdy >/dev/null 2>&1; then
    log "self-test     : running one comparison (look at the camera)"
    local target=${SUDO_USER:-$USER}
    sudo howdy set end_report true >/dev/null 2>&1 || true
    sudo /usr/lib/howdy/howdy-compare "$target" || warn "compare exited $? — see doc §4 (exit 152 = SIGXCPU)"
    sudo howdy set end_report false >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------- install

install_howdy() {
  command -v yay >/dev/null || die "yay not found; install howdy-next from the AUR manually"
  if pacman -Q howdy-next >/dev/null 2>&1; then
    log "howdy-next already installed ($(pacman -Q howdy-next | cut -d' ' -f2))"
  else
    log "installing howdy-next (builds ~10 min)"
    yay --noconfirm -S howdy-next
  fi
  log "downloading YuNet + SFace models"
  sudo howdy download-models
}

configure_howdy() {
  local ir
  ir=$(find_ir_node) || die "no IR camera node found — refusing to configure a colour camera"

  # Write the current /dev/videoN, not a by-id path: see describe_node() for why
  # by-id is a lie on this hardware. install_pin_service() keeps it correct.
  log "configuring device_path = $ir"
  sudo howdy set device_path "$ir"
  sudo howdy set frame_width 640
  sudo howdy set frame_height 360
  sudo howdy set max_height 320
  # THE important one: RLIMIT_CPU on the compare child is timeout+5s, and the
  # default 4 leaves 9s, which IR inference exhausts -> SIGXCPU -> a log line
  # that claims "timed out". See docs §4.
  sudo howdy set timeout 20
  sudo howdy set dark_threshold 85
  sudo howdy set abort_if_lid_closed false
  sudo howdy set yunet_score_threshold 0.6
  sudo howdy set clahe_enabled true
  sudo howdy set end_report false
}

# ---------------------------------------------------------------- pin service
#
# `/dev/videoN` is not stable either, so nothing can be hard-coded. Re-derive the
# IR capture node from sysfs at boot and on every camera re-enumeration, and point
# howdy at whatever number it got this time.
install_pin_service() {
  local pin=/usr/local/bin/u9311-ir-camera-pin
  local unit=/etc/systemd/system/u9311-ir-camera-pin.service
  local rule=/etc/udev/rules.d/70-u9311-ir-camera-pin.rules

  sudo tee "$pin" >/dev/null <<'PINEOF'
#!/usr/bin/env bash
# u9311-ir-camera-pin — point howdy at the current IR capture node.
set -euo pipefail

CONF=/etc/howdy/config.ini
[[ -f $CONF ]] || exit 0
command -v howdy >/dev/null 2>&1 || exit 0

ir=""
for d in /sys/class/video4linux/video*; do
  [[ -e $d/name ]] || continue
  [[ $(cat "$d/name" 2>/dev/null) == *"IR Camera"* ]] || continue
  [[ $(cat "$d/index" 2>/dev/null) == 0 ]] || continue
  ir="/dev/$(basename "$d")"
  break
done

[[ -n $ir ]] || { echo "u9311-ir-camera-pin: no IR capture node" >&2; exit 0; }

cur=$(sed -n 's/^device_path = //p' "$CONF")
[[ $cur == "$ir" ]] && exit 0

howdy set device_path "$ir" >/dev/null
echo "u9311-ir-camera-pin: device_path $cur -> $ir" | systemd-cat -t u9311-ir-camera-pin
PINEOF
  sudo chmod 755 "$pin"

  sudo tee "$unit" >/dev/null <<'UNITEOF'
[Unit]
Description=Pin howdy's camera to the current IR capture node
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/u9311-ir-camera-pin
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF

  sudo tee "$rule" >/dev/null <<'RULEEOF'
ACTION=="add", SUBSYSTEM=="video4linux", ATTR{name}=="*IR Camera*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="u9311-ir-camera-pin.service"
RULEEOF

  sudo systemctl daemon-reload
  sudo systemctl enable --now u9311-ir-camera-pin.service
  sudo udevadm control --reload-rules
  log "pin service installed and enabled"
}

# ---------------------------------------------------------------- PAM

backup_once() {
  local f=$1
  [[ -f $f ]] || return 0
  ls "$f".bak.* >/dev/null 2>&1 || { sudo cp -a "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"; log "backed up $f"; }
}

# Insert `auth sufficient pam_howdy.so` before the first line matching $anchor,
# unless it is already present. Text-only, no PAM stack surgery.
wire_pam() {
  local svc=$1 anchor=$2 file=/etc/pam.d/$1
  [[ -f $file ]] || { warn "$file does not exist, skipping"; return 0; }
  if grep -q pam_howdy "$file"; then
    log "pam[$svc]: already wired"
    return 0
  fi
  backup_once "$file"
  sudo awk -v anchor="$anchor" '
    !done && $0 ~ anchor { print "auth      sufficient pam_howdy.so"; done = 1 }
    { print }
  ' "$file" | sudo tee "$file.new" >/dev/null
  sudo mv "$file.new" "$file"
  log "pam[$svc]: inserted pam_howdy.so before /$anchor/"
}

wire_pam_dedicated() {
  [[ -f $FACE_PAM ]] && { log "pam[omarchy-lock-face]: already present"; return 0; }
  sudo tee "$FACE_PAM" >/dev/null <<'EOF'
#%PAM-1.0
auth       sufficient                  pam_howdy.so
account    include                     system-local-login
EOF
  log "pam[omarchy-lock-face]: created"
}

# polkit is special: its lid line skips N modules with success=N, so inserting a
# module means incrementing N or a closed lid silently goes back to fingerprint.
fix_polkit_success_count() {
  local file=/etc/pam.d/polkit-1
  grep -q 'success=[0-9].*omarchy-hw-laptop-closed' "$file" 2>/dev/null || return 0
  local n
  n=$(grep -c '^\s*\(-\?auth\)\s\+sufficient\s\+pam_howdy\.so\|^\s*\(-\?auth\)\s\+sufficient\s\+pam_fprintd\.so' "$file")
  [[ $n -ge 1 ]] || return 0
  if grep -q "success=$n default=ignore.*omarchy-hw-laptop-closed" "$file"; then
    log "pam[polkit-1]: success=$n already correct"
    return 0
  fi
  backup_once "$file"
  sudo sed -i "s/success=[0-9]\( default=ignore.*omarchy-hw-laptop-closed\)/success=$n\1/" "$file"
  log "pam[polkit-1]: lid skip count set to $n"
}

wire_all_pam() {
  # sudo: face AFTER fingerprint — let the thermal sensor try once first.
  if [[ -f /etc/pam.d/sudo ]] && ! grep -q pam_howdy /etc/pam.d/sudo; then
    backup_once /etc/pam.d/sudo
    if grep -q pam_fprintd /etc/pam.d/sudo; then
      sudo awk '{print} /pam_fprintd\.so/ && !done {print "auth      sufficient pam_howdy.so"; done=1}' \
        /etc/pam.d/sudo | sudo tee /etc/pam.d/sudo.new >/dev/null
      sudo mv /etc/pam.d/sudo.new /etc/pam.d/sudo
      log "pam[sudo]: inserted after pam_fprintd"
    else
      wire_pam sudo '^\s*-?auth\s.*include'
    fi
  fi

  wire_pam polkit-1 '^\s*-?auth\s.*include'
  wire_pam sddm '^\s*-?auth\s.*include'
  wire_pam_dedicated
  fix_polkit_success_count
}

# ---------------------------------------------------------------- main

case "${1:---all}" in
  --check)    report_state; exit 0 ;;
  # The reboot fix: no reinstall, no re-enrol, just re-point and arm the service.
  --pin)      configure_howdy; install_pin_service; report_state; exit 0 ;;
  --pam-only) wire_all_pam; report_state; exit 0 ;;
  --enroll)   install_howdy; configure_howdy; install_pin_service; sudo howdy add --plain -y; report_state; exit 0 ;;
  --all|"")   install_howdy; configure_howdy; install_pin_service; wire_all_pam; report_state ;;
  *)          die "unknown option: $1" ;;
esac

cat <<'EOF'

Next steps:
  1. Enrol 3-5 models (repeat, varying distance 40-60 cm):  sudo howdy add --plain -y
  2. Verify before trusting it:                             sudo howdy test
  3. Restart the shell so the lock plugin picks up its PAM service:
       omarchy-restart-shell
       journalctl --user --since "2 min ago" | grep -i "plugin load failed"
  4. Keep a root shell open while you test sudo/logout for the first time.

Rollback: restore /etc/pam.d/<service>.bak.* files.
EOF
