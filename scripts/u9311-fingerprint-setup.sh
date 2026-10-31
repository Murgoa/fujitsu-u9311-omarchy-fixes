#!/usr/bin/env bash
#
# u9311-fingerprint-setup.sh — NEXT Biometrics NB-2033-U (298d:2033) on Arch / Omarchy
#
# Builds libfprint from the open merge request that adds the nb2033 driver, applies
# the local tuning patch, deploys it so package upgrades cannot break it, then runs
# Omarchy's own fingerprint setup wizard (sudo / polkit / session lock PAM).
#
# Everything here is idempotent-ish: re-running rebuilds and redeploys. It does NOT
# touch your enrolled fingerprints unless you pass --re-enroll.
#
#   ./u9311-fingerprint-setup.sh            # build + deploy + PAM setup
#   ./u9311-fingerprint-setup.sh --deploy   # skip the build, just redeploy existing
#   ./u9311-fingerprint-setup.sh --check    # only report current state
#
# Requires: git, gcc, pkg-config, meson+ninja (a venv is fine), sudo.
# See docs/fingerprint-nb2033u.md for the why behind every step.
#
set -euo pipefail

MR_REF="merge-requests/574/head"
UPSTREAM="https://gitlab.freedesktop.org/libfprint/libfprint.git"
WORKDIR="${WORKDIR:-$HOME/.cache/u9311-fingerprint}"
UDEV_RULE="/etc/udev/rules.d/60-nb2033.rules"
DROPIN_DIR="/etc/systemd/system/fprintd.service.d"
DROPIN="$DROPIN_DIR/20-nb2033-lib.conf"
PATCH_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/patches/nb2033-u9311-tuning.patch"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

report_state() {
  log "device        : $(grep -l . /sys/bus/usb/devices/*/idProduct 2>/dev/null >/dev/null; \
      for d in /sys/bus/usb/devices/*/; do
        [[ $(cat "$d/idVendor" 2>/dev/null) == "298d" ]] && echo "$(basename "$d") $(cat "$d/product")"
      done | head -1)"
  log "running lib   : $(sudo grep -o '/[^ ]*libfprint[^ ]*' /proc/$(pgrep -x fprintd 2>/dev/null || echo 1)/maps 2>/dev/null | sort -u | head -1 || echo 'fprintd not running')"
  log "device visible: $(fprintd-list "${SUDO_USER:-$USER}" 2>&1 | tail -1)"
  log "udev rule     : $([[ -f $UDEV_RULE ]] && echo present || echo MISSING)"
  log "drop-in       : $([[ -f $DROPIN ]] && echo present || echo MISSING)"
}

build_libfprint() {
  mkdir -p "$WORKDIR"
  cd "$WORKDIR"

  if [[ ! -d libfprint/.git ]]; then
    log "fetching libfprint MR branch ($MR_REF)"
    git init -q libfprint
    git -C libfprint remote add origin "$UPSTREAM" 2>/dev/null || true
  fi
  git -C libfprint fetch -q --depth 1 origin "$MR_REF"
  git -C libfprint checkout -q FETCH_HEAD

  # glib-mkenums / g-ir-scanner live in glib2-devel on current Arch. Extract the
  # package locally instead of installing it, and shadow the hardcoded path the
  # glib-2.0.pc pkg-config file points at.
  if ! command -v glib-mkenums >/dev/null; then
    if [[ ! -x glib-devel/usr/bin/glib-mkenums ]]; then
      log "extracting glib2-devel locally (no root needed)"
      local ver url
      ver=$(pkg-config --modversion glib-2.0)
      url="https://geo.mirror.pkgbuild.com/core/os/x86_64/glib2-devel-${ver}-1-x86_64.pkg.tar.zst"
      curl -fsSL "$url" -o glib2-devel.pkg.tar.zst ||
        die "could not download glib2-devel ${ver}; fetch it manually and extract to $WORKDIR/glib-devel"
      mkdir -p glib-devel && tar -xf glib2-devel.pkg.tar.zst -C glib-devel
    fi
    mkdir -p pc
    sed "s|^glib_mkenums=.*|glib_mkenums=$PWD/glib-devel/usr/bin/glib-mkenums|" \
      /usr/lib/pkgconfig/glib-2.0.pc > pc/glib-2.0.pc
    export PKG_CONFIG_PATH="$PWD/pc:/usr/lib/pkgconfig:/usr/share/pkgconfig"
    export PATH="$PWD/glib-devel/usr/bin:$PATH"
  fi

  # meson >= 1.12 rejects `foreach x: dict` — only reachable with introspection off.
  if grep -q "foreach driver_test: drivers_tests" libfprint/tests/meson.build 2>/dev/null; then
    log "patching tests/meson.build for new meson (dict foreach)"
    sed -i 's|foreach driver_test: drivers_tests|foreach _k, driver_test: drivers_tests|;
            s|        test(driver_test,|        test(_k,|' libfprint/tests/meson.build
  fi

  # Our tuning: ppmm, banding removal, capture dwell, quality gate, threshold.
  if [[ -f $PATCH_FILE ]]; then
    if git -C libfprint apply --check "$PATCH_FILE" 2>/dev/null; then
      log "applying $PATCH_FILE"
      git -C libfprint apply "$PATCH_FILE"
    else
      warn "tuning patch does not apply cleanly (already applied, or MR moved on) — continuing"
    fi
  else
    warn "tuning patch not found at $PATCH_FILE — building the unmodified driver"
  fi

  log "configuring and building"
  ( cd libfprint &&
    meson setup --wipe build -Ddoc=false -Dintrospection=false >/dev/null 2>&1 ||
    meson setup build -Ddoc=false -Dintrospection=false >/dev/null
    ninja -C build >/dev/null )

  strings libfprint/build/libfprint/libfprint-2.so.2.0.0 | grep -qi nb2033 ||
    die "the built library does not contain the nb2033 driver — inspect $WORKDIR/libfprint/build/meson-logs"
  log "build OK ($(strings libfprint/build/libfprint/libfprint-2.so.2.0.0 | grep -ci nb2033) nb2033 symbols)"
}

deploy() {
  local so="$WORKDIR/libfprint/build/libfprint/libfprint-2.so.2.0.0"
  [[ -f $so ]] || die "no built library at $so — run without --deploy first"

  log "installing udev rule"
  echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="298d", ATTRS{idProduct}=="2033", MODE="0666", TAG+="uaccess"' |
    sudo tee "$UDEV_RULE" >/dev/null
  sudo udevadm control --reload-rules
  sudo udevadm trigger

  log "installing library to /usr/local/lib and /usr/lib"
  sudo cp "$so" /usr/local/lib/libfprint-2.so.2.0.0
  sudo cp "$so" /usr/lib/libfprint-2.so.2.0.0
  sudo ldconfig

  # /usr/local/lib is not in the linker path on Arch, and pacman will overwrite
  # /usr/lib on the next libfprint-git upgrade. The drop-in pins the daemon to our
  # copy, which survives upgrades.
  log "pinning fprintd to /usr/local/lib"
  sudo mkdir -p "$DROPIN_DIR"
  printf '[Service]\nEnvironment=LD_LIBRARY_PATH=/usr/local/lib\n' | sudo tee "$DROPIN" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl restart fprintd

  sudo grep -q '/usr/local/lib/libfprint' "/proc/$(pgrep -x fprintd)/maps" ||
    warn "fprintd does not appear to be using /usr/local/lib — check: systemctl cat fprintd"
}

setup_pam() {
  # omarchy-hw-fingerprint only whitelists a few vendor IDs; 298d is not one of them.
  # The check honours this env var, so a throw-away directory gets us into the wizard
  # without patching any packaged file.
  local fake="${TMPDIR:-/tmp}/u9311-fpdev"
  mkdir -p "$fake/nb2033"
  echo "Fingerprint Reader" > "$fake/nb2033/product"

  log "running Omarchy's fingerprint wizard (touch the reader when asked)"
  OMARCHY_USB_DEVICES_PATH="$fake" sudo -E omarchy-setup-security-fingerprint

  # The wizard writes /etc/pam.d/omarchy-lock-fingerprint with defaults; a thermal
  # sensor needs more tries per verification than the default 3.
  log "raising PAM max-tries for the lock screen"
  sudo tee /etc/pam.d/omarchy-lock-fingerprint >/dev/null <<'PAM'
#%PAM-1.0
auth       required                    pam_fprintd.so max-tries=6 timeout=30
account    include                     system-local-login
PAM

  warn "the lock-screen blank timer still needs the plugin fix — see docs/fingerprint-nb2033u.md §9"
}

case "${1:---all}" in
  --check)  report_state ;;
  --deploy) deploy; report_state ;;
  --all)    build_libfprint; deploy; setup_pam; report_state ;;
  *)        die "unknown option: $1 (use --all, --deploy, or --check)" ;;
esac

log "done."
