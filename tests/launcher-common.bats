#!/usr/bin/env bats
#
# launcher-common.bats
# Tests for launcher utility functions in scripts/launcher-common.sh
#
# Mirrors the claude-desktop-debian bats conventions: a per-test $TEST_TMP
# with HOME / XDG_* redirected, host display/env vars cleared, and the
# script sourced from a temp copy so doctor.sh co-locates next to it.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

# Check whether a value exists in the electron_args array.
# Supports glob patterns (e.g., '*WaylandWindowDecorations*').
has_electron_arg() {
	local pattern="$1"
	local arg
	for arg in "${electron_args[@]}"; do
		# shellcheck disable=SC2254
		[[ $arg == $pattern ]] && return 0
	done
	return 1
}

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Redirect all filesystem-touching functions to temp dirs.
	export HOME="$TEST_TMP/home"
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	export XDG_RUNTIME_DIR="$TEST_TMP/run"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"

	# Clear display / session vars so host state can't leak into tests.
	unset DISPLAY
	unset WAYLAND_DISPLAY
	unset WISPR_USE_WAYLAND
	unset WISPR_DISABLE_GPU
	unset XDG_CURRENT_DESKTOP
	unset XDG_SESSION_TYPE
	unset XDG_SESSION_ID
	unset XRDP_SESSION
	unset GDK_BACKEND

	# Copy to a temp dir so doctor.sh (sourced via BASH_SOURCE dirname)
	# co-locates next to the launcher copy.
	cp "$SCRIPT_DIR/../scripts/launcher-common.sh" "$TEST_TMP/launcher-common.sh"
	cp "$SCRIPT_DIR/../scripts/doctor.sh" "$TEST_TMP/doctor.sh"
	# shellcheck source=scripts/launcher-common.sh
	source "$TEST_TMP/launcher-common.sh"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# WM_CLASS / wispr_config_dir
# =============================================================================

@test "WM_CLASS: hardcoded to 'Wispr Flow' (matches StartupWMClass)" {
	[[ $WM_CLASS == 'Wispr Flow' ]]
}

@test "wispr_config_dir: under XDG_CONFIG_HOME with productName" {
	[[ $(wispr_config_dir) == "$XDG_CONFIG_HOME/Wispr Flow" ]]
}

@test "_wispr_udev_rules_content: emits both the uinput write and input read rules" {
	run _wispr_udev_rules_content
	[[ $status -eq 0 ]]
	# uinput write (injection) and /dev/input read (push-to-talk) lines present
	[[ $output == *'KERNEL=="uinput"'* ]]
	[[ $output == *'SUBSYSTEM=="input", KERNEL=="event*"'* ]]
	[[ $output == *'TAG+="uaccess"'* ]]
}

@test "wispr_config_dir: falls back to HOME/.config when XDG_CONFIG_HOME unset" {
	unset XDG_CONFIG_HOME
	[[ $(wispr_config_dir) == "$HOME/.config/Wispr Flow" ]]
}

# =============================================================================
# setup_logging
# =============================================================================

@test "setup_logging: creates log dir under cache" {
	run setup_logging
	[[ $status -eq 0 ]]
	[[ -d "$XDG_CACHE_HOME/wispr-flow" ]]
}

@test "setup_logging: sets log_file under XDG_CACHE_HOME" {
	setup_logging
	[[ $log_file == "$XDG_CACHE_HOME/wispr-flow/launcher.log" ]]
}

@test "setup_logging: falls back to HOME/.cache when XDG_CACHE_HOME unset" {
	unset XDG_CACHE_HOME
	setup_logging
	[[ $log_dir == "$HOME/.cache/wispr-flow" ]]
	[[ -d "$HOME/.cache/wispr-flow" ]]
}

# =============================================================================
# log_message
# =============================================================================

@test "log_message: appends messages to the log file" {
	setup_logging
	log_message "first line"
	log_message "second line"
	[[ -f $log_file ]]
	run cat "$log_file"
	[[ "${lines[0]}" == "first line" ]]
	[[ "${lines[1]}" == "second line" ]]
}

# =============================================================================
# log_session_env
# =============================================================================

@test "log_session_env: emits env={ ... } block with all required keys" {
	setup_logging
	XDG_SESSION_TYPE='wayland'
	WAYLAND_DISPLAY='wayland-0'
	DISPLAY=':0'
	XDG_CURRENT_DESKTOP='KDE'
	WISPR_USE_WAYLAND='1'
	WISPR_DISABLE_GPU='1'
	log_session_env

	run cat "$log_file"
	# Exact-line match locks block structure and per-key formatting.
	[[ "${lines[0]}" == 'env={' ]]
	[[ "${lines[1]}" == '  XDG_SESSION_TYPE=wayland' ]]
	[[ "${lines[2]}" == '  WAYLAND_DISPLAY=wayland-0' ]]
	[[ "${lines[3]}" == '  DISPLAY=:0' ]]
	[[ "${lines[4]}" == '  XDG_CURRENT_DESKTOP=KDE' ]]
	[[ "${lines[5]}" == '  WISPR_USE_WAYLAND=1' ]]
	[[ "${lines[6]}" == '  WISPR_DISABLE_GPU=1' ]]
	[[ "${lines[7]}" == '}' ]]
}

@test "log_session_env: unset values render as 'KEY=' (no value)" {
	setup_logging
	# All vars unset by setup().
	log_session_env

	run cat "$log_file"
	# Exact-line match proves the line ends right after '='.
	[[ "${lines[1]}" == '  XDG_SESSION_TYPE=' ]]
	[[ "${lines[2]}" == '  WAYLAND_DISPLAY=' ]]
	[[ "${lines[3]}" == '  DISPLAY=' ]]
	[[ "${lines[4]}" == '  XDG_CURRENT_DESKTOP=' ]]
	[[ "${lines[5]}" == '  WISPR_USE_WAYLAND=' ]]
	[[ "${lines[6]}" == '  WISPR_DISABLE_GPU=' ]]
}

# =============================================================================
# check_display
# =============================================================================

@test "check_display: fails when no display variables set (TTY)" {
	unset DISPLAY
	unset WAYLAND_DISPLAY
	run check_display
	[[ $status -ne 0 ]]
}

@test "check_display: succeeds with DISPLAY set" {
	DISPLAY=":0"
	run check_display
	[[ $status -eq 0 ]]
}

@test "check_display: succeeds with WAYLAND_DISPLAY set" {
	WAYLAND_DISPLAY="wayland-0"
	run check_display
	[[ $status -eq 0 ]]
}

@test "check_display: succeeds with both set" {
	DISPLAY=":0"
	WAYLAND_DISPLAY="wayland-0"
	run check_display
	[[ $status -eq 0 ]]
}

# =============================================================================
# detect_display_backend
# =============================================================================

@test "detect_display_backend: X11 session sets is_wayland=false" {
	DISPLAY=":0"
	detect_display_backend
	[[ $is_wayland == false ]]
}

@test "detect_display_backend: Wayland session sets is_wayland=true" {
	WAYLAND_DISPLAY="wayland-0"
	detect_display_backend
	[[ $is_wayland == true ]]
}

@test "detect_display_backend: no display vars defaults to is_wayland=false" {
	detect_display_backend
	[[ $is_wayland == false ]]
}

@test "detect_display_backend: WAYLAND_DISPLAY wins even with DISPLAY also set" {
	DISPLAY=":0"
	WAYLAND_DISPLAY="wayland-0"
	detect_display_backend
	[[ $is_wayland == true ]]
}

# =============================================================================
# build_electron_args
# =============================================================================

@test "build_electron_args: includes --class=Wispr Flow" {
	is_wayland=false
	setup_logging
	build_electron_args rpm
	has_electron_arg '--class=Wispr Flow'
}

@test "build_electron_args: appimage adds --no-sandbox" {
	is_wayland=false
	setup_logging
	build_electron_args appimage
	has_electron_arg '--no-sandbox'
}

@test "build_electron_args: rpm does NOT add --no-sandbox" {
	is_wayland=false
	setup_logging
	build_electron_args rpm
	# shellcheck disable=SC2314 # last command in test, ! works correctly
	! has_electron_arg '--no-sandbox'
}

@test "build_electron_args: deb does NOT add --no-sandbox" {
	is_wayland=false
	setup_logging
	build_electron_args deb
	# shellcheck disable=SC2314
	! has_electron_arg '--no-sandbox'
}

@test "build_electron_args: WISPR_DISABLE_GPU=1 adds --disable-gpu" {
	is_wayland=false
	WISPR_DISABLE_GPU=1
	setup_logging
	build_electron_args rpm
	has_electron_arg '--disable-gpu'
	has_electron_arg '--disable-software-rasterizer'
}

@test "build_electron_args: no GPU flags without WISPR_DISABLE_GPU" {
	is_wayland=false
	setup_logging
	build_electron_args rpm
	# shellcheck disable=SC2314
	! has_electron_arg '--disable-gpu'
}

@test "build_electron_args: X11 session adds no Wayland flags" {
	is_wayland=false
	setup_logging
	build_electron_args deb
	# shellcheck disable=SC2314
	! has_electron_arg '--ozone-platform=wayland'
}

@test "build_electron_args: Wayland default (auto-detect) adds no native flags" {
	# Default Wayland path: Electron Ozone auto-detect, no forced platform.
	is_wayland=true
	setup_logging
	build_electron_args deb
	# shellcheck disable=SC2314
	! has_electron_arg '--ozone-platform=wayland'
}

@test "build_electron_args: WISPR_USE_WAYLAND=1 adds native Wayland flags" {
	is_wayland=true
	WISPR_USE_WAYLAND=1
	setup_logging
	build_electron_args deb
	has_electron_arg '--ozone-platform=wayland'
	has_electron_arg '--enable-wayland-ime'
	has_electron_arg '--wayland-text-input-version=3'
	has_electron_arg '*WaylandWindowDecorations*'
}

@test "build_electron_args: WISPR_USE_WAYLAND=1 exports GDK_BACKEND=wayland" {
	is_wayland=true
	WISPR_USE_WAYLAND=1
	setup_logging
	build_electron_args deb
	[[ $GDK_BACKEND == 'wayland' ]]
}

@test "build_electron_args: WISPR_USE_WAYLAND ignored on X11 (is_wayland=false)" {
	# The native-Wayland flags only apply on an actual Wayland session.
	is_wayland=false
	WISPR_USE_WAYLAND=1
	setup_logging
	build_electron_args deb
	# shellcheck disable=SC2314
	! has_electron_arg '--ozone-platform=wayland'
}

# =============================================================================
# setup_electron_env
# =============================================================================

@test "setup_electron_env: exports ELECTRON_FORCE_IS_PACKAGED=true" {
	setup_electron_env
	[[ $ELECTRON_FORCE_IS_PACKAGED == 'true' ]]
}

# =============================================================================
# cleanup_stale_lock
# =============================================================================

@test "cleanup_stale_lock: no lock file - returns 0" {
	mkdir -p "$(wispr_config_dir)"
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
}

@test "cleanup_stale_lock: removes stale lock (dead PID)" {
	local config_dir
	config_dir="$(wispr_config_dir)"
	mkdir -p "$config_dir"
	# PID 99999999 almost certainly doesn't exist.
	ln -s "myhost-99999999" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	[[ ! -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: keeps lock for running process" {
	local config_dir
	config_dir="$(wispr_config_dir)"
	mkdir -p "$config_dir"
	# Our own PID is guaranteed to be running.
	ln -s "myhost-$$" "$config_dir/SingletonLock"
	setup_logging
	cleanup_stale_lock
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: ignores non-numeric PID in lock target" {
	local config_dir
	config_dir="$(wispr_config_dir)"
	mkdir -p "$config_dir"
	ln -s "myhost-notanumber" "$config_dir/SingletonLock"
	setup_logging
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
	[[ -L "$config_dir/SingletonLock" ]]
}

@test "cleanup_stale_lock: leaves a regular file (not a symlink) alone" {
	local config_dir
	config_dir="$(wispr_config_dir)"
	mkdir -p "$config_dir"
	echo "not a symlink" > "$config_dir/SingletonLock"
	setup_logging
	run cleanup_stale_lock
	[[ $status -eq 0 ]]
	[[ -f "$config_dir/SingletonLock" ]]
}
