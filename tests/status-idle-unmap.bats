#!/usr/bin/env bats
# Fail-closed patch contracts and renderer semantics, independent of a desktop.
setup() {
	PATCH_DIR="$BATS_TEST_DIRNAME/../scripts/patches"
	FIX="$BATS_TEST_TMPDIR/bundle.js"
}

main_fixture() {
	cat > "$FIX" <<'JS'
const e={ReportAlphaCatchRects:"status:reportAlphaCatchRects"};
e.ReportAlphaCatchRects="status:reportAlphaCatchRects";
const r={title:"Flow Status Indicator",webPreferences:{preload:require("path").resolve(__dirname,"..","renderer","status","preload.js"),backgroundThrottling:!1}};
JS
}

@test "idle-unmap refuses missing Status contract without changing bundle" {
	printf 'const unrelated = 1;\n' > "$FIX"
	cp "$FIX" "$FIX.before"
	run bash "$PATCH_DIR/linux-status-idle-unmap.sh" "$FIX"
	[[ $status -ne 0 ]]
	cmp "$FIX.before" "$FIX"
}

@test "idle-unmap is byte-identical on a second application" {
	main_fixture
	bash "$PATCH_DIR/linux-status-idle-unmap.sh" "$FIX"
	cp "$FIX" "$FIX.before"
	bash "$PATCH_DIR/linux-status-idle-unmap.sh" "$FIX"
	cmp "$FIX.before" "$FIX"
}

@test "surface-report reports the idle pill and the initial empty scan on Linux" {
	cp "$BATS_TEST_DIRNAME/fixtures/status-surface.js" "$FIX"
	bash "$PATCH_DIR/linux-status-surface-report.sh" "$FIX"
	# Execute the actual patched collector with an empty DOM. No pixel polling.
	run node "$BATS_TEST_DIRNAME/status-surface-test.cjs" "$FIX"
	[[ $status -eq 0 ]]
}

@test "surface-report is byte-identical on a second application" {
	cp "$BATS_TEST_DIRNAME/fixtures/status-surface.js" "$FIX"
	bash "$PATCH_DIR/linux-status-surface-report.sh" "$FIX"
	cp "$FIX" "$FIX.before"
	bash "$PATCH_DIR/linux-status-surface-report.sh" "$FIX"
	cmp "$FIX.before" "$FIX"
}

@test "surface-report rejects unrelated renderer without modifying it" {
	printf 'const renderer = "unrelated";\n' > "$FIX"
	cp "$FIX" "$FIX.before"
	run bash "$PATCH_DIR/linux-status-surface-report.sh" "$FIX"
	[[ $status -ne 0 ]]
	cmp "$FIX.before" "$FIX"
}
