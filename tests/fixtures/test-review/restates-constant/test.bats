@test "tripwires: the helper-resolver count is 1" {
	run awk -F '\t' '$1 == "helper-resolver" { print $4 }' \
		scripts/patches/tripwires.tsv
	[[ $output == 1 ]]
}
