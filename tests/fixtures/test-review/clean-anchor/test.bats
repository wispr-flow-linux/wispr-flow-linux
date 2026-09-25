@test "apparmor: passes when the profile is loaded" {
	printf 'firefox (enforce)\nwispr-flow-unofficial (enforce)\n' > "$TEST_TMP/loaded"
	run _doctor_check_apparmor "$TEST_TMP/loaded"
	[[ $output == *'[PASS]'* ]]
}

@test "apparmor: a profile with a longer name is not ours" {
	printf 'wispr-flow-unofficial-dev (enforce)\n' > "$TEST_TMP/loaded"
	run _doctor_check_apparmor "$TEST_TMP/loaded"
	[[ $output == *'[WARN]'* ]]
}

@test "apparmor: the name mid-line is not a loaded profile" {
	printf 'other wispr-flow-unofficial (enforce)\n' > "$TEST_TMP/loaded"
	run _doctor_check_apparmor "$TEST_TMP/loaded"
	[[ $output == *'[WARN]'* ]]
}
