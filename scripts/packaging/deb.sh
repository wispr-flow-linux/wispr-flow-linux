#!/usr/bin/env bash
#===============================================================================
# deb.sh -- package the validated Wispr Flow Linux tree as a .deb
#
# Mirrors rpm.sh's FHS layout for Debian/Ubuntu: builds a DEBIAN/control +
# postinst pkgroot and runs dpkg-deb. Produces:
#   /usr/lib/wispr-flow/            Electron app tree (launcher renamed
#                                   'wispr-flow'), plus launcher-common.sh +
#                                   doctor.sh
#   /usr/bin/wispr-flow             full launcher (sources launcher-common.sh,
#                                   handles --doctor, builds Electron args)
#   /usr/share/applications/wispr-flow.desktop
#   /usr/share/icons/hicolor/{256x256,scalable}/apps/wispr-flow.{png,svg}
#   /usr/lib/udev/rules.d/70-wispr-flow-uinput.rules  (installed by postinst)
#
# postinst: sets chrome-sandbox setuid-root (4755), installs the uinput udev
# rule + reloads udev, refreshes the desktop DB, and prints the GNOME relogin note.
#
# Runtime deps: Depends: wl-clipboard ; Recommends: xclip, xsel.
#
# Shared maker signature:
#   deb.sh <dist_dir> <version> <arch>
#     <dist_dir>  staged electron-dist tree (default: build-linux/downloads/electron-dist)
#     <version>   package version (default: $APP_VERSION env or 1.5.695)
#     <arch>      deb-native arch: amd64 | arm64 (default: derived from host)
# PACKAGE_NAME / WM_CLASS / MAINTAINER / DESCRIPTION come from the environment
# (exported by build.sh); sane defaults apply when run standalone.
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

#--- shared maker signature ----------------------------------------------------
DIST="${1:-$PROJECT_ROOT/build-linux/downloads/electron-dist}"
APP_VERSION="${2:-${APP_VERSION:-1.5.695}}"
# Default deb arch from the host: dpkg knows the canonical name when present.
_default_arch="amd64"
if command -v dpkg >/dev/null 2>&1; then
  _default_arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
else
  case "$(uname -m)" in
    aarch64|arm64) _default_arch="arm64" ;;
    *)             _default_arch="amd64" ;;
  esac
fi
ARCH="${3:-$_default_arch}"

#--- metadata from env, with standalone fallbacks ------------------------------
NAME="${PACKAGE_NAME:-wispr-flow}"
WM_CLASS="${WM_CLASS:-Wispr Flow}"
MAINTAINER="${MAINTAINER:-Wispr Flow Linux (unofficial)}"
DESCRIPTION="${DESCRIPTION:-Wispr Flow voice dictation for Linux (unofficial build)}"

WORK="$PROJECT_ROOT/build-linux/deb"
PKGROOT="$WORK/pkgroot"           # FHS staging tree (becomes the .deb)

say(){ printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$DIST/wispr-flow" ]] || die "renamed launcher not found at $DIST/wispr-flow (run the assembly + rename electron->wispr-flow first)"
[[ -f "$DIST/resources/app.asar" ]] || die "resources/app.asar not found under $DIST"
[[ -x "$DIST/resources/Release/wispr-flow-linux-helper" ]] || die "Linux helper not staged at resources/Release/wispr-flow-linux-helper"
[[ -f "$SCRIPTS_DIR/launcher-common.sh" ]] || die "launcher-common.sh not found at $SCRIPTS_DIR"
[[ -f "$SCRIPTS_DIR/doctor.sh" ]] || die "doctor.sh not found at $SCRIPTS_DIR"

say "Staging FHS tree at $PKGROOT"
rm -rf "$WORK"; mkdir -p "$PKGROOT/DEBIAN"

APPDIR="$PKGROOT/usr/lib/$NAME"
mkdir -p "$APPDIR"
# Copy the whole dist EXCEPT the duplicate 'electron' binary, the default app,
# and any downloads. electron-dist is READ-ONLY: we only copy FROM it.
rsync -a \
  --exclude 'electron' \
  --exclude 'resources/default_app.asar' \
  --exclude 'downloads' \
  "$DIST/"/ "$APPDIR/" 2>/dev/null || cp -a "$DIST/." "$APPDIR/"
rm -f "$APPDIR/resources/default_app.asar" "$APPDIR/electron" 2>/dev/null || true
rm -f "$APPDIR/resources/Release/Wispr Flow Helper.exe" 2>/dev/null || true
# Normalize directory modes. The staged dist carries restrictive dirs (asar
# extraction leaves resources/ subtrees 0700) and rsync -a preserves them, so
# a non-root user can't traverse into resources/ to reach app.asar or the
# helper -- Electron then fails to launch. Files keep their copied modes; only
# directories are forced world-traversable.
find "$APPDIR" -type d -exec chmod 0755 {} +
chmod 0755 "$APPDIR/$NAME" "$APPDIR/resources/Release/wispr-flow-linux-helper"

say "Shared launcher library + doctor"
cp "$SCRIPTS_DIR/launcher-common.sh" "$APPDIR/launcher-common.sh"
cp "$SCRIPTS_DIR/doctor.sh" "$APPDIR/doctor.sh"
chmod 0644 "$APPDIR/launcher-common.sh" "$APPDIR/doctor.sh"

say "Launcher /usr/bin/$NAME"
mkdir -p "$PKGROOT/usr/bin"
cat > "$PKGROOT/usr/bin/$NAME" <<EOF
#!/usr/bin/env bash
# Wispr Flow launcher (deb). Sources the shared launcher library, runs the
# doctor on --doctor, sets up logging + Electron env, then exec's the renamed
# Electron binary. chrome-sandbox is installed setuid-root so no --no-sandbox.

set -uo pipefail

app_dir="/usr/lib/$NAME"
electron_bin="\$app_dir/$NAME"
helper_bin="\$app_dir/resources/Release/wispr-flow-linux-helper"

# Source shared launcher library (it sources doctor.sh from the same dir).
# shellcheck source=/dev/null
source "\$app_dir/launcher-common.sh"

# Handle --doctor before anything else.
if [[ "\${1:-}" == '--doctor' ]]; then
	run_doctor "\$helper_bin" "\$electron_bin"
	exit \$?
fi

# Install the input-access udev rule (already installed by the deb postinst;
# offered here too for parity and re-running after a manual rule removal).
if [[ "\${1:-}" == '--install-udev-rules' ]]; then
	install_udev_rules
	exit \$?
fi

setup_logging || exit 1
setup_electron_env
cleanup_stale_lock

log_message '--- Wispr Flow Launcher Start (deb) ---'
log_message "Timestamp: \$(date)"
log_message "Arguments: \$*"
log_session_env

# Require a graphical session; refuse to launch from a bare TTY.
if ! check_display; then
	log_message 'No display detected (TTY session)'
	echo 'Error: Wispr Flow requires a graphical desktop environment.' >&2
	echo 'Run from within a Wayland or X11 session, not a TTY.' >&2
	echo 'Tip: run "wispr-flow --doctor" to diagnose your setup.' >&2
	exit 1
fi

detect_display_backend
build_electron_args 'deb'

log_message "Executing: \$electron_bin \${electron_args[*]} \$*"
cd "\$app_dir" || { log_message "Failed to cd to \$app_dir"; exit 1; }
exec "\$electron_bin" "\${electron_args[@]}" "\$@" >> "\$log_file" 2>&1
EOF
chmod 0755 "$PKGROOT/usr/bin/$NAME"

say "Desktop entry + icons"
mkdir -p "$PKGROOT/usr/share/applications"
cat > "$PKGROOT/usr/share/applications/$NAME.desktop" <<EOF
[Desktop Entry]
Name=Wispr Flow
Comment=Voice dictation that types into your focused app
GenericName=Voice Dictation
Exec=$NAME %U
Icon=$NAME
Terminal=false
Type=Application
Categories=Utility;AudioVideo;Audio;
StartupWMClass=$WM_CLASS
Keywords=voice;dictation;speech;transcription;
EOF

ICON_PNG="$DIST/resources/assets/logos/wispr-logo.png"     # 256x256 RGBA
ICON_SVG="$DIST/resources/assets/logos/wispr-flow.svg"
if [[ -f "$ICON_PNG" ]]; then
  mkdir -p "$PKGROOT/usr/share/icons/hicolor/256x256/apps"
  cp "$ICON_PNG" "$PKGROOT/usr/share/icons/hicolor/256x256/apps/$NAME.png"
fi
if [[ -f "$ICON_SVG" ]]; then
  mkdir -p "$PKGROOT/usr/share/icons/hicolor/scalable/apps"
  cp "$ICON_SVG" "$PKGROOT/usr/share/icons/hicolor/scalable/apps/$NAME.svg"
fi

say "input access udev rule (staged for the postinst to install)"
# The udev rule ships under the package but is *installed* into
# /usr/lib/udev/rules.d by postinst so we can reload udev in the same step.
# Canonical rule text — keep in sync with rpm.sh, nix/wispr-flow.nix, and the
# launcher's _wispr_udev_rules_content (scripts/launcher-common.sh).
mkdir -p "$APPDIR"
cat > "$APPDIR/70-$NAME-uinput.rules" <<'EOF'
# Wispr Flow: grant the active-session user the input access the helper needs.
#  - write /dev/uinput        — keystroke injection (PasteText/SimulateKeyPress)
#  - read  /dev/input/event*  — global key monitor for push-to-talk and the
#                               in-app shortcut recorder
# TAG+="uaccess" scopes the grant to the active logind session; the input group
# + 0660 is the cross-distro fallback (then `usermod -aG input $USER` + re-login).
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
SUBSYSTEM=="input", KERNEL=="event*", TAG+="uaccess", GROUP="input", MODE="0660"
EOF

say "DEBIAN/control"
# Compute Installed-Size (KiB) so apt reports it correctly.
installed_size="$(du -sk "$PKGROOT/usr" | cut -f1)"
cat > "$PKGROOT/DEBIAN/control" <<EOF
Package: $NAME
Version: $APP_VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $installed_size
Depends: wl-clipboard
Recommends: xclip, xsel
Description: $DESCRIPTION
 Unofficial repackaging of the Wispr Flow voice-dictation app for Linux, with
 a clean-room Rust helper providing text injection, active-app detection, and
 selection capture across KDE/GNOME/wlroots/X11.
EOF

say "DEBIAN/postinst"
cat > "$PKGROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e

NAME="$NAME"
APPDIR="/usr/lib/\$NAME"

# chrome-sandbox must be setuid-root for the Electron sandbox to work.
SANDBOX="\$APPDIR/chrome-sandbox"
if [ -f "\$SANDBOX" ]; then
  chown root:root "\$SANDBOX" || echo "Warning: failed to chown chrome-sandbox" >&2
  chmod 4755 "\$SANDBOX" || echo "Warning: failed to chmod chrome-sandbox" >&2
fi

# Install the uinput udev rule and reload so it applies without a reboot.
RULE_SRC="\$APPDIR/70-\$NAME-uinput.rules"
RULE_DST="/usr/lib/udev/rules.d/70-\$NAME-uinput.rules"
if [ -f "\$RULE_SRC" ]; then
  mkdir -p /usr/lib/udev/rules.d
  install -m 0644 "\$RULE_SRC" "\$RULE_DST"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=misc --sysname-match=uinput 2>/dev/null || true
    udevadm trigger --subsystem-match=input 2>/dev/null || true
  fi
fi

update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

cat <<'MSG'
Wispr Flow installed.
 - Keystroke injection (/dev/uinput) and push-to-talk (/dev/input read) both
   need input access; the bundled udev rule grants it to the active-session
   user. If paste or push-to-talk does not work, ensure your user is in the
   'input' group (usermod -aG input \$USER) and re-login.
 - GNOME users: the helper installs a Shell extension for window detection on
   first run; log out and back in once to enable it.
 - Run "wispr-flow --doctor" to diagnose display, input access, and clipboard.
MSG

exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postinst"

say "DEBIAN/postrm"
cat > "$PKGROOT/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = "remove" ] || [ "\$1" = "purge" ]; then
  rm -f "/usr/lib/udev/rules.d/70-$NAME-uinput.rules"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || true
  fi
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "$PKGROOT/DEBIAN/postrm"

chmod 0755 "$PKGROOT/DEBIAN"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  warn=$'\033[1;33mWARNING:\033[0m'
  printf '%b dpkg-deb not found; FHS tree staged at %s but no .deb built.\n' "$warn" "$PKGROOT" >&2
  printf '  Install dpkg (Debian/Ubuntu) or the "dpkg" package to build the .deb.\n' >&2
  exit 0
fi

say "Building .deb"
DEB_OUT="$WORK/${NAME}_${APP_VERSION}_${ARCH}.deb"
# Root-owned files inside the package: use --root-owner-group when supported so
# /usr files are owned by root:root without needing fakeroot.
if dpkg-deb --help 2>&1 | grep -q -- '--root-owner-group'; then
  dpkg-deb --root-owner-group --build "$PKGROOT" "$DEB_OUT"
else
  dpkg-deb --build "$PKGROOT" "$DEB_OUT"
fi

say "Done"
echo "  DEB: $DEB_OUT"
echo "  Size: $(du -h "$DEB_OUT" | cut -f1)"
echo
echo "  Install:  sudo apt install '$DEB_OUT'"
echo "  Run:      wispr-flow"
