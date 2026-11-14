@test "apparmor: warns when the profile is not loaded" {
	printf 'firefox (enforce)\n' > "$TEST_TMP/loaded"
	run _doctor_check_apparmor "$TEST_TMP/loaded"
	[[ $output == *'[WARN]'* ]]
}
