@test "helper: passes and reports the probed version" {
	printf '#!/bin/sh\necho "wispr-flow-linux-helper 1.2.3"\n' > "$TEST_TMP/helper"
	chmod +x "$TEST_TMP/helper"
	HELPER_BIN="$TEST_TMP/helper"
	run _doctor_check_helper
	[[ $output == '[PASS] helper: wispr-flow-linux-helper 1.2.3' ]]
}
