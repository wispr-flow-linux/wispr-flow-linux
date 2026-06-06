#!/usr/bin/env bash
# Integration tests for Wispr Flow .rpm artifacts.
#
# Two tiers:
#   1. Inspection (always runs, no install, safe on any box): metadata,
#      file-list / FHS placement via `rpm -qlp`, runtime deps via
#      `rpm -qp --requires`, and the launcher script content pulled out of
#      the package without installing.
#   2. Install + smoke (CI containers only): `rpm -i`, on-disk file checks,
#      setuid chrome-sandbox, --doctor, and a headless launch. Skipped (with
#      a clear message) when not root, or when rpm tooling is missing.

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT/INT/TERM trap
_rpm_cleanup() {
	_launch_smoke_cleanup
	[[ -n ${smoke_user:-} ]] && userdel -r "$smoke_user" 2>/dev/null
	[[ -n ${qlp_tmp:-} ]] && rm -rf "$qlp_tmp"
}
trap _rpm_cleanup EXIT INT TERM

# Find the .rpm file (search recursively; build-linux nests it under rpmbuild).
rpm_file=$(find "$artifact_dir" -name '*.rpm' -type f | head -1)
if [[ -z $rpm_file ]]; then
	fail "No .rpm file found in $artifact_dir"
	print_summary
fi
pass "Found rpm: $(basename "$rpm_file")"

if ! command -v rpm &>/dev/null; then
	pass "Skipping rpm inspection (rpm tool not available)"
	print_summary
fi

# === Tier 1: inspection (no install) ========================================

rpm_info=$(rpm -qip "$rpm_file" 2>/dev/null)
if [[ $rpm_info == *'Name'*'wispr-flow'* ]]; then
	pass "Package name is wispr-flow"
else
	fail "Package name is not wispr-flow"
fi

# Runtime deps: wl-clipboard is a hard Requires (Wayland paste/selection).
requires=$(rpm -qp --requires "$rpm_file" 2>/dev/null)
if [[ $requires == *'wl-clipboard'* ]]; then
	pass "Requires wl-clipboard"
else
	fail "Missing Requires: wl-clipboard"
fi

# File list / FHS placement straight from the package metadata.
file_list=$(rpm -qlp "$rpm_file" 2>/dev/null)
for path in \
	'/usr/bin/wispr-flow' \
	'/usr/lib/wispr-flow/launcher-common.sh' \
	'/usr/lib/wispr-flow/doctor.sh' \
	'/usr/lib/wispr-flow/wispr-flow' \
	'/usr/lib/wispr-flow/chrome-sandbox' \
	'/usr/lib/wispr-flow/resources/app.asar' \
	'/usr/lib/wispr-flow/resources/Release/wispr-flow-linux-helper' \
	'/usr/share/applications/wispr-flow.desktop' \
	'/usr/lib/udev/rules.d/70-wispr-flow-uinput.rules'
do
	if grep -qxF "$path" <<< "$file_list"; then
		pass "Packaged: $path"
	else
		fail "Not packaged: $path"
	fi
done

# At least one hicolor icon.
if grep -qE '/usr/share/icons/hicolor/.*/apps/wispr-flow\.(png|svg)' \
	<<< "$file_list"; then
	pass "Icon installed under hicolor"
else
	fail "No hicolor icon in package"
fi

# Launcher script content (extract /usr/bin/wispr-flow without installing).
qlp_tmp=$(mktemp -d)
if rpm2cpio "$rpm_file" 2>/dev/null \
	| (cd "$qlp_tmp" && cpio -idm './usr/bin/wispr-flow' 2>/dev/null); then
	launcher="$qlp_tmp/usr/bin/wispr-flow"
	assert_contains "$launcher" 'launcher-common.sh' \
		"Launcher sources launcher-common.sh"
	assert_contains "$launcher" 'run_doctor' \
		"Launcher references run_doctor"
	assert_contains "$launcher" 'build_electron_args' \
		"Launcher calls build_electron_args"
	# rpm/deb installs the setuid sandbox, so the launcher must NOT pass
	# --no-sandbox (that's the AppImage path only). Ignore comment lines —
	# the launcher mentions --no-sandbox in a header comment; we care only
	# about an actual flag in executable code.
	if grep -vE '^[[:space:]]*#' "$launcher" | grep -q -- '--no-sandbox'; then
		fail "rpm launcher unexpectedly passes --no-sandbox"
	else
		pass "rpm launcher does not pass --no-sandbox (setuid sandbox path)"
	fi
else
	pass "Skipping launcher-content check (rpm2cpio/cpio unavailable)"
fi

# === Tier 2: install + smoke (CI containers only) ===========================
#
# Opt-in: the install tier modifies the system (it would install the
# proprietary payload), so it runs ONLY when WISPR_ARTIFACT_INSTALL=1 AND we
# are root. CI sets the flag in a throwaway container; local runs never reach
# it even if uid happens to be 0. This is the safety gate that keeps the
# script safe to invoke on a developer box.
if [[ ${WISPR_ARTIFACT_INSTALL:-0} != 1 ]]; then
	pass "Skipping install/smoke (set WISPR_ARTIFACT_INSTALL=1 in CI to enable)"
	print_summary
fi
if [[ $(id -u) -ne 0 ]]; then
	pass "Skipping install/smoke (not root)"
	print_summary
fi

if rpm -ivh --nodeps "$rpm_file"; then
	pass "rpm -ivh succeeded"
else
	fail "rpm -ivh failed"
	print_summary
fi

assert_executable '/usr/bin/wispr-flow'
assert_file_exists '/usr/share/applications/wispr-flow.desktop'
assert_dir_exists '/usr/lib/wispr-flow'
assert_file_exists '/usr/lib/wispr-flow/launcher-common.sh'
assert_file_exists '/usr/lib/wispr-flow/doctor.sh'

electron_bin='/usr/lib/wispr-flow/wispr-flow'
assert_file_exists "$electron_bin"
assert_executable "$electron_bin"

# chrome-sandbox: %attr(4755) in the spec %files — verify the suid bit lands
# on disk (regression guard against reverting to a %post chmod that no-ops
# under --noscripts).
chrome_sandbox='/usr/lib/wispr-flow/chrome-sandbox'
assert_file_exists "$chrome_sandbox"
assert_setuid "$chrome_sandbox"

desktop_file='/usr/share/applications/wispr-flow.desktop'
assert_contains "$desktop_file" 'Exec=wispr-flow' "Desktop entry Exec correct"
assert_contains "$desktop_file" 'Type=Application' "Desktop entry Type correct"
assert_contains "$desktop_file" 'StartupWMClass=Wispr Flow' \
	"Desktop entry StartupWMClass correct"

resources_dir='/usr/lib/wispr-flow/resources'
validate_app_contents "$resources_dir"

# --doctor must run without crashing (some checks fail in CI; that's fine).
doctor_exit=0
/usr/bin/wispr-flow --doctor >/dev/null 2>&1 || doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# Headless launch: drop to an unprivileged user (Electron refuses root with a
# setuid sandbox and no --no-sandbox). The install is world-readable and
# chrome-sandbox is setuid root, so this exercises the real user path.
smoke_user=''
if command -v useradd &>/dev/null; then
	smoke_user='wispr-smoke'
	useradd -m "$smoke_user" 2>/dev/null || smoke_user=''
fi

run_launch_smoke_test 'rpm package' '/usr/lib/wispr-flow' \
	"$smoke_user" /usr/bin/wispr-flow

print_summary
