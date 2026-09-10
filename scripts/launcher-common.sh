#!/usr/bin/env bash
# Common launcher functions for Wispr Flow (deb / rpm / AppImage).
# Sourced by the per-package /usr/bin/wispr-flow launcher to avoid
# duplicating the display-backend, logging, and Electron-arg logic.
#
# Scoped to Wispr Flow's actual runtime needs. The Claude-Desktop
# reference this was ported from also carried cowork/VM, wco-shim
# titlebar, IBus-override, and password-store handling — none of which
# Wispr Flow has, so they are intentionally absent here. See the Phase 3
# report for the kept-vs-dropped rationale.
#
# Env var convention: WISPR_* (not CLAUDE_*). Supported overrides:
#   WISPR_USE_WAYLAND=1   force native Wayland (Electron Ozone)
#   WISPR_DISABLE_GPU=1   disable GPU / software rasterizer (blank-window
#                         workaround on broken drivers / remote sessions)
#
# Design notes:
#   - WM_CLASS is hardcoded "Wispr Flow" (matches the .desktop
#     StartupWMClass written by the packaging makers; no sed placeholder).
#   - No --password-store flag. Wispr Flow uses Electron safeStorage, but
#     the port analysis records no re-auth-on-launch failure, and
#     Electron's keyring autodetect works on KDE/GNOME. Omitting the flag
#     keeps the launcher desktop-agnostic. (Contrast: claude-desktop
#     pins it for issue #593, which Wispr does not exhibit.)

# WM_CLASS / StartupWMClass — must match upstream productName "Wispr Flow".
readonly WM_CLASS='Wispr Flow'

# User config dir (Electron app name "Wispr Flow" -> ~/.config/Wispr Flow).
# Exposed as a function so doctor.sh and cleanup_stale_lock agree on it.
wispr_config_dir() {
	printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/Wispr Flow"
}

# Setup logging directory and file.
# Sets: log_dir, log_file
setup_logging() {
	log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/wispr-flow"
	mkdir -p "$log_dir" || return 1
	log_file="$log_dir/launcher.log"
}

# Log a message to the log file.
# Usage: log_message "message"
log_message() {
	echo "$1" >> "$log_file"
}

# Log the session/display environment vars that drive backend and input
# decisions, so bug reports carry enough context without an env-dump
# round trip.
#
# Emits one block:
#     env={
#       KEY=value
#       ...
#     }
#
# Empty or unset values are emitted as `KEY=` so absence is unambiguous
# (vs. silently omitted). Caller must run setup_logging first.
log_session_env() {
	local key
	log_message 'env={'
	for key in \
		XDG_SESSION_TYPE \
		WAYLAND_DISPLAY \
		DISPLAY \
		XDG_CURRENT_DESKTOP \
		WISPR_USE_WAYLAND \
		WISPR_DISABLE_GPU
	do
		log_message "  $key=${!key:-}"
	done
	log_message '}'
}

# Check if we have a valid display (not running from a TTY).
# Returns: 0 if a display is available, 1 if not.
check_display() {
	[[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]]
}

# Detect display backend (Wayland vs X11).
# Sets: is_wayland
#
# Electron 42 auto-detects Wayland/X11 via Ozone, so unlike the Claude
# reference we do NOT force XWayland: Wispr Flow's keystroke injection
# uses an in-process /dev/uinput virtual keyboard (not X11 XTEST global
# hotkeys), so native Wayland is the validated default. WISPR_USE_WAYLAND
# is retained as an explicit override that maps to native Ozone Wayland
# flags in build_electron_args.
detect_display_backend() {
	is_wayland=false
	[[ -n ${WAYLAND_DISPLAY:-} ]] && is_wayland=true
	# Return 0 unconditionally: the function's job is to *set* is_wayland,
	# not to report the backend via exit status. Without this, the trailing
	# `&&` above leaves $? at 1 on X11/no-Wayland, which would abort any
	# caller running under `set -e` (or break `detect_display_backend && ...`).
	return 0
}

# Build the Electron arguments array based on package type and backend.
# Requires: is_wayland to be set (call detect_display_backend first).
# Sets: electron_args array
# Arguments: $1 = "appimage" | "rpm" | "deb" | "nix" (affects sandbox).
build_electron_args() {
	local package_type="${1:-rpm}"

	electron_args=()

	# Sandbox: deb/rpm install chrome-sandbox setuid-root, so Electron
	# sandboxes itself with no flag. The AppImage runs from a FUSE mount
	# where the setuid bit is dropped, so it must pass --no-sandbox.
	[[ $package_type == 'appimage' ]] && electron_args+=('--no-sandbox')

	# WM_CLASS must match the .desktop StartupWMClass and upstream
	# productName so the window groups under the right taskbar icon.
	electron_args+=("--class=$WM_CLASS")

	# Remote XRDP sessions lack GPU acceleration and render a blank
	# window when GPU compositing is on. Detect via XRDP_SESSION (set by
	# xrdp's session init) and the loginctl session Type.
	local rdp_session_type=''
	[[ -n ${XDG_SESSION_ID:-} ]] && rdp_session_type=$(
		loginctl show-session "$XDG_SESSION_ID" \
			-p Type --value 2>/dev/null
	)
	# Track the GPU-disable decision so XRDP and WISPR_DISABLE_GPU do not
	# stack duplicate flags — either signal is sufficient.
	local _disable_gpu=false
	if [[ -n ${XRDP_SESSION:-} || $rdp_session_type == xrdp ]]; then
		_disable_gpu=true
		log_message 'XRDP session detected - GPU compositing disabled'
	fi
	# WISPR_DISABLE_GPU=1: opt-in workaround for blank windows / GPU
	# process crashes on broken drivers.
	if [[ ${WISPR_DISABLE_GPU:-} == '1' ]]; then
		_disable_gpu=true
		log_message 'WISPR_DISABLE_GPU=1 - hardware acceleration disabled'
	fi
	[[ $_disable_gpu == true ]] \
		&& electron_args+=('--disable-gpu' '--disable-software-rasterizer')

	# X11 session: let Electron's Ozone default handle it, no extra flags.
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
		return
	fi

	# Wayland session.
	if [[ ${WISPR_USE_WAYLAND:-} == '1' ]]; then
		# Explicit native-Wayland opt-in: pin the Ozone Wayland platform
		# and enable the Wayland IME path.
		log_message 'WISPR_USE_WAYLAND=1 - native Wayland (Ozone) backend'
		electron_args+=('--enable-features=UseOzonePlatform,WaylandWindowDecorations')
		electron_args+=('--ozone-platform=wayland')
		electron_args+=('--enable-wayland-ime')
		electron_args+=('--wayland-text-input-version=3')
		# Override a system-wide GDK_BACKEND=x11 that would otherwise stop
		# GTK from connecting to the compositor (blurry/failed HiDPI).
		export GDK_BACKEND=wayland
	else
		# Default: force XWayland (--ozone-platform=x11).
		# Under native Ozone Wayland, Electron ignores X11 EWMH window-type
		# hints (skipTaskbar, type:"toolbar"), so the status indicator appears
		# as a regular closeable window in GNOME Activities / Alt+Tab.
		# Under XWayland those hints are honoured by the compositor, giving
		# the status pill correct overlay behaviour.
		# WISPR_USE_WAYLAND=1 opts back into native Ozone for users who need it.
		log_message 'Wayland session - using XWayland (--ozone-platform=x11) for overlay window compatibility'
		electron_args+=('--ozone-platform=x11')
	fi
}

# Set common environment variables.
setup_electron_env() {
	# ELECTRON_FORCE_IS_PACKAGED makes app.isPackaged return true so the
	# app resolves resources via process.resourcesPath. Belt-and-braces:
	# the Electron binary is also renamed to 'wispr-flow' (off 'electron')
	# for the same reason, but the env var guarantees it.
	export ELECTRON_FORCE_IS_PACKAGED=true
}

# Clean up a stale Electron SingletonLock if the owning process is gone.
# requestSingleInstanceLock() silently quits the new instance when the
# lock is held; a stale lock (crash / unclean update) then blocks every
# launch with no user-facing error. The lock is a symlink -> "hostname-PID".
cleanup_stale_lock() {
	local config_dir lock_file
	config_dir="$(wispr_config_dir)"
	lock_file="$config_dir/SingletonLock"

	[[ -L $lock_file ]] || return 0

	local lock_target
	lock_target="$(readlink "$lock_file" 2>/dev/null)" || return 0

	local lock_pid="${lock_target##*-}"

	# Validate that we extracted a numeric PID.
	[[ $lock_pid =~ ^[0-9]+$ ]] || return 0

	if kill -0 "$lock_pid" 2>/dev/null; then
		# Process still running — lock is valid.
		return 0
	fi

	rm -f "$lock_file"
	log_message "Removed stale SingletonLock (PID $lock_pid no longer running)"
}

#===============================================================================
# Input-access udev rule installer (--install-udev-rules)
#
# For formats without a root post-install hook (AppImage, non-NixOS Nix): write
# the same rule the deb/rpm packages ship, then reload + trigger udev. Escalates
# via pkexec (graphical) or sudo. The deb/rpm/Nix builds install the rule for
# you; this is the manual one-step equivalent.
#===============================================================================

# Canonical rule text. Keep in sync with the copies in scripts/packaging/deb.sh,
# scripts/packaging/rpm.sh, and nix/wispr-flow.nix.
_wispr_udev_rules_content() {
	cat <<'UDEV'
# Wispr Flow: grant the active-session user the input access the helper needs.
#  - write /dev/uinput        — keystroke injection (PasteText/SimulateKeyPress)
#  - read  /dev/input/event*  — global key monitor for push-to-talk and the
#                               in-app shortcut recorder
# TAG+="uaccess" scopes the grant to the active logind session; the input group
# + 0660 is the cross-distro fallback (then `usermod -aG input $USER` + re-login).
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
SUBSYSTEM=="input", KERNEL=="event*", TAG+="uaccess", GROUP="input", MODE="0660"
UDEV
}

# Install the rule into /usr/lib/udev/rules.d and reload udev. Returns non-zero
# on failure. Needs root: runs directly if already root, else pkexec, else sudo.
install_udev_rules() {
	local rule_dst='/usr/lib/udev/rules.d/70-wispr-flow-uinput.rules'
	local tmp
	tmp="$(mktemp)" || {
		echo 'Error: mktemp failed' >&2
		return 1
	}
	_wispr_udev_rules_content > "$tmp"

	# The privileged half as one script, so a single escalation does everything.
	local script
	printf -v script '%s\n' \
		'set -e' \
		"install -D -m 0644 '$tmp' '$rule_dst'" \
		'if command -v udevadm >/dev/null 2>&1; then' \
		'	udevadm control --reload-rules || true' \
		'	udevadm trigger --subsystem-match=misc --sysname-match=uinput || true' \
		'	udevadm trigger --subsystem-match=input || true' \
		'fi'

	echo "Installing udev rule -> $rule_dst"
	local rc
	if [[ $EUID -eq 0 ]]; then
		bash -c "$script"
		rc=$?
	elif command -v pkexec >/dev/null 2>&1 \
		&& [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
		pkexec bash -c "$script"
		rc=$?
	elif command -v sudo >/dev/null 2>&1; then
		sudo bash -c "$script"
		rc=$?
	else
		echo 'Error: need root to install the rule.' >&2
		echo 'Install pkexec or sudo, or re-run this command as root.' >&2
		rm -f "$tmp"
		return 1
	fi
	rm -f "$tmp"

	if [[ $rc -ne 0 ]]; then
		echo "Error: udev rule install failed (exit $rc)." >&2
		return "$rc"
	fi
	echo 'Done. The rule grants the active-session user input access for'
	echo 'keystroke injection (/dev/uinput) and push-to-talk (/dev/input read).'
	echo 'Already-open sessions may need a re-login (or device replug) to pick'
	echo 'up the new ACL. Verify with: wispr-flow --doctor'
	return 0
}

#===============================================================================
# Doctor Diagnostics
#
# run_doctor and its helpers live in doctor.sh next to this file. Sourced
# here so any consumer of launcher-common.sh gets the run_doctor entry
# point. Each packaging target installs doctor.sh alongside this file.
#===============================================================================
# shellcheck source=scripts/doctor.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/doctor.sh"
