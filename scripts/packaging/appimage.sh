#!/usr/bin/env bash
#===============================================================================
# appimage.sh -- package the validated Wispr Flow Linux tree as an .AppImage
#
# Builds an AppDir + AppRun and runs appimagetool. The AppImage is a portable,
# self-contained bundle that does NOT install a system udev rule (it cannot --
# there is no install step), so AppRun passes --no-sandbox (FUSE mounts drop
# the chrome-sandbox setuid bit) and the bundled doctor detects missing
# /dev/uinput access and tells the user how to fix it.
#
# AppDir layout:
#   AppRun                                       sources launcher-common.sh
#   ai.wisprflow.WisprFlow.desktop               top-level desktop entry
#   ai.wisprflow.WisprFlow.png / .DirIcon        top-level icon (appimagetool)
#   usr/lib/wispr-flow/                           Electron tree (renamed binary)
#                       launcher-common.sh / doctor.sh
#   usr/share/applications/ , usr/share/icons/    standard copies
#
# Shared maker signature:
#   appimage.sh <dist_dir> <version> <arch>
#     <dist_dir>  staged electron-dist tree (default: build-linux/downloads/electron-dist)
#     <version>   package version (default: $APP_VERSION env or 1.5.695)
#     <arch>      appimage-native arch: x86_64 | aarch64 (default: host uname -m)
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
ARCH="${3:-$(uname -m)}"

#--- metadata from env, with standalone fallbacks ------------------------------
NAME="${PACKAGE_NAME:-wispr-flow}"
WM_CLASS="${WM_CLASS:-Wispr Flow}"

# Reverse-DNS component id (wisprflow.ai -> ai.wisprflow) for the desktop file,
# icon, and AppStream metadata naming.
COMPONENT_ID='ai.wisprflow.WisprFlow'

WORK="$PROJECT_ROOT/build-linux/appimage"
APPDIR="$WORK/${COMPONENT_ID}.AppDir"

say(){ printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
warn(){ printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }

[[ -x "$DIST/wispr-flow" ]] || die "renamed launcher not found at $DIST/wispr-flow (run the assembly + rename electron->wispr-flow first)"
[[ -f "$DIST/resources/app.asar" ]] || die "resources/app.asar not found under $DIST"
[[ -x "$DIST/resources/Release/wispr-flow-linux-helper" ]] || die "Linux helper not staged at resources/Release/wispr-flow-linux-helper"
[[ -f "$SCRIPTS_DIR/launcher-common.sh" ]] || die "launcher-common.sh not found at $SCRIPTS_DIR"
[[ -f "$SCRIPTS_DIR/doctor.sh" ]] || die "doctor.sh not found at $SCRIPTS_DIR"

say "Staging AppDir at $APPDIR"
rm -rf "$WORK"; mkdir -p "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps" \
  "$APPDIR/usr/share/metainfo"

APP_LIBDIR="$APPDIR/usr/lib/$NAME"
mkdir -p "$APP_LIBDIR"
# Copy the dist EXCEPT the duplicate 'electron' binary, the default app, and
# downloads. electron-dist is READ-ONLY: we only copy FROM it.
rsync -a \
  --exclude 'electron' \
  --exclude 'resources/default_app.asar' \
  --exclude 'downloads' \
  "$DIST/"/ "$APP_LIBDIR/" 2>/dev/null || cp -a "$DIST/." "$APP_LIBDIR/"
rm -f "$APP_LIBDIR/resources/default_app.asar" "$APP_LIBDIR/electron" 2>/dev/null || true
rm -f "$APP_LIBDIR/resources/Release/Wispr Flow Helper.exe" 2>/dev/null || true
chmod 0755 "$APP_LIBDIR/$NAME" "$APP_LIBDIR/resources/Release/wispr-flow-linux-helper"

say "Shared launcher library + doctor"
cp "$SCRIPTS_DIR/launcher-common.sh" "$APP_LIBDIR/launcher-common.sh"
cp "$SCRIPTS_DIR/doctor.sh" "$APP_LIBDIR/doctor.sh"
chmod 0644 "$APP_LIBDIR/launcher-common.sh" "$APP_LIBDIR/doctor.sh"

say "AppRun"
cat > "$APPDIR/AppRun" <<EOF
#!/usr/bin/env bash
# Wispr Flow AppRun. Sources the shared launcher library from \$APPDIR, runs the
# doctor on --doctor, and builds Electron args in 'appimage' mode (adds
# --no-sandbox because the FUSE mount drops the chrome-sandbox setuid bit).
#
# An AppImage cannot install a system udev rule for /dev/uinput, so if keystroke
# injection (paste) does not work, run:  <this-AppImage> --doctor
# which detects missing /dev/uinput access and prints the udev-rule / input-group
# remedies.

set -uo pipefail

appdir="\$(dirname "\$(readlink -f "\$0")")"
app_dir="\$appdir/usr/lib/$NAME"
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

# AppImages can't run a root post-install hook, so the input-access udev rule
# (uinput write + /dev/input read) is NOT auto-installed. This one-step command
# installs it via pkexec/sudo so push-to-talk and paste work without manual setup.
if [[ "\${1:-}" == '--install-udev-rules' ]]; then
	install_udev_rules
	exit \$?
fi

setup_logging || exit 1
setup_electron_env
cleanup_stale_lock

log_message '--- Wispr Flow Launcher Start (appimage) ---'
log_message "Timestamp: \$(date)"
log_message "Arguments: \$*"
log_message "APPDIR: \$appdir"
log_session_env

# Require a graphical session; refuse to launch from a bare TTY.
if ! check_display; then
	log_message 'No display detected (TTY session)'
	echo 'Error: Wispr Flow requires a graphical desktop environment.' >&2
	echo 'Run from within a Wayland or X11 session, not a TTY.' >&2
	echo 'Tip: run this AppImage with --doctor to diagnose your setup.' >&2
	exit 1
fi

detect_display_backend
build_electron_args 'appimage'

log_message "Executing: \$electron_bin \${electron_args[*]} \$*"
cd "\$HOME" || exit 1
exec "\$electron_bin" "\${electron_args[@]}" "\$@" >> "\$log_file" 2>&1
EOF
chmod 0755 "$APPDIR/AppRun"

say "Desktop entry + icons"
cat > "$APPDIR/$COMPONENT_ID.desktop" <<EOF
[Desktop Entry]
Name=Wispr Flow
Comment=Voice dictation that types into your focused app
GenericName=Voice Dictation
Exec=AppRun %U
Icon=$COMPONENT_ID
Terminal=false
Type=Application
Categories=Utility;AudioVideo;Audio;
StartupWMClass=$WM_CLASS
Keywords=voice;dictation;speech;transcription;
X-AppImage-Version=$APP_VERSION
X-AppImage-Name=Wispr Flow
EOF
# Standard copy for appimaged / validation tools.
cp "$APPDIR/$COMPONENT_ID.desktop" "$APPDIR/usr/share/applications/"

ICON_PNG="$DIST/resources/assets/logos/wispr-logo.png"     # 256x256 RGBA
ICON_SVG="$DIST/resources/assets/logos/wispr-flow.svg"
if [[ -f "$ICON_PNG" ]]; then
  cp "$ICON_PNG" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$COMPONENT_ID.png"
  # Top-level icon (appimagetool) + .DirIcon fallback, named after Icon= field.
  cp "$ICON_PNG" "$APPDIR/$COMPONENT_ID.png"
  cp "$ICON_PNG" "$APPDIR/.DirIcon"
else
  warn "256x256 icon not found at $ICON_PNG; AppImage icon may be missing."
fi
if [[ -f "$ICON_SVG" ]]; then
  cp "$ICON_SVG" "$APPDIR/usr/share/icons/hicolor/scalable/apps/$COMPONENT_ID.svg"
fi

say "AppStream metadata"
cat > "$APPDIR/usr/share/metainfo/${COMPONENT_ID}.appdata.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$COMPONENT_ID</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary</project_license>
  <name>Wispr Flow</name>
  <summary>Voice dictation that types into your focused app</summary>
  <description>
    <p>
      Unofficial Linux build of the Wispr Flow voice-dictation app, with a
      clean-room Rust helper providing text injection, active-app detection,
      and selection capture across KDE/GNOME/wlroots/X11.
    </p>
  </description>
  <launchable type="desktop-id">${COMPONENT_ID}.desktop</launchable>
  <icon type="stock">${COMPONENT_ID}</icon>
  <url type="homepage">https://wisprflow.ai</url>
  <provides>
    <binary>AppRun</binary>
  </provides>
  <categories>
    <category>Utility</category>
    <category>AudioVideo</category>
  </categories>
  <content_rating type="oars-1.1" />
  <releases>
    <release version="$APP_VERSION" date="$(date +%Y-%m-%d)">
      <description><p>Version $APP_VERSION.</p></description>
    </release>
  </releases>
</component>
EOF

#--- locate appimagetool -------------------------------------------------------
appimagetool=''
if command -v appimagetool >/dev/null 2>&1; then
  appimagetool="$(command -v appimagetool)"
else
  for a in x86_64 aarch64; do
    cand="$WORK/appimagetool-${a}.AppImage"
    [[ -f $cand ]] && { appimagetool="$cand"; break; }
  done
fi

if [[ -z $appimagetool ]]; then
  warn "appimagetool not found; AppDir staged at $APPDIR but no .AppImage built."
  echo "  To build: install appimagetool (or place appimagetool-<arch>.AppImage" >&2
  echo "  under $WORK), then re-run this maker." >&2
  echo "  Download: https://github.com/AppImage/appimagetool/releases" >&2
  exit 0
fi

say "Building AppImage with $appimagetool"
OUT="$WORK/${NAME}-${APP_VERSION}-${ARCH}.AppImage"
export ARCH

# In CI, embed update information and emit a .zsync delta so published AppImages
# self-update via AppImageUpdate / appimaged. Local builds skip it (there is no
# release to update from). Format:
#   gh-releases-zsync|<user>|<repo>|<tag>|<filename-glob>
# the glob matches any released version for this arch; |latest| tracks the most
# recent GitHub Release. Keep the glob in sync with the OUT filename above.
if [[ "${GITHUB_ACTIONS:-}" == 'true' ]]; then
  if ! command -v zsyncmake >/dev/null 2>&1; then
    warn 'zsyncmake not found; the .zsync delta will not be generated.'
    warn '  Install the "zsync" package in the build environment to enable it.'
  fi
  update_info="gh-releases-zsync|wispr-flow-linux|wispr-flow-linux|latest|${NAME}-*-${ARCH}.AppImage.zsync"
  say "Embedding AppImage update info: $update_info"
  if ! "$appimagetool" --updateinformation "$update_info" "$APPDIR" "$OUT"; then
    die "appimagetool failed to build the AppImage"
  fi
  if [[ -f "$OUT.zsync" ]]; then
    echo "  zsync: $OUT.zsync (publish alongside the AppImage)"
  else
    warn 'zsync delta not generated (zsyncmake missing?); auto-update will be slower.'
  fi
else
  if ! "$appimagetool" "$APPDIR" "$OUT"; then
    die "appimagetool failed to build the AppImage"
  fi
fi

say "Done"
echo "  AppImage: $OUT"
echo "  Size: $(du -h "$OUT" | cut -f1)"
echo
echo "  Run:      chmod +x '$OUT' && '$OUT'"
echo "  Setup:    '$OUT' --install-udev-rules  (input access; not auto-installed by AppImages)"
echo "  Diagnose: '$OUT' --doctor"
