#!/usr/bin/env bats
# Fail-closed injection contract for the Status input shim.
setup() {
	PATCH_DIR="$BATS_TEST_DIRNAME/../scripts/patches"
	FIX="$BATS_TEST_TMPDIR/bundle.js"
}

main_fixture() {
	cat > "$FIX" <<'JS'
/*! For license information please see main.js.LICENSE.txt */
const w={title:"Flow Status Indicator"};
const report="status:reportAlphaCatchRects";
const show="notification:show";
const clear="notification:clear";
JS
}

@test "status-input: injects the shim after the license banner" {
	main_fixture
	run bash "$PATCH_DIR/linux-status-input.sh" "$FIX"
	[[ $status -eq 0 ]]
	grep -qF 'WISPR_LINUX_STATUS_INPUT' "$FIX"
	[[ "$(head -1 "$FIX")" == '/*! For license information please see main.js.LICENSE.txt */' ]]
	node --check "$FIX"
}

@test "status-input: is byte-identical on a second application" {
	main_fixture
	bash "$PATCH_DIR/linux-status-input.sh" "$FIX"
	cp "$FIX" "$FIX.before"
	bash "$PATCH_DIR/linux-status-input.sh" "$FIX"
	cmp "$FIX.before" "$FIX"
}

@test "status-input: refuses a bundle missing the surface report channel" {
	printf 'const w={title:"Flow Status Indicator"};const show="notification:show";const clear="notification:clear";\n' > "$FIX"
	cp "$FIX" "$FIX.before"
	run bash "$PATCH_DIR/linux-status-input.sh" "$FIX"
	[[ $status -ne 0 ]]
	cmp "$FIX.before" "$FIX"
}

@test "status-input: refuses a bundle missing the Status title" {
	printf 'const report="status:reportAlphaCatchRects";const show="notification:show";const clear="notification:clear";\n' > "$FIX"
	cp "$FIX" "$FIX.before"
	run bash "$PATCH_DIR/linux-status-input.sh" "$FIX"
	[[ $status -ne 0 ]]
	cmp "$FIX.before" "$FIX"
}
