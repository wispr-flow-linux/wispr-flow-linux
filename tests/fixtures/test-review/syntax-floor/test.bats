@test "linux-autostart: patched bundle still parses" {
	cp "$FIXTURES/main.js" "$TEST_TMP/main.js"
	bash scripts/patches/linux-autostart.sh "$TEST_TMP"
	node --check "$TEST_TMP/main.js"
}
