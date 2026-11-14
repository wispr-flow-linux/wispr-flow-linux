@test "sandbox: a real 0755 file fails with its mode" {
	touch "$TEST_TMP/chrome-sandbox"
	chmod 0755 "$TEST_TMP/chrome-sandbox"
	run _doctor_check_sandbox "$TEST_TMP/chrome-sandbox"
	[[ $output == *'[FAIL] chrome-sandbox mode is 755, want 4755'* ]]
}

@test "sandbox: an unreadable path warns instead of passing" {
	run _doctor_check_sandbox "$TEST_TMP/missing"
	[[ $output == *'[WARN] cannot read the mode'* ]]
}

@test "sandbox: setuid root passes (stubbed: a test cannot chown root)" {
	stat() { echo 4755; }
	run _doctor_check_sandbox /opt/wispr-flow/chrome-sandbox
	[[ $output == *'[PASS] chrome-sandbox is setuid root'* ]]
}
