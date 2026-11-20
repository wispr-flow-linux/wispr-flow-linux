@test "clipboard: missing wl-copy fails and counts" {
	_hide_commands wl-copy
	_doctor_failures=0
	run _doctor_check_clipboard
	[[ $output == *"[FAIL] wl-copy not found"* ]]
	_doctor_check_clipboard >/dev/null
	[[ $_doctor_failures -eq 1 ]]
}
