#!/usr/bin/env bats

setup() {
	TEST_TMP=$(mktemp -d)
	local root="$BATS_TEST_DIRNAME/.."
	mkdir -p "$TEST_TMP/scripts/packaging" "$TEST_TMP/bin" \
		"$TEST_TMP/dist/resources/Release"
	cp "$root/scripts/packaging/appimage.sh" "$TEST_TMP/scripts/packaging/"
	cp "$root/scripts/launcher-common.sh" "$root/scripts/doctor.sh" \
		"$TEST_TMP/scripts/"
	touch "$TEST_TMP/dist/resources/app.asar"
	printf '#!/bin/sh\nexit 0\n' > "$TEST_TMP/dist/wispr-flow"
	cp "$TEST_TMP/dist/wispr-flow" \
		"$TEST_TMP/dist/resources/Release/wispr-flow-linux-helper"
	chmod +x "$TEST_TMP/dist/wispr-flow" \
		"$TEST_TMP/dist/resources/Release/wispr-flow-linux-helper"
	cat > "$TEST_TMP/bin/appimagetool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_TMP/args"
touch "${@: -1}"
SH
	chmod +x "$TEST_TMP/bin/appimagetool"
	export TEST_TMP
}

teardown() {
	rm -rf "$TEST_TMP"
}

@test "AppImage updater follows the publishing repository" {
	for repo in srivasv/wispr-flow-linux wispr-flow-linux/wispr-flow-linux; do
		run env PATH="$TEST_TMP/bin:$PATH" GITHUB_ACTIONS=true \
			GITHUB_REPOSITORY="$repo" \
			bash "$TEST_TMP/scripts/packaging/appimage.sh" \
			"$TEST_TMP/dist" 1.0.9 x86_64
		[[ $status -eq 0 ]]
		grep -qxF "gh-releases-zsync|${repo/\//|}|latest|wispr-flow-*-x86_64.AppImage.zsync" "$TEST_TMP/args"
	done
}

@test "Local AppImages carry no release updater metadata" {
	run env PATH="$TEST_TMP/bin:$PATH" GITHUB_ACTIONS=false \
		bash "$TEST_TMP/scripts/packaging/appimage.sh" \
		"$TEST_TMP/dist" 1.0.9 x86_64
	[[ $status -eq 0 ]]
	! grep -qF -- '--updateinformation' "$TEST_TMP/args"
}
