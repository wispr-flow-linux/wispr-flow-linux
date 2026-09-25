@test "disk: plenty of space passes" {
	df() { printf 'Avail\n9000M\n'; }
	run _doctor_check_disk
	[[ $output == *'[PASS] free space: 9000M'* ]]
}
