#!/usr/bin/env bash
# Integration tests for Wispr Flow .deb artifacts.
#
# Two tiers:
#   1. Inspection (always runs, no install): metadata via `dpkg-deb -I`,
#      file-list / FHS placement and launcher content via `dpkg-deb -c` /
#      `dpkg-deb -x`, and the wl-clipboard Depends.
#   2. Install + smoke (CI only): `dpkg -i`, on-disk checks, --doctor, and a
#      headless launch. Skipped with a clear message when not root or tooling
#      is missing.

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
_deb_cleanup() {
	_launch_smoke_cleanup
	[[ -n ${dx_tmp:-} ]] && rm -rf "$dx_tmp"
}
trap _deb_cleanup EXIT INT TERM

deb_file=$(find "$artifact_dir" -name '*.deb' -type f | head -1)
if [[ -z $deb_file ]]; then
	fail "No .deb file found in $artifact_dir"
	print_summary
fi
pass "Found deb: $(basename "$deb_file")"

if ! command -v dpkg-deb &>/dev/null; then
	pass "Skipping deb inspection (dpkg-deb not available)"
	print_summary
fi

# === Tier 1: inspection (no install) ========================================

pkg_info=$(dpkg-deb -I "$deb_file" 2>/dev/null)
if [[ $pkg_info == *'Package: wispr-flow'* ]]; then
	pass "Package name is wispr-flow"
else
	fail "Package name is not wispr-flow"
fi
if [[ $pkg_info == *'Version:'* ]]; then
	pass "Version field present"
else
	fail "Version field missing"
fi
if [[ $pkg_info == *'Architecture:'* ]]; then
	pass "Architecture field present"
else
	fail "Architecture field missing"
fi
# wl-clipboard is a hard Depends (Wayland paste/selection).
if [[ $pkg_info == *'Depends:'*'wl-clipboard'* ]]; then
	pass "Depends on wl-clipboard"
else
	fail "Missing Depends: wl-clipboard"
fi

# File list / FHS placement from the package contents.
file_list=$(dpkg-deb -c "$deb_file" 2>/dev/null)
for path in \
	'/usr/bin/wispr-flow' \
	'/usr/lib/wispr-flow/launcher-common.sh' \
	'/usr/lib/wispr-flow/doctor.sh' \
	'/usr/lib/wispr-flow/wispr-flow' \
	'/usr/lib/wispr-flow/chrome-sandbox' \
	'/usr/lib/wispr-flow/resources/app.asar' \
	'/usr/lib/wispr-flow/resources/Release/wispr-flow-linux-helper' \
	'/usr/share/applications/wispr-flow.desktop'
do
	# dpkg-deb -c prints './usr/...'; match the tail of the line.
	if grep -qE "(^|[[:space:]])\.${path}\$" <<< "$file_list"; then
		pass "Packaged: $path"
	else
		fail "Not packaged: $path"
	fi
done

# udev rule ships in the package (installed into /usr/lib/udev by postinst).
if grep -qE '70-wispr-flow-uinput\.rules' <<< "$file_list"; then
	pass "Packaged: uinput udev rule"
else
	fail "Not packaged: uinput udev rule"
fi

# At least one hicolor icon.
if grep -qE '/usr/share/icons/hicolor/.*/apps/wispr-flow\.(png|svg)' \
	<<< "$file_list"; then
	pass "Icon installed under hicolor"
else
	fail "No hicolor icon in package"
fi

# Launcher script content + sandbox flag (extract without installing).
dx_tmp=$(mktemp -d)
if dpkg-deb -x "$deb_file" "$dx_tmp" 2>/dev/null; then
	launcher="$dx_tmp/usr/bin/wispr-flow"
	assert_contains "$launcher" 'launcher-common.sh' \
		"Launcher sources launcher-common.sh"
	assert_contains "$launcher" 'run_doctor' \
		"Launcher references run_doctor"
	assert_contains "$launcher" 'build_electron_args' \
		"Launcher calls build_electron_args"
	# Ignore comment lines (the launcher mentions --no-sandbox in a header
	# comment); only an actual flag in executable code is a problem.
	if grep -vE '^[[:space:]]*#' "$launcher" | grep -q -- '--no-sandbox'; then
		fail "deb launcher unexpectedly passes --no-sandbox"
	else
		pass "deb launcher does not pass --no-sandbox (setuid sandbox path)"
	fi
	# Validate desktop file syntax if the tool is available.
	desktop_file="$dx_tmp/usr/share/applications/wispr-flow.desktop"
	assert_contains "$desktop_file" 'Exec=wispr-flow' "Desktop entry Exec correct"
	assert_contains "$desktop_file" 'StartupWMClass=Wispr Flow' \
		"Desktop entry StartupWMClass correct"
	if command -v desktop-file-validate &>/dev/null; then
		assert_command_succeeds "desktop-file-validate passes" \
			desktop-file-validate "$desktop_file"
	fi
	# Verify the patched app.asar carries the Linux markers (no install).
	validate_app_contents "$dx_tmp/usr/lib/wispr-flow/resources"
else
	pass "Skipping extract-based checks (dpkg-deb -x failed)"
fi

# === Tier 2: install + smoke (CI only) ======================================
#
# Opt-in (see test-artifact-rpm.sh): installing the package modifies the
# system, so it runs ONLY when WISPR_ARTIFACT_INSTALL=1 AND we are root with
# dpkg available. Local runs never reach it.
if [[ ${WISPR_ARTIFACT_INSTALL:-0} != 1 ]]; then
	pass "Skipping install/smoke (set WISPR_ARTIFACT_INSTALL=1 in CI to enable)"
	print_summary
fi
if [[ $(id -u) -ne 0 ]] || ! command -v dpkg &>/dev/null; then
	pass "Skipping install/smoke (not root or dpkg missing; inspection only)"
	print_summary
fi

if dpkg -i --force-depends "$deb_file"; then
	pass "dpkg -i succeeded"
else
	fail "dpkg -i failed"
	print_summary
fi

assert_executable '/usr/bin/wispr-flow'
assert_file_exists '/usr/share/applications/wispr-flow.desktop'
assert_dir_exists '/usr/lib/wispr-flow'

electron_bin='/usr/lib/wispr-flow/wispr-flow'
assert_file_exists "$electron_bin"
assert_executable "$electron_bin"
assert_file_exists '/usr/lib/wispr-flow/chrome-sandbox'

doctor_exit=0
/usr/bin/wispr-flow --doctor >/dev/null 2>&1 || doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# A Debian/Ubuntu CI runner is typically non-root, but if this tier runs it's
# root, so drop privileges for the launch (setuid sandbox, no --no-sandbox).
smoke_user=''
if command -v useradd &>/dev/null && command -v runuser &>/dev/null; then
	smoke_user='wispr-smoke'
	useradd -m "$smoke_user" 2>/dev/null || smoke_user=''
fi
run_launch_smoke_test 'deb package' '/usr/lib/wispr-flow' "$smoke_user" \
	/usr/bin/wispr-flow

print_summary
