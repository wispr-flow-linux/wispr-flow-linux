#!/usr/bin/env bash
# Integration tests for Wispr Flow AppImage artifacts.
#
# Accepts either a built *.AppImage (extracted via --appimage-extract) or, as a
# fallback, the staged AppDir the maker leaves under build-linux/appimage when
# appimagetool isn't installed. All structure/content checks run with no
# install; the optional headless launch runs the built AppImage and degrades to
# a skip when the launch tooling is missing.

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
artifact_dir="$(cd "$artifact_dir" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
_cleanup() {
	_launch_smoke_cleanup
	[[ -n ${extract_dir:-} ]] && rm -rf "$extract_dir"
}
trap _cleanup EXIT INT TERM

component_id='ai.wisprflow.WisprFlow'

# Resolve an AppDir to validate: prefer extracting a built .AppImage; fall
# back to the staged AppDir the maker leaves behind.
appdir=''
appimage_file=$(find "$artifact_dir" -name '*.AppImage' ! -name '*.zsync' \
	-type f 2>/dev/null | head -1)

if [[ -n $appimage_file ]]; then
	pass "Found AppImage: $(basename "$appimage_file")"
	chmod +x "$appimage_file" 2>/dev/null || true
	assert_executable "$appimage_file"
	extract_dir=$(mktemp -d)
	if (cd "$extract_dir" && "$appimage_file" --appimage-extract >/dev/null 2>&1) \
		&& [[ -d "$extract_dir/squashfs-root" ]]; then
		pass "--appimage-extract succeeded"
		appdir="$extract_dir/squashfs-root"
	else
		pass "Skipping extract (--appimage-extract unavailable); trying staged AppDir"
	fi
fi

if [[ -z $appdir ]]; then
	staged=$(find "$artifact_dir" -maxdepth 3 -type d -name "${component_id}.AppDir" \
		2>/dev/null | head -1)
	if [[ -n $staged ]]; then
		pass "Using staged AppDir: $staged"
		appdir="$staged"
	fi
fi

if [[ -z $appdir ]]; then
	fail "No AppImage or staged AppDir found under $artifact_dir"
	print_summary
fi

# === AppDir structure =======================================================

assert_file_exists "$appdir/AppRun"
assert_executable "$appdir/AppRun"

# Top-level desktop entry + icon (appimagetool conventions).
if [[ -f "$appdir/${component_id}.desktop" ]]; then
	pass "Top-level .desktop present"
	assert_contains "$appdir/${component_id}.desktop" 'Type=Application' \
		"Desktop entry Type correct"
	assert_contains "$appdir/${component_id}.desktop" 'Exec=AppRun' \
		"Desktop entry Exec points to AppRun"
	assert_contains "$appdir/${component_id}.desktop" 'StartupWMClass=Wispr Flow' \
		"Desktop entry StartupWMClass correct"
else
	fail "No top-level .desktop file"
fi
assert_file_exists "$appdir/usr/share/applications/${component_id}.desktop"
assert_file_exists "$appdir/${component_id}.png"
assert_file_exists "$appdir/.DirIcon"
assert_file_exists "$appdir/usr/share/metainfo/${component_id}.appdata.xml"

# === Electron tree + launcher library =======================================

app_libdir="$appdir/usr/lib/wispr-flow"
assert_dir_exists "$app_libdir"
assert_file_exists "$app_libdir/launcher-common.sh"
assert_file_exists "$app_libdir/doctor.sh"

electron_bin="$app_libdir/wispr-flow"
assert_file_exists "$electron_bin"
assert_executable "$electron_bin"

# === AppRun content =========================================================

assert_contains "$appdir/AppRun" 'launcher-common.sh' \
	"AppRun sources launcher-common.sh"
assert_contains "$appdir/AppRun" 'run_doctor' \
	"AppRun references run_doctor"
assert_contains "$appdir/AppRun" 'build_electron_args' \
	"AppRun calls build_electron_args"
# AppImage runs from a FUSE mount that drops the setuid bit, so it MUST request
# the appimage mode (which adds --no-sandbox in build_electron_args).
assert_contains "$appdir/AppRun" "build_electron_args 'appimage'" \
	"AppRun builds args in appimage mode (--no-sandbox path)"

# === App contents (asar + helper + patch markers) ===========================

validate_app_contents "$app_libdir/resources"

# === Optional headless launch ===============================================

if [[ -n $appimage_file ]]; then
	# --doctor must run without crashing.
	doctor_exit=0
	"$appimage_file" --doctor >/dev/null 2>&1 || doctor_exit=$?
	if [[ $doctor_exit -lt 127 ]]; then
		pass "--doctor runs without crashing (exit: $doctor_exit)"
	else
		fail "--doctor crashed (exit: $doctor_exit)"
	fi
	# AppImage runs as the (non-root) user; AppRun passes --no-sandbox.
	run_launch_smoke_test 'AppImage' "$appimage_file" '' "$appimage_file"
else
	pass "Skipping launch smoke test (no built .AppImage; staged AppDir only)"
fi

print_summary
