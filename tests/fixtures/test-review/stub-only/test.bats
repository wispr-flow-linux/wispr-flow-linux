@test "uinput: a 0600 node fails" {
	stat() { [[ $2 == '%a' ]] && echo 600; }
	run _doctor_check_uinput_perms
	[[ $output == *'[FAIL] /dev/uinput mode is 600'* ]]
}
