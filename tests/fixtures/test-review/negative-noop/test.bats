@test "cleanup: no pkill sweep outside CI" {
	unset CI
	pkill() { printf '%s\n' "$*" >> "$TEST_TMP/kills"; }
	touch "$TEST_TMP/kills"
	run_launch_cleanup '/usr/lib/wispr-flow' 12345
	! grep -qF -- '-KILL' "$TEST_TMP/kills"
	[[ -f $TEST_TMP/kills ]]
}
