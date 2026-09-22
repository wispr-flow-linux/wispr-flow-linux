#!/usr/bin/env bats
#
# test-artifact-common.bats
# Tests for the shared artifact-test harness in tests/test-artifact-common.sh.
#
# run_launch_smoke_test is driven end to end with PATH shims: `setsid`
# stands in for the whole xvfb-run / dbus / launcher tree and writes the
# readiness marker plus a backend line straight into the launcher.log the
# harness polls, and `pkill` records its argv instead of killing anything.
# That lets the tests pin the one decision that can hurt a developer: the
# `pkill -f` sweep must run only under CI, because its pattern also matches
# a live Wispr Flow on the developer's desktop.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	mkdir -p "$TEST_TMP/bin"

	# The harness only checks these exist; the setsid shim never execs them.
	local tool
	for tool in xvfb-run dbus-run-session; do
		printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/$tool"
		chmod +x "$TEST_TMP/bin/$tool"
	done

	# setsid: find the XDG_CACHE_HOME the harness passes through `env`, write
	# the marker and a real backend line where the harness will look, exit.
	cat > "$TEST_TMP/bin/setsid" <<'SHIM'
#!/usr/bin/env bash
cache=''
for arg in "$@"; do
	[[ $arg == XDG_CACHE_HOME=* ]] && cache="${arg#XDG_CACHE_HOME=}"
done
[[ -n $cache ]] || exit 3
mkdir -p "$cache/wispr-flow"
{
	echo '[INFO  wispr_flow_linux_helper::backend] injection: X11 (XTEST)'
	echo 'Helper service is ready: true'
} >> "$cache/wispr-flow/launcher.log"
exit 0
SHIM
	chmod +x "$TEST_TMP/bin/setsid"

	# pkill: log argv, kill nothing.
	cat > "$TEST_TMP/bin/pkill" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PKILL_LOG:?}"
exit 0
SHIM
	chmod +x "$TEST_TMP/bin/pkill"

	export PKILL_LOG="$TEST_TMP/pkill.log"
	export PATH="$TEST_TMP/bin:$PATH"
	unset CI

	# shellcheck source=tests/test-artifact-common.sh
	source "$SCRIPT_DIR/test-artifact-common.sh"
	_pass_count=0
	_fail_count=0
}

teardown() {
	rm -rf "$TEST_TMP"
}

# Write an asar-shaped file: the 16-byte pickle prefix (4, header pickle
# size, header string size, JSON length), the JSON header padded to 4, then
# whatever body bytes follow. Only the JSON length at offset 12 and the
# JSON itself matter to assert_asar_no_patch_backups; the other sizes are
# filled in the way @electron/asar writes them.
_le32() {
	local n="$1"
	printf '%b' "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
		$((n & 255)) $(((n >> 8) & 255)) $(((n >> 16) & 255)) \
		$(((n >> 24) & 255)))"
}

_write_asar() {
	local path="$1" json="$2" body="${3:-}"
	local len=${#json} pad
	pad=$(( (4 - len % 4) % 4 ))
	{
		_le32 4
		_le32 $((8 + len + pad))
		_le32 $((4 + len + pad))
		_le32 "$len"
		printf '%s' "$json"
		head -c "$pad" /dev/zero
		printf '%s' "$body"
	} > "$path"
}

# The shims must carry the harness to its sweep: ready marker read, backend
# read and not stub, no failure. Every sweep test asserts this first so a
# missing pkill line is never mistaken for a guard that worked.
_assert_reached_sweep() {
	[[ $_fail_count -eq 0 ]]
	[[ $_pass_count -eq 2 ]]
}

@test "run_launch_smoke_test: pkill sweep is skipped when CI is unset" {
	run_launch_smoke_test 'shim' 'wispr-flow-live-pattern' '' true
	_assert_reached_sweep
	[[ ! -e $PKILL_LOG ]]
	# The cleanup trap reads the same cleared pattern.
	[[ -z $_smoke_pkill_match ]]
}

@test "run_launch_smoke_test: pkill sweep is skipped when CI is set but empty" {
	export CI=''
	run_launch_smoke_test 'shim' 'wispr-flow-live-pattern' '' true
	_assert_reached_sweep
	[[ ! -e $PKILL_LOG ]]
	[[ -z $_smoke_pkill_match ]]
}

@test "run_launch_smoke_test: pkill sweep runs with the pattern under CI" {
	export CI=true
	run_launch_smoke_test 'shim' 'wispr-flow-live-pattern' '' true
	_assert_reached_sweep
	[[ -f $PKILL_LOG ]]
	grep -qxF -- '-KILL -f wispr-flow-live-pattern' "$PKILL_LOG"
	[[ $(wc -l < "$PKILL_LOG") -eq 1 ]]
	[[ $_smoke_pkill_match == 'wispr-flow-live-pattern' ]]
}

@test "run_launch_smoke_test: an empty pattern sweeps nothing even under CI" {
	export CI=true
	run_launch_smoke_test 'shim' '' '' true
	_assert_reached_sweep
	[[ ! -e $PKILL_LOG ]]
}

@test "run_launch_smoke_test: the backend line is read, a stub backend fails" {
	# Mutate the setsid shim so the helper reports the no-op backend.
	sed -i 's/injection: X11 (XTEST)/injection: stub (no-op)/' \
		"$TEST_TMP/bin/setsid"
	run_launch_smoke_test 'shim' '' '' true
	[[ $_pass_count -eq 1 ]]
	[[ $_fail_count -eq 1 ]]
}

# =============================================================================
# assert_asar_no_patch_backups
# =============================================================================

@test "assert_asar_no_patch_backups: passes on a header with no .orig entry" {
	_write_asar "$TEST_TMP/app.asar" \
		'{"files":{".webpack":{"files":{"main":{"files":{"index.js":{"size":3,"offset":"0"}}}}}}}' \
		'abc'
	run assert_asar_no_patch_backups "$TEST_TMP/app.asar"
	[[ $output == *"[PASS] No patch backups"* ]]
	assert_asar_no_patch_backups "$TEST_TMP/app.asar" >/dev/null
	[[ $_fail_count -eq 0 ]]
	[[ $_pass_count -eq 1 ]]
}

@test "assert_asar_no_patch_backups: fails and names a packed .orig entry" {
	_write_asar "$TEST_TMP/app.asar" \
		'{"files":{"index.js":{"size":1,"offset":"0"},"index.js.orig":{"size":1,"offset":"1"},"index.js.macgate.orig":{"size":1,"offset":"2"}}}' \
		'abc'
	run assert_asar_no_patch_backups "$TEST_TMP/app.asar"
	[[ $output == *'[FAIL] Patch backups packed in'* ]]
	[[ $output == *'"index.js.orig"'* ]]
	[[ $output == *'"index.js.macgate.orig"'* ]]
	assert_asar_no_patch_backups "$TEST_TMP/app.asar" >/dev/null 2>&1
	[[ $_fail_count -eq 1 ]]
	[[ $_pass_count -eq 0 ]]
}

@test "assert_asar_no_patch_backups: a .orig string in a bundle body is not an entry" {
	# Near miss: the name appears past the header, inside file content.
	_write_asar "$TEST_TMP/app.asar" \
		'{"files":{"index.js":{"size":40,"offset":"0"}}}' \
		'const backup = "index.js.orig"; export {};'
	assert_asar_no_patch_backups "$TEST_TMP/app.asar" >/dev/null 2>&1
	[[ $_fail_count -eq 0 ]]
	[[ $_pass_count -eq 1 ]]
}

@test "assert_asar_no_patch_backups: a header that spans past 4 KiB is read whole" {
	# The length field, not a fixed prefix, bounds the read: an entry listed
	# deep in a long header must still be found.
	local filler i json='{"files":{'
	for ((i = 0; i < 300; i++)); do
		json+="\"module-$i-with-a-long-name.js\":{\"size\":1,\"offset\":\"$i\"},"
	done
	json+='"index.js.orig":{"size":1,"offset":"300"}}}'
	[[ ${#json} -gt 8192 ]]
	_write_asar "$TEST_TMP/app.asar" "$json" 'x'
	assert_asar_no_patch_backups "$TEST_TMP/app.asar" >/dev/null 2>&1
	[[ $_fail_count -eq 1 ]]
}

@test "assert_asar_no_patch_backups: an unreadable header is a failure, not a pass" {
	printf 'not an asar' > "$TEST_TMP/app.asar"
	run assert_asar_no_patch_backups "$TEST_TMP/app.asar"
	[[ $output == *'[FAIL] Cannot read the asar header length'* ]]
	assert_asar_no_patch_backups "$TEST_TMP/app.asar" >/dev/null 2>&1
	[[ $_fail_count -eq 1 ]]
	[[ $_pass_count -eq 0 ]]
	run assert_asar_no_patch_backups "$TEST_TMP/no-such.asar"
	[[ $output == *'[FAIL] Cannot read'* ]]
}
