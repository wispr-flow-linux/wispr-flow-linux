#!/usr/bin/env bats
#
# check-upstream-tripwires.bats -- scripts/check-upstream-tripwires.sh over a
# hand-built .webpack/ tree and a hand-built tripwire table: exact and
# at-least counts, fixed and regex kinds, the renderer/* file spec that
# mirrors the step 3 driver's grep filter, CHANGED lines named by patch and
# label, a missing file, and the usage and table errors. The shipped table
# is checked for shape only; its counts are pinned against the real bundle
# by tests/test-patch-stage.sh.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/check-upstream-tripwires.sh"
SHIPPED="$SCRIPT_DIR/../scripts/patches/tripwires.tsv"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	ROOT="$TEST_TMP/.webpack"
	TABLE="$TEST_TMP/tripwires.tsv"
	mkdir -p "$ROOT/main" "$ROOT/renderer/hub" "$ROOT/renderer/status" \
		"$ROOT/renderer/vendor"
	printf 'l().info("Running Dev Mac Helper service");x.y.isFlag;x.y.isFlag;\n' \
		> "$ROOT/main/index.js"
	printf 'a?.platform?.isWindows??!1;classList.add(window.electron.platform.os)\n' \
		> "$ROOT/renderer/hub/index.js"
	printf 'b?.platform?.isWindows??!1;b?.platform?.isWindows??!1\n' \
		> "$ROOT/renderer/status/index.js"
	printf 'nothing platform-related here\n' > "$ROOT/renderer/vendor/index.js"
}

teardown() {
	rm -rf "$TEST_TMP"
}

# Write $TABLE from lines given as "patch|file|kind|expected|label|pattern"
# (| for readability; the table itself is tab-separated).
_table() {
	local line
	: > "$TABLE"
	for line in "$@"; do
		printf '%s\n' "$line" | tr '|' '\t' >> "$TABLE"
	done
}

@test "every line matches: one OK per file checked, exit 0" {
	_table '# a comment' \
		'p1|main|F|1|the dev-mac line|Running Dev Mac Helper service' \
		'p1|main|P|2|the flag reads|[\w$]+\.[\w$]+\.isFlag' \
		'p2|renderer/hub|F|1|the class add|classList.add(window.electron.platform.os)' \
		'p3|renderer/*|F|1+|the per-renderer bind|platform?.isWindows??!1'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'OK       p1: the dev-mac line (1 in main/index.js)'* ]]
	[[ "$output" == *'OK       p1: the flag reads (2 in main/index.js)'* ]]
	[[ "$output" == *'OK       p2: the class add (1 in renderer/hub/index.js)'* ]]
	# renderer/* is every renderer that reads platform?.isWindows: hub and
	# status, not vendor
	[[ "$output" == *'OK       p3: the per-renderer bind (1 in renderer/hub/index.js)'* ]]
	[[ "$output" == *'OK       p3: the per-renderer bind (2 in renderer/status/index.js)'* ]]
	[[ "$output" != *'vendor'* ]]
	[[ "$output" == *'TRIPWIRES: all 5 checks match upstream.'* ]]
}

@test "an exact count off by one is CHANGED, named by patch and label, exit 1" {
	_table 'p1|main|F|2|the dev-mac line|Running Dev Mac Helper service' \
		'p1|main|F|1|the flag property|isFlag'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'CHANGED  p1: the dev-mac line: expected 2, found 1 in main/index.js'* ]]
	[[ "$output" == *'CHANGED  p1: the flag property: expected 1, found 2 in main/index.js'* ]]
	[[ "$output" == *'TRIPWIRES: 2 of 2 changed.'* ]]
	[[ "$output" == *'re-audit before re-anchoring'* ]]
}

@test "an at-least count is satisfied above the floor and CHANGED below it" {
	_table 'p1|main|F|2+|the flag property|isFlag' \
		'p1|main|F|3+|the flag property again|isFlag'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'OK       p1: the flag property (2 in main/index.js)'* ]]
	[[ "$output" == *'CHANGED  p1: the flag property again: expected 3+, found 2 in main/index.js'* ]]
}

@test "a zero count is a tripwire too: the literal appearing is CHANGED" {
	_table 'p1|main|F|0|no upstream linux arm|Running Dev Mac Helper service'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'CHANGED  p1: no upstream linux arm: expected 0, found 1'* ]]
}

@test "F counts the string literally; the same text as a regex would differ" {
	# The `?` and `.` in the bind are literal under F. Under P `?` makes the
	# preceding char optional, so a P line with the F text counts differently.
	_table 'p3|renderer/hub|F|1|literal|platform?.isWindows??!1' \
		'p3|renderer/hub|P|1|regex|platform\?\.isWindows\?\?!1'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 0 ]]
	[[ "$output" == *'TRIPWIRES: all 2 checks match upstream.'* ]]
}

@test "a file a line names that is missing is CHANGED, not skipped" {
	_table 'p2|renderer/overlay|F|1|the overlay bind|isWindows'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *'CHANGED  p2: the overlay bind: missing renderer/overlay/index.js'* ]]
}

@test "renderer/* with no renderer reading isWindows is CHANGED" {
	rm "$ROOT/renderer/hub/index.js" "$ROOT/renderer/status/index.js"
	_table 'p3|renderer/*|F|1+|the per-renderer bind|platform?.isWindows??!1'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 1 ]]
	[[ "$output" == *"CHANGED  p3: the per-renderer bind: no file matches 'renderer/*'"* ]]
}

@test "usage: no root or a missing root exits 2 with the usage text" {
	run bash "$CHECK"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *'Usage:'* ]]
	run bash "$CHECK" "$TEST_TMP/nowhere"
	[[ "$status" -eq 2 ]]
}

@test "a bad kind, a bad count, an unknown file spec or an empty table exits 2" {
	_table 'p1|main|X|1|bad kind|isFlag'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *"bad kind 'X'"* ]]
	_table 'p1|main|F|one|bad count|isFlag'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *"bad expected count 'one'"* ]]
	_table 'p1|preload|F|1|bad spec|isFlag'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *"unknown file spec 'preload'"* ]]
	_table '# only a comment'
	run bash "$CHECK" "$ROOT" "$TABLE"
	[[ "$status" -eq 2 ]]
	[[ "$output" == *'no tripwires in'* ]]
}

@test "the shipped table is well-formed and names only existing patches" {
	local patch spec kind expected label pattern
	while IFS=$'\t' read -r patch spec kind expected label pattern; do
		[[ -z $patch || $patch == \#* ]] && continue
		[[ $patch == upstream || -f "$SCRIPT_DIR/../scripts/patches/$patch.sh" ]]
		[[ $spec == main || $spec == 'renderer/*' || $spec == renderer/?* ]]
		[[ $kind == F || $kind == P ]]
		[[ $expected =~ ^[0-9]+\+?$ ]]
		[[ -n $label && -n $pattern ]]
	done < "$SHIPPED"
	# every patch that carries a marker has at least one tripwire
	local f name
	for f in "$SCRIPT_DIR"/../scripts/patches/*.sh; do
		name=$(basename "$f" .sh)
		[[ $name == _lib ]] && continue
		grep -q "^$name	" "$SHIPPED"
	done
}
