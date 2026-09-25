@test "write: rejects a 63-char sha256 and leaves the pin byte-identical" {
	printf 'VERSION=1\nSHA256=%s\n' "$GOOD_SHA" > "$TEST_TMP/pin"
	cp "$TEST_TMP/pin" "$TEST_TMP/pin.before"
	run write_pin 2 "${GOOD_SHA:0:63}" "$TEST_TMP/pin"
	[[ $status -eq 1 ]]
	[[ $output == *'not a sha256'* ]]
	cmp -s "$TEST_TMP/pin" "$TEST_TMP/pin.before"
}
