# shellcheck shell=bash
#===============================================================================
# Doctor Diagnostics for Wispr Flow
#
# Sourced by: scripts/launcher-common.sh (in turn sourced by the per-package
# /usr/bin/wispr-flow launcher — deb / rpm / AppImage).
#
# Provides: run_doctor (the `wispr-flow --doctor` entry point) plus its
# internal helpers. Self-contained — no dependency on launcher-common.sh
# state, though it reuses wispr_config_dir() when available.
#
# Scoped to Wispr Flow's load-bearing runtime requirements: /dev/uinput
# write access (keystroke injection), input-group fallback, wl-clipboard /
# xclip-xsel, AT-SPI accessibility, the GNOME Shell window-bridge extension
# (relogin caveat), the helper-binary launch probe, and recent crashes.
#
# To add a check: define `_check_<name>`, call it from run_doctor, and use
# _pass / _fail / _warn / _info. _fail increments _doctor_failures (local to
# run_doctor) which becomes the exit status.
#===============================================================================

# GNOME Shell extension UUID, must match the helper's bundled
# gnome_extension/metadata.json (org.wispr.flow.WindowBridge bridge).
_WISPR_GNOME_EXT_UUID='wispr-flow-window-bridge@wispr.flow'

# Color helpers (disabled when stdout is not a terminal).
_doctor_colors() {
	if [[ -t 1 ]]; then
		_green='\033[0;32m'
		_red='\033[0;31m'
		_yellow='\033[0;33m'
		_bold='\033[1m'
		_reset='\033[0m'
	else
		_green='' _red='' _yellow='' _bold='' _reset=''
	fi
}

_pass() { echo -e "${_green}[PASS]${_reset} $*"; }
_fail() {
	echo -e "${_red}[FAIL]${_reset} $*"
	_doctor_failures=$((_doctor_failures + 1))
}
_warn() { echo -e "${_yellow}[WARN]${_reset} $*"; }
_info() { echo -e "       $*"; }

# Resolve the user config dir even when this file is sourced standalone
# (i.e. without launcher-common.sh defining wispr_config_dir).
_doctor_config_dir() {
	if declare -F wispr_config_dir &>/dev/null; then
		wispr_config_dir
	else
		printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/Wispr Flow"
	fi
}

#------------------------------------------------------------------------------
# Display / session backend.
#------------------------------------------------------------------------------
_doctor_check_display() {
	if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
		_pass "Display server: Wayland (WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
		if [[ ${WISPR_USE_WAYLAND:-} == '1' ]]; then
			_info 'Mode: native Wayland forced (WISPR_USE_WAYLAND=1)'
		else
			_info 'Mode: Electron Ozone auto-detect (default)'
		fi
	elif [[ -n ${DISPLAY:-} ]]; then
		_pass "Display server: X11 (DISPLAY=$DISPLAY)"
	else
		_fail 'No display server detected' \
			'(DISPLAY and WAYLAND_DISPLAY are unset)'
		_info 'Fix: run from within a Wayland or X11 session, not a TTY'
		return
	fi

	# Compositor family from XDG_CURRENT_DESKTOP (may be colon-separated,
	# e.g. "ubuntu:GNOME"). Lowercase for matching.
	local desktop="${XDG_CURRENT_DESKTOP:-unknown}"
	local d="${desktop,,}"
	local family
	case "$d" in
		*kde*|*plasma*) family='KDE Plasma (KWin)' ;;
		*gnome*)        family='GNOME (Mutter)' ;;
		*sway*|*hyprland*|*wlroots*|*niri*|*river*)
			family='wlroots-based' ;;
		*) family='other / unknown' ;;
	esac
	_info "Desktop: $desktop  [$family]"
}

#------------------------------------------------------------------------------
# /dev/uinput — the load-bearing check for keystroke injection.
#------------------------------------------------------------------------------
_doctor_check_uinput() {
	local node='/dev/uinput'
	if [[ ! -e $node ]]; then
		_fail '/dev/uinput: missing (uinput kernel module not loaded)'
		_info 'Fix: sudo modprobe uinput  (and ensure it loads at boot)'
		return
	fi
	if [[ -w $node ]]; then
		_pass '/dev/uinput: writable (keystroke injection available)'
		return
	fi
	_fail '/dev/uinput: exists but NOT writable by current user'
	_info 'Keystroke injection (paste / SimulateKeyPress) will fail.'
	_info 'Fix (preferred, persistent): install the udev rule'
	_info '  KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput",'
	_info '  TAG+="uaccess", GROUP="input", MODE="0660"'
	_info '  then: sudo udevadm control --reload-rules && sudo udevadm trigger'
	# SC2016: literal $USER is intentional — these are copy-paste remedies
	# the user runs in their own shell, not expanded here.
	# shellcheck disable=SC2016
	_info 'Fix (group fallback): sudo usermod -aG input "$USER"  (then re-login)'
	# shellcheck disable=SC2016
	_info 'Fix (this session only): sudo setfacl -m u:$USER:rw /dev/uinput'
}

#------------------------------------------------------------------------------
# input group — fallback grant path when the uaccess ACL is absent.
#------------------------------------------------------------------------------
_doctor_check_input_group() {
	if ! getent group input &>/dev/null; then
		_info 'input group: not present on this system (uaccess ACL path only)'
		return
	fi
	if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx 'input'; then
		_pass 'input group: current user is a member'
	else
		# Not necessarily a failure: a uaccess ACL may already grant
		# /dev/uinput access. Only warn so the uinput check stays the
		# authoritative signal.
		_warn 'input group: current user is NOT a member'
		_info 'Harmless if /dev/uinput is already writable above.'
		# shellcheck disable=SC2016  # literal $USER: copy-paste remedy
		_info 'Otherwise: sudo usermod -aG input "$USER"  (then re-login)'
	fi
}

#------------------------------------------------------------------------------
# /dev/input read — load-bearing for push-to-talk and the shortcut recorder.
# The helper monitors global keys by reading /dev/input/event* (evdev); without
# read access no KeypressEvent reaches the app, so no hotkey ever fires and the
# in-app shortcut recorder captures nothing.
#------------------------------------------------------------------------------
# shellcheck disable=SC2120  # $1 (dir) is an optional test seam; prod uses the
# default /dev/input, tests/doctor.bats drives it with fake event nodes.
_doctor_check_input_read() {
	# dir override (default /dev/input) keeps this testable with fake nodes.
	local dir="${1:-/dev/input}" dev readable=0 total=0
	if [[ ! -d $dir ]]; then
		_fail '/dev/input: missing (no evdev input layer)'
		return
	fi
	for dev in "$dir"/event*; do
		[[ -e $dev ]] || continue
		total=$((total + 1))
		[[ -r $dev ]] && readable=$((readable + 1))
	done
	if ((total == 0)); then
		_warn '/dev/input: no event devices found'
		return
	fi
	if ((readable > 0)); then
		_pass "/dev/input: ${readable}/${total} event device(s) readable" \
			'(push-to-talk available)'
		return
	fi
	_fail "/dev/input: none of ${total} event device(s) readable"
	_info 'Push-to-talk and the in-app shortcut recorder will not work.'
	_info 'Fix (easiest): wispr-flow --install-udev-rules  (installs the rule via pkexec/sudo)'
	# shellcheck disable=SC2016  # literal $USER: copy-paste remedy
	_info 'Fix (group, grants both input read + uinput write): sudo usermod -aG input "$USER"  (then re-login)'
}

#------------------------------------------------------------------------------
# Push-to-talk liveness — is the RUNNING helper watching the keyboards that
# exist right now? The static readability check above stays green while a
# helper that enumerated /dev/input once (helper <= v0.1.2) decays to watching
# nothing as devices churn (wispr-flow-linux/helper#7): each reader thread
# dies with its device and nothing rescans. Compare the helper's open
# event-node fds (procfs) against the keyboard-capable nodes present now.
#
# A "keyboard" mirrors the helper's own filter: a /proc/bus/input/devices
# block whose KEY bitmap advertises the letter keys KEY_A(30)+KEY_Z(44) —
# this excludes mice, power buttons and lid switches (which still get the
# kernel kbd handler). The helper's own uinput injection device is excluded:
# it is deliberately never watched (it would echo injected keys).
#------------------------------------------------------------------------------
# Args are test seams (tests/doctor.bats drives them with fixtures):
#   $1 proc root (default /proc)   $2 input device list   $3 launcher.log
#   $4 helper pid override (skips pgrep)
_doctor_check_capture_liveness() {
	local proc_root="${1:-/proc}"
	local devices_file="${2:-/proc/bus/input/devices}"
	local log_path="${3:-${XDG_CACHE_HOME:-$HOME/.cache}/wispr-flow/launcher.log}"
	local pid="${4:-}"

	# Selected capture backend: the helper logs one line per launch; the
	# newest one is authoritative for the current/most recent run.
	local backend=''
	if [[ -r $log_path ]]; then
		backend=$(grep -ao 'key capture: [^"'\'']*' "$log_path" 2>/dev/null \
			| tail -n 1) || backend=''
		backend="${backend#key capture: }"
	fi
	[[ -n $backend ]] && _info "Capture backend (last helper launch): $backend"

	if [[ -z $pid ]]; then
		pid=$(pgrep -f 'wispr-flow-linux-helper$' 2>/dev/null | head -n 1)
	fi
	if [[ -z $pid || ! -d "$proc_root/$pid/fd" ]]; then
		_info 'Monitor liveness: helper not running' \
			'(launch Wispr Flow, then re-run doctor to check)'
		return
	fi

	# XInput2 (true X11) holds no event-node fds; the comparison below only
	# applies to the evdev backend.
	if [[ $backend == *XInput2* ]]; then
		_pass "Monitor liveness: helper (pid $pid) uses XInput2" \
			'(no device fds to check)'
		return
	fi

	if [[ ! -r $devices_file ]]; then
		_info 'Monitor liveness: cannot read the input device list'
		return
	fi

	# Event nodes the helper currently holds open.
	local watched=' '
	local fd target
	for fd in "$proc_root/$pid/fd"/*; do
		[[ -e $fd || -L $fd ]] || continue
		target=$(readlink "$fd" 2>/dev/null) || continue
		if [[ $target == /dev/input/event* ]]; then
			watched+="${target##*/} "
		fi
	done

	# Keyboard-capable nodes present now.
	local -a keyboards=() unwatched=()
	local line name='' ev='' keybits='' tok
	while IFS= read -r line || [[ -n $line ]]; do
		case $line in
			N:*)
				name="${line#*Name=\"}"
				name="${name%\"}"
				;;
			B:\ KEY=*)
				keybits="${line##* }"
				;;
			H:*)
				ev=''
				for tok in ${line#*Handlers=}; do
					[[ $tok == event[0-9]* ]] && ev="$tok"
				done
				;;
			'')
				_doctor_liveness_collect
				name='' ev='' keybits=''
				;;
		esac
	done < "$devices_file"
	_doctor_liveness_collect

	if ((${#keyboards[@]} == 0)); then
		_info 'Monitor liveness: no keyboard-capable input devices found'
		return
	fi
	if ((${#unwatched[@]} == 0)); then
		_pass "Monitor liveness: helper (pid $pid) is watching" \
			"${#keyboards[@]}/${#keyboards[@]} keyboard device(s)"
		return
	fi
	_warn "Monitor liveness: helper (pid $pid) is NOT watching" \
		"${#unwatched[@]} of ${#keyboards[@]} keyboard device(s):"
	local k
	for k in "${unwatched[@]}"; do
		_info "  unwatched: $k"
	done
	_info 'Push-to-talk from those keyboards is dead until Wispr Flow is'
	_info 'restarted. Helper <= v0.1.2 loses keyboards that re-enumerate'
	_info '(Bluetooth reconnect, USB replug, suspend/resume); fixed by'
	_info 'wispr-flow-linux/helper#7 hotplug adoption.'
}

# Block-end collector for _doctor_check_capture_liveness: appends the block
# just parsed to `keyboards` (and `unwatched` when the helper does not hold
# its node open). Reads/writes the caller's locals; bash dynamic scoping.
_doctor_liveness_collect() {
	[[ -n $ev && -n $keybits ]] || return 0
	[[ $keybits =~ ^[0-9a-fA-F]{1,16}$ ]] || return 0
	# Letter-key capability, mirroring the helper's EVIOCGBIT filter: bits
	# KEY_A(30) and KEY_Z(44) of the last (lowest) 64-bit word of the KEY
	# bitmap. Mice, power buttons and lid switches fail this even when they
	# carry the kbd handler.
	local v=$((16#$keybits))
	(((v >> 30) & 1)) || return 0
	(((v >> 44) & 1)) || return 0
	# The helper's own uinput injection keyboard is never watched by design.
	[[ $name == 'Wispr Flow Linux Helper' ]] && return 0
	keyboards+=("$ev ($name)")
	if [[ $watched != *" $ev "* ]]; then
		unwatched+=("$ev ($name)")
	fi
}

#------------------------------------------------------------------------------
# Clipboard tools — hard requirement on Wayland (paste/selection).
#------------------------------------------------------------------------------
_doctor_check_clipboard() {
	if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
		if command -v wl-copy &>/dev/null && command -v wl-paste &>/dev/null; then
			_pass 'Clipboard: wl-copy and wl-paste present (Wayland)'
		else
			_fail 'Clipboard: wl-clipboard missing (wl-copy / wl-paste)'
			_info 'Wayland paste and selection capture require it.'
			_info 'Fix: install the "wl-clipboard" package'
		fi
		# X11 fallback tools are still useful under XWayland; note only.
		if command -v xclip &>/dev/null || command -v xsel &>/dev/null; then
			_info 'XWayland fallback: xclip/xsel also present'
		fi
		return
	fi

	# X11 session.
	if command -v xclip &>/dev/null || command -v xsel &>/dev/null; then
		local tools=()
		command -v xclip &>/dev/null && tools+=('xclip')
		command -v xsel &>/dev/null && tools+=('xsel')
		_pass "Clipboard: ${tools[*]} present (X11)"
	else
		_fail 'Clipboard: neither xclip nor xsel found (X11)'
		_info 'X11 paste and selection capture require one of them.'
		_info 'Fix: install "xclip" or "xsel"'
	fi
}

#------------------------------------------------------------------------------
# AT-SPI accessibility — best-effort. Off by default; the helper enables it.
#------------------------------------------------------------------------------
_doctor_check_atspi() {
	# Preferred signal: the gsettings toggle the helper flips
	# (set_session_accessibility). Absent gsettings -> fall back to probing
	# the a11y bus address.
	local enabled=''
	if command -v gsettings &>/dev/null; then
		enabled=$(gsettings get org.gnome.desktop.interface toolkit-accessibility \
			2>/dev/null) || enabled=''
	fi

	if [[ $enabled == 'true' ]]; then
		_pass 'AT-SPI: accessibility enabled (toolkit-accessibility=true)'
		return
	fi

	# Probe whether an a11y bus is reachable at all (per-app dictation /
	# selection reads still work once the helper enables it at runtime).
	local a11y_reachable=false
	if command -v dbus-send &>/dev/null; then
		if dbus-send --session --print-reply --reply-timeout=1000 \
			--dest=org.a11y.Bus /org/a11y/bus \
			org.a11y.Bus.GetAddress &>/dev/null
		then
			a11y_reachable=true
		fi
	fi

	if [[ $enabled == 'false' ]]; then
		_warn 'AT-SPI: accessibility disabled (toolkit-accessibility=false)'
		_info 'Off by default; the helper enables it at runtime (best-effort).'
		_info 'Selection reads (GetSelectedText) may be empty until then.'
	elif [[ $a11y_reachable == true ]]; then
		_pass 'AT-SPI: a11y bus reachable (org.a11y.Bus)'
	else
		_warn 'AT-SPI: accessibility state unknown (a11y bus not reachable)'
		_info 'The helper enables accessibility at runtime; this is usually fine.'
	fi
}

#------------------------------------------------------------------------------
# GNOME Shell extension — only relevant on GNOME. Relogin caveat.
#------------------------------------------------------------------------------
_doctor_check_gnome_extension() {
	local desktop="${XDG_CURRENT_DESKTOP:-}"
	[[ ${desktop,,} == *gnome* ]] || return 0

	local ext_base="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions"
	local ext_dir="$ext_base/$_WISPR_GNOME_EXT_UUID"

	if [[ ! -d $ext_dir ]]; then
		_info "GNOME extension: not yet installed ($_WISPR_GNOME_EXT_UUID)"
		_info 'The helper installs it on first run, then asks you to re-login.'
		return
	fi

	# Installed on disk. Is it actually loaded/active in the running shell?
	local state=''
	if command -v gnome-extensions &>/dev/null; then
		state=$(gnome-extensions info "$_WISPR_GNOME_EXT_UUID" 2>/dev/null \
			| awk -F': ' '/State:/ {print $2; exit}')
	fi

	case "$state" in
		ACTIVE|ENABLED)
			_pass "GNOME extension: active ($_WISPR_GNOME_EXT_UUID)" ;;
		'')
			_warn "GNOME extension: installed but state unknown"
			_info 'If active-app detection is wrong, log out and back in.' ;;
		*)
			_warn "GNOME extension: installed but not active (state=$state)"
			_info 'GNOME scans extensions only at login.' \
				'Log out and back in to activate it.' ;;
	esac
}

#------------------------------------------------------------------------------
# Helper binary — present, executable, and actually launches. Stat checks
# alone green-lit a helper that aborted at exec with `GLIBC_2.39 not found`
# (wispr-flow-linux/helper#1, #16), so probe by running `--version` with
# stdin at EOF:
#   * helper >= v0.1.2 prints its version and exits 0
#   * older helpers ignore argv, hit stdin EOF, and exit 0 silently
#   * a binary that cannot start exits non-zero with the loader's
#     message on stderr — surfaced below
# fd 3 (the helper's IPC return channel) is redirected to /dev/null so a
# probed helper can never write frames into a descriptor the launcher
# happens to have open.
#------------------------------------------------------------------------------
_doctor_check_helper() {
	local helper_path="${1:-}"
	if [[ -z $helper_path ]]; then
		_warn 'Helper binary: path not provided to doctor'
		return
	fi
	if [[ ! -e $helper_path ]]; then
		_fail "Helper binary: not found at $helper_path"
		_info 'Text injection / active-app detection will not work.'
		_info 'Fix: reinstall the wispr-flow package'
		return
	fi
	if [[ ! -x $helper_path ]]; then
		local perms
		perms=$(stat -c '%a' "$helper_path" 2>/dev/null || echo '?')
		_fail "Helper binary: not executable (perms=$perms) at $helper_path"
		_info "Fix: chmod +x '$helper_path'"
		return
	fi

	local timeout_s="${WISPR_DOCTOR_HELPER_TIMEOUT:-5}"
	local err_file probe_out status=0
	err_file=$(mktemp "${TMPDIR:-/tmp}/wispr-doctor-helper.XXXXXX")
	probe_out=$(timeout "$timeout_s" "$helper_path" --version \
		</dev/null 2>"$err_file" 3>/dev/null) || status=$?

	if [[ $status -eq 0 ]]; then
		if [[ $probe_out == wispr-flow-linux-helper* ]]; then
			_pass "Helper binary: launches OK ($probe_out)"
		else
			_pass "Helper binary: launches OK ($helper_path)"
			_info 'Helper predates --version (< v0.1.2); no version reported.'
		fi
		rm -f "$err_file"
		return
	fi

	if [[ $status -eq 124 ]]; then
		_fail "Helper binary: still running after ${timeout_s}s probe" \
			"at $helper_path"
		_info 'The helper did not exit on stdin EOF; it may be wedged.'
	else
		_fail "Helper binary: cannot launch (exit $status) at $helper_path"
		_info 'Text injection / push-to-talk will not work.'
	fi
	# Surface the launch-failure cause (e.g. `GLIBC_2.39 not found`).
	local line
	while IFS= read -r line; do
		_info "stderr: $line"
	done < <(tail -n 3 "$err_file")
	rm -f "$err_file"
}

#------------------------------------------------------------------------------
# Recent crashes — scan launcher.log tail for crash / FATAL markers.
#------------------------------------------------------------------------------
_doctor_check_recent_crashes() {
	local log_path
	log_path="${XDG_CACHE_HOME:-$HOME/.cache}/wispr-flow/launcher.log"
	[[ -f $log_path ]] || return 0

	# Scan the tail only; the log is append-only and can grow large.
	local hits
	hits=$(tail -n 500 "$log_path" 2>/dev/null \
		| grep -ciE 'FATAL|segfault|SIGSEGV|SIGABRT|core dumped|crashed|GPU process' ) \
		|| hits=0
	[[ $hits =~ ^[0-9]+$ ]] || hits=0

	if ((hits == 0)); then
		_pass 'Recent crashes: none in launcher.log tail'
	else
		_warn "Recent crashes: $hits crash/FATAL marker(s) in launcher.log tail"
		_info "Inspect: tail -n 500 '$log_path' | grep -iE 'FATAL|crash|GPU'"
		_info 'If GPU-related, try WISPR_DISABLE_GPU=1 in the environment.'
	fi
}

#------------------------------------------------------------------------------
# SingletonLock — surface a stale single-instance lock (blocks launches).
#------------------------------------------------------------------------------
_doctor_check_singleton_lock() {
	local config_dir lock_file
	config_dir="$(_doctor_config_dir)"
	lock_file="$config_dir/SingletonLock"
	[[ -L $lock_file ]] || { _pass 'SingletonLock: no lock file (OK)'; return; }

	local lock_target lock_pid
	lock_target="$(readlink "$lock_file" 2>/dev/null)" || true
	lock_pid="${lock_target##*-}"
	if [[ $lock_pid =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
		_pass "SingletonLock: held by running process (PID $lock_pid)"
	else
		_warn "SingletonLock: stale lock (PID ${lock_pid:-?} not running)"
		_info "Fix: rm '$lock_file'  (the launcher also clears this on start)"
	fi
}

#------------------------------------------------------------------------------
# Electron runtime — the renamed Electron binary the launcher exec's must exist
# and be executable. Version is read from the sibling 'version' file rather than
# launching Electron (which can hang).
#------------------------------------------------------------------------------
_doctor_electron_version() {
	local version_file
	version_file="$(dirname "$1")/version"
	[[ -r $version_file ]] && printf '%s' "$(< "$version_file")"
}

_doctor_check_electron() {
	local electron_path="${1:-}"
	if [[ -z $electron_path ]]; then
		_warn 'Electron runtime: path not provided to doctor'
		return
	fi
	if [[ ! -x $electron_path ]]; then
		_fail "Electron runtime: not found / not executable at $electron_path"
		_info 'The launcher cannot start the app.'
		_info 'Fix: reinstall the wispr-flow package'
		return
	fi
	local ver
	ver=$(_doctor_electron_version "$electron_path")
	if [[ $ver =~ ^v?[0-9]+\.[0-9]+ ]]; then
		_pass "Electron runtime: v${ver#v} ($electron_path)"
	else
		_pass "Electron runtime: present and executable ($electron_path)"
	fi
}

#------------------------------------------------------------------------------
# chrome-sandbox — must be setuid-root (4755, owner root) on deb/rpm so Electron
# runs sandboxed. Absent on AppImage (which launches with --no-sandbox). A
# sandbox that lost its setuid bit makes Electron refuse to start or run
# unsandboxed, so a clean "all passed" without this check is misleading.
#------------------------------------------------------------------------------
_doctor_check_sandbox() {
	local electron_path="${1:-}"
	# AppImages launch with --no-sandbox (squashfs can't carry a setuid bit), so
	# the bundled chrome-sandbox is intentionally not setuid there. The AppImage
	# runtime exports APPIMAGE; treat that as "sandbox perms don't apply".
	if [[ -n ${APPIMAGE:-} ]]; then
		_info 'chrome-sandbox: AppImage runs with --no-sandbox (setuid not required)'
		return
	fi
	local sandbox_path=''
	[[ -n $electron_path ]] && sandbox_path="$(dirname "$electron_path")/chrome-sandbox"
	if [[ -z $sandbox_path || ! -f $sandbox_path ]]; then
		_warn 'chrome-sandbox: not found (expected for AppImage / --no-sandbox)'
		return
	fi
	local perms owner
	perms=$(stat -c '%a' "$sandbox_path" 2>/dev/null || echo '?')
	owner=$(stat -c '%U' "$sandbox_path" 2>/dev/null || echo '?')
	if [[ $perms == '4755' && $owner == 'root' ]]; then
		_pass "chrome-sandbox: setuid-root OK ($sandbox_path)"
	else
		_fail "chrome-sandbox: perms=$perms owner=$owner (need 4755 root)"
		_info 'Electron may refuse to start or run unsandboxed.'
		_info "Fix: sudo chown root:root '$sandbox_path'"
		_info "     sudo chmod 4755 '$sandbox_path'"
	fi
}

#------------------------------------------------------------------------------
# Desktop entry + free disk on the config partition — cheap install-integrity
# checks. Out-of-disk is a known Chromium failure mode (blank window / profile
# corruption) that is otherwise invisible.
#------------------------------------------------------------------------------
# Args (test seam): application dirs to search; default is the system +
# user XDG locations. Known filenames cover the deb/rpm makers
# (wispr-flow.desktop), the AUR AppImage package (wispr-flow-appimage.desktop),
# and the upstream app id (ai.wisprflow.WisprFlow.desktop) used by AppImage
# desktop integration.
# shellcheck disable=SC2120  # args are an optional test seam; prod uses the
# default dir list, tests/doctor.bats drives it with fixture dirs.
_doctor_check_desktop_entry() {
	local -a names=(
		'wispr-flow.desktop'
		'wispr-flow-appimage.desktop'
		'ai.wisprflow.WisprFlow.desktop'
	)
	local -a dirs
	if (($#)); then
		dirs=("$@")
	else
		dirs=(
			'/usr/share/applications'
			'/usr/local/share/applications'
			"${XDG_DATA_HOME:-$HOME/.local/share}/applications"
		)
	fi
	local d n
	for d in "${dirs[@]}"; do
		for n in "${names[@]}"; do
			if [[ -f "$d/$n" ]]; then
				_pass "Desktop entry: $d/$n"
				return
			fi
		done
	done
	_warn 'Desktop entry: none found (expected for portable AppImage runs)'
	_info "Looked for: ${names[*]}"
}

_doctor_check_disk_space() {
	local config_dir avail
	config_dir="$(_doctor_config_dir)"
	avail=$(df -BM --output=avail "$config_dir" 2>/dev/null \
		| tail -1 | tr -d ' M') || true
	[[ $avail =~ ^[0-9]+$ ]] || return 0
	if ((avail < 100)); then
		_fail "Disk space: ${avail}MB free on the config partition"
		_info 'Chromium will fail to write its profile. Fix: free up disk space.'
	elif ((avail < 500)); then
		_warn "Disk space: ${avail}MB free on the config partition (low)"
	else
		_pass "Disk space: ${avail}MB free on the config partition"
	fi
}

#===============================================================================
# Entry point.
# Arguments: $1 = path to the Linux helper binary (helper check).
#            $2 = path to the Electron runtime binary (runtime / sandbox checks
#                 derive the install dir from it). Both optional but recommended.
#===============================================================================
run_doctor() {
	local helper_path="${1:-}"
	local electron_path="${2:-}"
	local _doctor_failures=0
	_doctor_colors

	local arch
	arch=$(uname -m 2>/dev/null || echo 'unknown')
	local session="${XDG_SESSION_TYPE:-unknown}"
	local desktop="${XDG_CURRENT_DESKTOP:-unknown}"

	echo -e "${_bold}Wispr Flow Diagnostics${_reset}"
	echo '=========================='
	echo "Session: $session   Desktop: $desktop   Arch: $arch"
	if [[ -n $helper_path && -x $helper_path ]]; then
		echo "Helper:  $helper_path"
	fi
	echo

	echo -e "${_bold}Display / Session${_reset}"
	_doctor_check_display
	echo

	echo -e "${_bold}Text Injection (uinput)${_reset}"
	_doctor_check_uinput
	_doctor_check_input_group
	echo

	echo -e "${_bold}Push-to-Talk (input monitor)${_reset}"
	_doctor_check_input_read
	_doctor_check_capture_liveness
	echo

	echo -e "${_bold}Clipboard${_reset}"
	_doctor_check_clipboard
	echo

	echo -e "${_bold}Accessibility (AT-SPI)${_reset}"
	_doctor_check_atspi
	echo

	# GNOME-only section: skip the header entirely off GNOME to avoid a
	# confusing empty block (KDE/wlroots use the in-process KWin/AT-SPI
	# bridges instead of the Shell extension).
	if [[ ${desktop,,} == *gnome* ]]; then
		echo -e "${_bold}GNOME Window Bridge${_reset}"
		_doctor_check_gnome_extension
		echo
	fi

	echo -e "${_bold}Helper & Runtime${_reset}"
	_doctor_check_helper "$helper_path"
	_doctor_check_electron "$electron_path"
	_doctor_check_sandbox "$electron_path"
	_doctor_check_desktop_entry
	_doctor_check_disk_space
	_doctor_check_singleton_lock
	_doctor_check_recent_crashes
	echo

	if ((_doctor_failures == 0)); then
		echo -e "${_green}${_bold}All checks passed.${_reset}"
	else
		echo -e "${_red}${_bold}${_doctor_failures} check(s) failed.${_reset}"
		echo 'See above for fixes.'
	fi

	return "$_doctor_failures"
}
