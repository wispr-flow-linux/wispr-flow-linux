@test "config: reports the config dir" {
	run _doctor_check_config
	[[ $output == *"$HOME/.config/Wispr Flow"* ]]
}
