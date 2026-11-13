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
#   ./u9311-face-unlock-setup.sh --pam-only  # skip install/config, just redo PAM
#   ./u9311-face-unlock-setup.sh --enroll    # also run `howdy add` (interactive)
#
# Requires: sudo, yay (AUR). See docs/face-unlock-howdy.md for the why.
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
find_ir_node() {
  local d card
  for d in /dev/video*; do
    [[ -e $d ]] || continue
    card=$(v4l2-ctl -d "$d" --info 2>/dev/null | sed -n 's/.*Card type *: *//p' || true)
    [[ $card == *"IR Camera"* ]] && { echo "$d"; return 0; }
  done
  return 1
}

# /dev/videoN moves between boots; by-id does not.
stable_path_for() {
  local target
  target=$(readlink -f "$1")
  local link
  for link in /dev/v4l/by-id/*; do
    [[ -e $link ]] || continue
    [[ $(readlink -f "$link") == "$target" ]] && { echo "$link"; return 0; }
  done
  return 1
}

report_state() {
  local ir stable
  prime_sudo
  ir=$(find_ir_node || true)
  if [[ -n $ir ]]; then
    stable=$(stable_path_for "$ir" || echo "(no by-id link)")
    log "IR camera     : $ir  →  $stable"
  else
    warn "IR camera     : NOT FOUND — this machine may really have colour only"
  fi

  log "howdy installed: $(command -v howdy >/dev/null 2>&1 && howdy version 2>/dev/null || echo no)"
  log "device_path    : $(sudo grep -o 'device_path = .*' "$HOWDY_CONF" 2>/dev/null | cut -d= -f2- | xargs || echo '(no config)')"
  log "timeout        : $(sudo grep -o '^timeout = .*' "$HOWDY_CONF" 2>/dev/null | cut -d= -f2 | xargs || echo '-')"
  log "models         : $(sudo howdy list 2>/dev/null | grep -c . || echo 0)"

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
  local ir stable
  ir=$(find_ir_node) || die "no IR camera node found — refusing to configure a colour camera"
  stable=$(stable_path_for "$ir" || echo "$ir")
  [[ $stable == /dev/v4l/by-id/* ]] || warn "no by-id link for $ir; writing the unstable path"

  log "configuring device_path = $stable"
  sudo howdy set device_path "$stable"
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
  --pam-only) wire_all_pam; report_state; exit 0 ;;
  --enroll)   install_howdy; configure_howdy; sudo howdy add --plain -y; report_state; exit 0 ;;
  --all|"")   install_howdy; configure_howdy; wire_all_pam; report_state ;;
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
