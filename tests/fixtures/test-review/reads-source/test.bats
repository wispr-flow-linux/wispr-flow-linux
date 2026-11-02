@test "mac-gates: gates the Applications-folder guard to darwin" {
	run grep -c 'process.platform==="darwin"' scripts/patches/mac-gates.sh
	[[ $output -ge 1 ]]
}
