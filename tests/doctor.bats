#!/usr/bin/env bats
#
# doctor.bats
# Tests for diagnostic helpers in scripts/doctor.sh
#
# Focused: the _pass/_fail/_warn counter behavior plus a few representative
# checks driven with stubbed conditions (clipboard tool presence via a
# `command` shadow, the helper-binary check against a temp file, and the
# display check). Not every branch — the counter and a couple of checks.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	export HOME="$TEST_TMP/home"
	export XDG_CACHE_HOME="$TEST_TMP/cache"
	export XDG_CONFIG_HOME="$TEST_TMP/config"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

	# Clear display vars to avoid host-state leakage.
	unset DISPLAY
	unset WAYLAND_DISPLAY
	unset XDG_SESSION_TYPE
	unset XDG_CURRENT_DESKTOP
	unset WISPR_USE_WAYLAND

	# shellcheck source=scripts/doctor.sh
	source "$SCRIPT_DIR/../scripts/doctor.sh"

	_doctor_colors
	_doctor_failures=0
	_HIDDEN_COMMANDS=''
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Shadow `command` so that `command -v <tool>` reports specific tools as
# absent. `command -v` finds shell functions too, so a stub function alone
# isn't enough — we shadow `command` itself. The shadow must be a top-level
# (not nested) function for bats `run` to see it, so it reads the hide-list
# from a global rather than closing over a local.
#
# Usage: _hide_commands wl-copy wl-paste   (sets the list)
_HIDDEN_COMMANDS=''
_hide_commands() {
	_HIDDEN_COMMANDS=" $* "
}

command() {
	if [[ $1 == '-v' && $_HIDDEN_COMMANDS == *" $2 "* ]]; then
		return 1
	fi
	builtin command "$@"
}

# =============================================================================
# Color helpers + pass/fail/warn counter behavior
# =============================================================================

@test "_doctor_colors: empty color vars when stdout is not a terminal" {
	# bats captures stdout, so [[ -t 1 ]] is false -> all empty.
	_doctor_colors
	[[ -z $_green ]]
	[[ -z $_red ]]
	[[ -z $_yellow ]]
	[[ -z $_bold ]]
	[[ -z $_reset ]]
}

@test "_pass: outputs [PASS] with message and does not touch counter" {
	_doctor_failures=0
	run _pass "all good"
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"all good"* ]]
	# Counter unchanged (run executes in a subshell, so assert via a
	# direct call too).
	_pass "all good" >/dev/null
	[[ $_doctor_failures -eq 0 ]]
}

@test "_fail: outputs [FAIL] and increments _doctor_failures" {
	_doctor_failures=0
	_fail "something broke" >/dev/null
	[[ $_doctor_failures -eq 1 ]]
	_fail "another thing" >/dev/null
	[[ $_doctor_failures -eq 2 ]]
}

@test "_fail: message is present in output" {
	run _fail "boom"
	[[ $output == *"[FAIL]"* ]]
	[[ $output == *"boom"* ]]
}

@test "_warn: outputs [WARN] with message, no counter change" {
	_doctor_failures=0
	run _warn "be careful"
	[[ $output == *"[WARN]"* ]]
	[[ $output == *"be careful"* ]]
	_warn "be careful" >/dev/null
	[[ $_doctor_failures -eq 0 ]]
}

@test "_info: outputs indented message" {
	run _info "extra detail"
	[[ $output == *"extra detail"* ]]
}

# =============================================================================
# _doctor_config_dir
# =============================================================================

@test "_doctor_config_dir: resolves under XDG_CONFIG_HOME standalone" {
	# launcher-common.sh is not sourced here, so the fallback branch runs.
	[[ $(_doctor_config_dir) == "$XDG_CONFIG_HOME/Wispr Flow" ]]
}

# =============================================================================
# _doctor_check_display
# =============================================================================

@test "_doctor_check_display: fails when no display server detected" {
	_doctor_failures=0
	_doctor_check_display >/dev/null
	[[ $_doctor_failures -eq 1 ]]
}

@test "_doctor_check_display: passes with WAYLAND_DISPLAY set" {
	WAYLAND_DISPLAY='wayland-0'
	_doctor_failures=0
	run _doctor_check_display
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"Wayland"* ]]
	_doctor_check_display >/dev/null
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_display: passes with DISPLAY set (X11)" {
	DISPLAY=':0'
	_doctor_failures=0
	run _doctor_check_display
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"X11"* ]]
	_doctor_check_display >/dev/null
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_display: notes native Wayland mode when WISPR_USE_WAYLAND=1" {
	WAYLAND_DISPLAY='wayland-0'
	WISPR_USE_WAYLAND='1'
	run _doctor_check_display
	[[ $output == *"native Wayland forced"* ]]
}

# =============================================================================
# _doctor_check_clipboard (stubbed tool presence)
# =============================================================================

@test "_doctor_check_clipboard: Wayland - fails when wl-clipboard missing" {
	WAYLAND_DISPLAY='wayland-0'
	_hide_commands wl-copy wl-paste xclip xsel
	_doctor_failures=0
	run _doctor_check_clipboard
	[[ $output == *"[FAIL]"* ]]
	[[ $output == *"wl-clipboard"* ]]
	_doctor_check_clipboard >/dev/null
	[[ $_doctor_failures -eq 1 ]]
}

@test "_doctor_check_clipboard: X11 - fails when neither xclip nor xsel present" {
	DISPLAY=':0'
	_hide_commands xclip xsel
	_doctor_failures=0
	run _doctor_check_clipboard
	[[ $output == *"[FAIL]"* ]]
	[[ $output == *"xclip"* ]]
	_doctor_check_clipboard >/dev/null
	[[ $_doctor_failures -eq 1 ]]
}

# =============================================================================
# _doctor_check_input_read (dir argument lets us drive it with fake event nodes)
# =============================================================================

@test "_doctor_check_input_read: passes when an event node is readable" {
	local dir="$TEST_TMP/input"
	mkdir -p "$dir"
	: >"$dir/event0"
	_doctor_failures=0
	run _doctor_check_input_read "$dir"
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"push-to-talk available"* ]]
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_input_read: fails when no event node is readable" {
	local dir="$TEST_TMP/input"
	mkdir -p "$dir"
	: >"$dir/event0"
	chmod 000 "$dir/event0"
	_doctor_failures=0
	run _doctor_check_input_read "$dir"
	[[ $output == *"[FAIL]"* ]]
	[[ $output == *"not work"* ]]
	_doctor_check_input_read "$dir" >/dev/null
	[[ $_doctor_failures -eq 1 ]]
	chmod 644 "$dir/event0"
}

@test "_doctor_check_input_read: warns when no event nodes exist" {
	local dir="$TEST_TMP/input"
	mkdir -p "$dir"
	_doctor_failures=0
	run _doctor_check_input_read "$dir"
	[[ $output == *"[WARN]"* ]]
	[[ $_doctor_failures -eq 0 ]]
}

# =============================================================================
# _doctor_check_helper (path argument lets us drive it with stub scripts that
# mimic the real helper's launch behaviors: print a version, exit silently on
# stdin EOF, abort with a loader error on stderr, or hang)
# =============================================================================

@test "_doctor_check_helper: passes and reports the probed version" {
	local helper="$TEST_TMP/wispr-flow-linux-helper"
	printf '#!/bin/sh\necho "wispr-flow-linux-helper 0.1.2"\n' > "$helper"
	chmod +x "$helper"
	_doctor_failures=0
	run _doctor_check_helper "$helper"
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"wispr-flow-linux-helper 0.1.2"* ]]
	_doctor_check_helper "$helper" >/dev/null
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_helper: passes a pre---version helper (clean EOF exit)" {
	# Helpers < v0.1.2 ignore argv, hit stdin EOF, and exit 0 silently.
	local helper="$TEST_TMP/wispr-flow-linux-helper"
	printf '#!/bin/sh\ncat >/dev/null\n' > "$helper"
	chmod +x "$helper"
	_doctor_failures=0
	run _doctor_check_helper "$helper"
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"predates --version"* ]]
	_doctor_check_helper "$helper" >/dev/null
	[[ $_doctor_failures -eq 0 ]]
}

@test "_doctor_check_helper: fails and surfaces stderr when launch aborts" {
	# The #16 blind spot: present + executable but aborts at startup
	# (e.g. the dynamic loader's GLIBC version error on stderr).
	local helper="$TEST_TMP/wispr-flow-linux-helper"
	{
		printf '#!/bin/sh\n'
		printf 'echo "version GLIBC_2.39 not found" >&2\n'
		printf 'exit 1\n'
	} > "$helper"
	chmod +x "$helper"
	_doctor_failures=0
	run _doctor_check_helper "$helper"
	[[ $output == *"[FAIL]"* ]]
	[[ $output == *"cannot launch"* ]]
	[[ $output == *"GLIBC_2.39 not found"* ]]
	_doctor_check_helper "$helper" >/dev/null
	[[ $_doctor_failures -eq 1 ]]
}

@test "_doctor_check_helper: fails when the probe times out" {
	local helper="$TEST_TMP/wispr-flow-linux-helper"
	printf '#!/bin/sh\nsleep 30\n' > "$helper"
	chmod +x "$helper"
	export WISPR_DOCTOR_HELPER_TIMEOUT=1
	_doctor_failures=0
	run _doctor_check_helper "$helper"
	[[ $output == *"[FAIL]"* ]]
	[[ $output == *"still running"* ]]
	_doctor_check_helper "$helper" >/dev/null
	[[ $_doctor_failures -eq 1 ]]
	unset WISPR_DOCTOR_HELPER_TIMEOUT
}

@test "_doctor_check_helper: fails when helper binary is missing" {
	_doctor_failures=0
	run _doctor_check_helper "$TEST_TMP/does-not-exist"
	[[ $output == *"[FAIL]"* ]]
	[[ $output == *"not found"* ]]
	_doctor_check_helper "$TEST_TMP/does-not-exist" >/dev/null
	[[ $_doctor_failures -eq 1 ]]
}

@test "_doctor_check_helper: fails when helper present but not executable" {
	local helper="$TEST_TMP/wispr-flow-linux-helper"
	printf 'binary\n' > "$helper"
	chmod 644 "$helper"
	_doctor_failures=0
	run _doctor_check_helper "$helper"
	[[ $output == *"[FAIL]"* ]]
	[[ $output == *"not executable"* ]]
	_doctor_check_helper "$helper" >/dev/null
	[[ $_doctor_failures -eq 1 ]]
}

@test "_doctor_check_helper: warns (not fails) when no path provided" {
	_doctor_failures=0
	run _doctor_check_helper ''
	[[ $output == *"[WARN]"* ]]
	_doctor_check_helper '' >/dev/null
	[[ $_doctor_failures -eq 0 ]]
}

# =============================================================================
# _doctor_check_singleton_lock
# =============================================================================

@test "_doctor_check_singleton_lock: passes when no lock file" {
	_doctor_failures=0
	run _doctor_check_singleton_lock
	[[ $output == *"[PASS]"* ]]
	[[ $output == *"no lock file"* ]]
}

@test "_doctor_check_singleton_lock: warns on stale lock (dead PID)" {
	local config_dir="$XDG_CONFIG_HOME/Wispr Flow"
	mkdir -p "$config_dir"
	ln -s "myhost-99999999" "$config_dir/SingletonLock"
	run _doctor_check_singleton_lock
	[[ $output == *"[WARN]"* ]]
	[[ $output == *"stale"* ]]
}

# =============================================================================
# run_doctor: return status reflects the failure counter
# =============================================================================

@test "run_doctor: returns non-zero when a check fails (no display, no clipboard)" {
	# No display set -> display check fails -> non-zero exit.
	run run_doctor "$TEST_TMP/does-not-exist"
	[[ $status -ne 0 ]]
}
