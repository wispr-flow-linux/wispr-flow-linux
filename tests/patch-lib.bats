#!/usr/bin/env bats
#
# patch-lib.bats -- scripts/patches/_lib.sh, the shell every patch shares:
# bundle resolution and usage, the marker guard, the pristine backup, the
# post-patch marker and shape checks that restore on a miss, and the node
# syntax check. Driven through a throwaway patch script built per test so
# the exit statuses and messages the real patches (and linux-patches.bats)
# rely on are pinned here once.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIB="$SCRIPT_DIR/../scripts/patches/_lib.sh"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	FIX="$TEST_TMP/bundle.js"
	printf 'var a=1;\n' > "$FIX"
}

teardown() {
	rm -rf "$TEST_TMP"
}

# A patch script whose body is $1 (shell run after patch_begin), ending in
# patch_verify_marker and patch_finish like the real ones.
_patch_script() {
	local body="$1" script="$TEST_TMP/patch.sh"
	cat > "$script" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$LIB"
patch_begin "WISPR_TEST_MARKER" "\${1:-}"
$body
patch_verify_marker
patch_finish "the test patch applied to \$BUNDLE"
SH
	echo "$script"
}

@test "patch_begin: no bundle argument and no default is usage, exit 2" {
	script=$(_patch_script '')
	run bash "$script"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *'usage:'* ]]
}

@test "patch_begin: a default path is resolved against the repo root" {
	# The default is relative to the repo root (two levels above _lib.sh),
	# whatever the caller's cwd is.
	cat > "$TEST_TMP/patch.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$LIB"
patch_begin "WISPR_TEST_MARKER" "" "no/such/bundle.js"
SH
	run bash "$TEST_TMP/patch.sh"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *"bundle not found: $(cd "$SCRIPT_DIR/.." && pwd)/no/such/bundle.js"* ]]
}

@test "patch_begin: a missing bundle is an error, exit 1" {
	script=$(_patch_script '')
	run bash "$script" "$TEST_TMP/nope.js"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'bundle not found'* ]]
}

@test "patch_begin: the marker guard exits 0 before any backup is written" {
	printf 'var a=1;/*WISPR_TEST_MARKER*/\n' > "$FIX"
	script=$(_patch_script 'echo "body ran"')
	run bash "$script" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'Already patched (WISPR_TEST_MARKER present in'* ]]
	[[ "$output" != *'body ran'* ]]
	[[ ! -f "$FIX.orig" ]]
}

@test "patch_begin: writes the pristine .orig once and never overwrites it" {
	script=$(_patch_script 'printf "%s/*WISPR_TEST_MARKER*/\n" "$(cat "$BUNDLE")" > "$BUNDLE"')
	run bash "$script" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *"Backup written: $FIX.orig"* ]]
	cmp -s "$FIX.orig" <(printf 'var a=1;\n')
	# a second patch on the same bundle keeps the first backup
	sed -i 's/WISPR_TEST_MARKER/WISPR_OTHER/' "$FIX"
	run bash "$script" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$output" != *'Backup written'* ]]
	cmp -s "$FIX.orig" <(printf 'var a=1;\n')
}

@test "patch_verify_marker: a body that leaves no marker restores and exits 1" {
	script=$(_patch_script 'printf "var a=2;\n" > "$BUNDLE"')
	run bash "$script" "$FIX"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'post-patch verification failed (marker not found)'* ]]
	cmp -s "$FIX" <(printf 'var a=1;\n')
}

@test "patch_expect_shape: a miss names the message, restores and exits 1" {
	script=$(_patch_script 'printf "var a=1;/*WISPR_TEST_MARKER*/\n" > "$BUNDLE"
patch_expect_shape -qF "never here" -- "widened thing not in expected form."')
	run bash "$script" "$FIX"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'ERROR: widened thing not in expected form. Restoring backup.'* ]]
	cmp -s "$FIX" <(printf 'var a=1;\n')
}

@test "patch_expect_shape: a hit passes the grep options through" {
	script=$(_patch_script 'printf "var a=1;/*WISPR_TEST_MARKER*/x\n" > "$BUNDLE"
patch_expect_shape -qE "MARKER\\*/x\$" -- "unused"')
	run bash "$script" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'OK: the test patch applied to'* ]]
}

@test "patch_finish: a body that breaks the syntax restores and exits 1" {
	command -v node >/dev/null || skip "node not installed"
	script=$(_patch_script 'printf "var a=(;/*WISPR_TEST_MARKER*/\n" > "$BUNDLE"')
	run bash "$script" "$FIX"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'node --check failed on patched bundle. Restoring backup.'* ]]
	cmp -s "$FIX" <(printf 'var a=1;\n')
}

@test "patch_finish: prints node --check OK then the OK line" {
	command -v node >/dev/null || skip "node not installed"
	script=$(_patch_script 'printf "var a=1;/*WISPR_TEST_MARKER*/\n" > "$BUNDLE"')
	run bash "$script" "$FIX"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'node --check OK'*"OK: the test patch applied to $FIX"* ]]
}
