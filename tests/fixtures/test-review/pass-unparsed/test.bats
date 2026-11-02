@test "password store: reports the configured store" {
	printf 'password-store=gnome-libsecret\n' > "$TEST_TMP/conf"
	run _doctor_check_password_store "$TEST_TMP/conf"
	[[ $output == '[PASS] Password store: gnome-libsecret' ]]
}
