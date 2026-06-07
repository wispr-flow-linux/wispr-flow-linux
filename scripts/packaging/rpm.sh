#!/usr/bin/env bash
#===============================================================================
# rpm.sh -- package the validated Wispr Flow Linux tree as an .rpm
#
# Consumes the run-in-place tree produced by build-linux.sh + the manual
# assembly (build-linux/downloads/electron-dist), and produces an installable
# Fedora/RHEL rpm with:
#   /usr/lib/wispr-flow/            the Electron app tree (launcher renamed to
#                                   'wispr-flow' so app.isPackaged=true), plus
#                                   launcher-common.sh + doctor.sh
#   /usr/bin/wispr-flow             full launcher (sources launcher-common.sh,
#                                   handles --doctor, builds Electron args)
#   /usr/share/applications/wispr-flow.desktop
#   /usr/share/icons/hicolor/{256x256,scalable}/apps/wispr-flow.{png,svg}
#   /usr/lib/udev/rules.d/70-wispr-flow-uinput.rules   (uinput access for paste)
#   chrome-sandbox installed setuid-root (4755) so the app runs sandboxed.
#
# Runtime deps: wl-clipboard (Wayland paste/selection) is a hard Requires;
# xclip/xsel (X11 fallback) are weak Recommends.
#
# Shared maker signature (see deb.sh / appimage.sh):
#   rpm.sh <dist_dir> <version> <arch>
#     <dist_dir>  staged electron-dist tree (default: build-linux/downloads/electron-dist)
#     <version>   package version (default: $APP_VERSION env or 1.5.695)
#     <arch>      rpm-native arch: x86_64 | aarch64 (default: host uname -m)
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

# RPM Version: cannot contain a hyphen, so split a combined
# <wisprVer>-<repoVer> package version into Version: <wisprVer> and
# Release: <repoVer>. A bare version keeps the default release of 1. The
# canonical released asset name is always <name>-<version>-1.<arch>.rpm (no
# %{?dist}), so a worker can reconstruct the release tag from the filename.
if [[ "$APP_VERSION" == *-* ]]; then
  RPM_VERSION="${APP_VERSION%%-*}"
  RPM_RELEASE="${APP_VERSION#*-}"
else
  RPM_VERSION="$APP_VERSION"
  RPM_RELEASE="1"
fi
RELEASE="$RPM_RELEASE"

#--- metadata from env (build.sh exports these), with standalone fallbacks -----
NAME="${PACKAGE_NAME:-wispr-flow}"
WM_CLASS="${WM_CLASS:-Wispr Flow}"
# (MAINTAINER / DESCRIPTION are referenced in the spec below.)
DESCRIPTION="${DESCRIPTION:-Wispr Flow voice dictation for Linux (unofficial build)}"

WORK="$PROJECT_ROOT/build-linux/rpm"
PKGROOT="$WORK/pkgroot"           # FHS staging tree
TOPDIR="$WORK/rpmbuild"

say(){ printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$DIST/wispr-flow" ]] || die "renamed launcher not found at $DIST/wispr-flow (run the assembly + rename electron->wispr-flow first)"
[[ -f "$DIST/resources/app.asar" ]] || die "resources/app.asar not found under $DIST"
[[ -x "$DIST/resources/Release/wispr-flow-linux-helper" ]] || die "Linux helper not staged at resources/Release/wispr-flow-linux-helper"
[[ -f "$SCRIPTS_DIR/launcher-common.sh" ]] || die "launcher-common.sh not found at $SCRIPTS_DIR"
[[ -f "$SCRIPTS_DIR/doctor.sh" ]] || die "doctor.sh not found at $SCRIPTS_DIR"

say "Staging FHS tree at $PKGROOT"
rm -rf "$WORK"; mkdir -p "$PKGROOT" "$TOPDIR"/{SPECS,RPMS,BUILD,BUILDROOT}

APPDIR="$PKGROOT/usr/lib/$NAME"
mkdir -p "$APPDIR"
# Copy the whole dist EXCEPT: the duplicate 'electron' binary (identical to the
# renamed wispr-flow), the default app, and any downloads. Preserve modes.
# electron-dist is READ-ONLY input: we only ever copy FROM it.
rsync -a \
  --exclude 'electron' \
  --exclude 'resources/default_app.asar' \
  --exclude 'downloads' \
  "$DIST/"/ "$APPDIR/" 2>/dev/null || cp -a "$DIST/." "$APPDIR/"
rm -f "$APPDIR/resources/default_app.asar" "$APPDIR/electron" 2>/dev/null || true
# Drop the Windows helper if it lingered.
rm -f "$APPDIR/resources/Release/Wispr Flow Helper.exe" 2>/dev/null || true
chmod 0755 "$APPDIR/$NAME" "$APPDIR/resources/Release/wispr-flow-linux-helper"

# Bake the chrome-sandbox setuid bit into the staging tree so the %files dir
# walk records 4755 in the payload. Listing the file a second time under an
# %attr(4755) entry (on top of the parent-dir listing) makes it appear twice;
# on modern rpmbuild the "File listed twice" path can silently strip it from
# the payload (cf. claude-desktop-debian #609), shipping an rpm whose sandbox
# helper is missing or non-setuid. Set it here, list only the parent dir in
# %files, and assert below that rpmbuild didn't warn.
SANDBOX="$APPDIR/chrome-sandbox"
[[ -f "$SANDBOX" ]] || die "chrome-sandbox not found at $SANDBOX (Electron dist incomplete)"
chmod 4755 "$SANDBOX"

say "Shared launcher library + doctor"
cp "$SCRIPTS_DIR/launcher-common.sh" "$APPDIR/launcher-common.sh"
cp "$SCRIPTS_DIR/doctor.sh" "$APPDIR/doctor.sh"
chmod 0644 "$APPDIR/launcher-common.sh" "$APPDIR/doctor.sh"

say "Launcher /usr/bin/$NAME"
mkdir -p "$PKGROOT/usr/bin"
cat > "$PKGROOT/usr/bin/$NAME" <<EOF
#!/usr/bin/env bash
# Wispr Flow launcher (rpm). Sources the shared launcher library, runs the
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

# Install the input-access udev rule (already installed by the rpm %post;
# offered here too for parity and re-running after a manual rule removal).
if [[ "\${1:-}" == '--install-udev-rules' ]]; then
	install_udev_rules
	exit \$?
fi

setup_logging || exit 1
setup_electron_env
cleanup_stale_lock

log_message '--- Wispr Flow Launcher Start (rpm) ---'
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
build_electron_args 'rpm'

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

say "input access udev rule (uinput write + /dev/input read)"
mkdir -p "$PKGROOT/usr/lib/udev/rules.d"
# Canonical rule text — keep in sync with deb.sh, nix/wispr-flow.nix, and the
# launcher's _wispr_udev_rules_content (scripts/launcher-common.sh).
cat > "$PKGROOT/usr/lib/udev/rules.d/70-$NAME-uinput.rules" <<'EOF'
# Wispr Flow: grant the active-session user the input access the helper needs.
#  - write /dev/uinput        — keystroke injection (PasteText/SimulateKeyPress)
#  - read  /dev/input/event*  — global key monitor for push-to-talk and the
#                               in-app shortcut recorder
# TAG+="uaccess" scopes the grant to the active logind session; the input group
# + 0660 is the cross-distro fallback (then `usermod -aG input $USER` + re-login).
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
SUBSYSTEM=="input", KERNEL=="event*", TAG+="uaccess", GROUP="input", MODE="0660"
EOF

say "Writing spec"
SPEC="$TOPDIR/SPECS/$NAME.spec"
cat > "$SPEC" <<EOF
Name:           $NAME
Version:        $RPM_VERSION
Release:        $RELEASE%{?dist}
Summary:        $DESCRIPTION
License:        Proprietary
URL:            https://wisprflow.ai
BuildArch:      $ARCH

# The payload bundles its own Electron runtime; do not auto-generate library
# deps (they would reference unbundled .so names and may not resolve cleanly).
AutoReqProv:    no
Requires:       wl-clipboard
Recommends:     xclip
Recommends:     xsel

%global __os_install_post %{nil}
%global debug_package %{nil}
%global _build_id_links none
%global __brp_strip %{nil}
%global __brp_strip_static_archive %{nil}
%global __brp_check_rpaths %{nil}

%description
Unofficial repackaging of the Wispr Flow voice-dictation app for Linux, with a
clean-room Rust helper providing text injection (PasteText / SimulateKeyPress),
active-app detection, and selection capture across KDE/GNOME/wlroots/X11.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a "$PKGROOT"/. %{buildroot}/

%files
%defattr(-, root, root, -)
/usr/bin/$NAME
# /usr/lib/$NAME is listed once; chrome-sandbox's 4755 setuid bit was baked into
# the FHS tree before the spec was written, so this dir walk records it (see the
# chrome-sandbox staging note above; avoids the #609 "File listed twice" strip).
/usr/lib/$NAME
/usr/share/applications/$NAME.desktop
/usr/share/icons/hicolor/256x256/apps/$NAME.png
/usr/share/icons/hicolor/scalable/apps/$NAME.svg
/usr/lib/udev/rules.d/70-$NAME-uinput.rules

%post
# Reload udev so the input-access rule applies without a reboot (uinput write +
# /dev/input read).
if [ -x /usr/bin/udevadm ]; then
  /usr/bin/udevadm control --reload-rules 2>/dev/null || true
  /usr/bin/udevadm trigger --subsystem-match=misc --sysname-match=uinput 2>/dev/null || true
  /usr/bin/udevadm trigger --subsystem-match=input 2>/dev/null || true
fi
/usr/bin/update-desktop-database &>/dev/null || true
/usr/bin/gtk-update-icon-cache -q /usr/share/icons/hicolor &>/dev/null || true
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

%postun
if [ \$1 -eq 0 ]; then
  /usr/bin/udevadm control --reload-rules 2>/dev/null || true
  /usr/bin/update-desktop-database &>/dev/null || true
fi

%changelog
* Thu Jun 04 2026 Wispr Flow Linux port - $RPM_VERSION-$RELEASE
- Electron 42.3.0 + clean-room Rust helper; sqlite natives rebuilt for V8 14.8;
  macOS-only Applications-folder guard gated to darwin. Full launcher sources
  launcher-common.sh + doctor.sh.
EOF

say "Running rpmbuild"
RPMBUILD_LOG="$WORK/rpmbuild.log"
# Capture the build output so we can scan it for the #609 warning. set -e is
# active, so temporarily relax it around the pipeline to read PIPESTATUS rather
# than aborting before the diagnostic check.
set +e
rpmbuild --define "_topdir $TOPDIR" --target "$ARCH" -bb "$SPEC" 2>&1 \
  | tee "$RPMBUILD_LOG"
rpmbuild_rc=${PIPESTATUS[0]}
set -e
[[ $rpmbuild_rc -eq 0 ]] || die "rpmbuild failed (see $RPMBUILD_LOG)"

# Guard against re-introducing the chrome-sandbox double-listing: a "File listed
# twice" warning means %files has overlapping entries, and on modern rpmbuild
# the silent-strip path can drop the setuid sandbox from the payload (#609).
if grep -qF 'File listed twice' "$RPMBUILD_LOG"; then
  grep -F 'File listed twice' "$RPMBUILD_LOG" >&2
  die 'rpmbuild emitted "File listed twice" -- %files has overlapping listings (#609)'
fi

# rpmbuild names its output <name>-<Version>-<Release><dist>.<arch>.rpm (the
# %{?dist} tag varies per host). Locate it by Version-Release...
RPM_BUILT="$(find "$TOPDIR/RPMS" \
  -name "$NAME-$RPM_VERSION-$RPM_RELEASE*.rpm" | head -1)"
[[ -n "$RPM_BUILT" ]] || die "rpmbuild did not produce an rpm"

# ...then rename to the canonical, dist-free released asset name
#   <name>-<version>[-<repoVer>]-1.<arch>.rpm
# so a downstream worker can reconstruct the release tag from the filename and
# build.sh's <name>-<pkg_version>-*.rpm glob locates it deterministically.
RPM_OUT="$(dirname "$RPM_BUILT")/$NAME-$APP_VERSION-1.$ARCH.rpm"
if [[ "$RPM_BUILT" != "$RPM_OUT" ]]; then
  mv -f "$RPM_BUILT" "$RPM_OUT"
fi

say "Done"
echo "  RPM: $RPM_OUT"
echo "  Size: $(du -h "$RPM_OUT" | cut -f1)"
echo
echo "  Install:  sudo dnf install '$RPM_OUT'"
echo "  Run:      wispr-flow"
