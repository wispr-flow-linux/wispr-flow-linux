#!/usr/bin/env bats
#
# build-workdir.bats
# What survives between builds under build-linux/. Step 2 of
# scripts/build-linux.sh keeps downloads/ and clears every other output, and
# build.sh's sync_stage_to_dist mirrors the staged tree into the Electron
# dist exactly. Both scripts guard their main behind BASH_SOURCE, so they are
# sourced here and their functions run on temp trees.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	rm -rf "$TEST_TMP"
}

# Lay down a build-linux/ tree the way a previous build leaves it.
_previous_workdir() {
	local w="$1"
	mkdir -p "$w/downloads/electron-dist" "$w/stage/Release" \
		"$w/app.asar.contents/.webpack/main" "$w/deb/pkgroot" "$w/appimage"
	printf 'exe' > "$w/downloads/wispr-flow-setup-0.0.0.exe"
	printf 'zip' > "$w/downloads/electron-v0.0.0-linux-x64.zip"
	printf 'bin' > "$w/downloads/electron-dist/wispr-flow"
	printf 'old' > "$w/stage/app.asar"
	printf 'old' > "$w/app.asar.contents/.webpack/main/index.js"
	printf 'old' > "$w/deb/old.deb"
	printf 'old' > "$w/appimage/old.AppImage"
}

# Source build-linux.sh (its main is guarded) and point it at temp trees.
# RESOURCES_SRC carries one file and no app.asar, so step 2 copies it and
# takes its no-asar branch: nothing here needs npx or the network.
_source_build_linux() {
	# shellcheck source=scripts/build-linux.sh
	source "$ROOT/scripts/build-linux.sh"
	WORK_DIR="$TEST_TMP/build-linux"
	STAGE="$WORK_DIR/stage"
	RESOURCES_SRC="$TEST_TMP/resources"
	mkdir -p "$RESOURCES_SRC/assets"
	printf 'new' > "$RESOURCES_SRC/assets/logo.png"
}

# Source build.sh (its main is guarded) with the one global the sync reads.
_source_build_sh() {
	# shellcheck source=build.sh
	source "$ROOT/build.sh"
	work_dir="$TEST_TMP/build-linux"
}

# A stage and a dist resources dir holding one file from each of: the new
# stage, Electron itself, and a previous stage.
_stage_and_dist() {
	local stage="$TEST_TMP/build-linux/stage"
	local res="$TEST_TMP/build-linux/downloads/electron-dist/resources"
	mkdir -p "$stage/Release" "$res/gone" "$res/Release"
	printf 'asar' > "$stage/app.asar"
	printf 'helper' > "$stage/Release/wispr-flow-linux-helper"
	printf 'electron' > "$res/default_app.asar"
	printf 'stale' > "$res/gone/old.txt"
	printf 'stale' > "$res/app.asar.stale"
	printf 'old' > "$res/Release/wispr-flow-linux-helper"
}

_assert_exact_mirror() {
	local res="$TEST_TMP/build-linux/downloads/electron-dist/resources"
	[[ $(< "$res/app.asar") == 'asar' ]]
	[[ $(< "$res/Release/wispr-flow-linux-helper") == 'helper' ]]
	[[ -x $res/Release/wispr-flow-linux-helper ]]
	[[ $(< "$res/default_app.asar") == 'electron' ]]
	[[ ! -e $res/gone ]]
	[[ ! -e $res/app.asar.stale ]]
}

# =============================================================================
# step2_stage_resources
# =============================================================================

@test "step 2: keeps downloads/ and clears every other build output" {
	_source_build_linux
	_previous_workdir "$WORK_DIR"

	step2_stage_resources >/dev/null 2>&1

	[[ $(< "$WORK_DIR/downloads/wispr-flow-setup-0.0.0.exe") == 'exe' ]]
	[[ -f $WORK_DIR/downloads/electron-v0.0.0-linux-x64.zip ]]
	[[ -f $WORK_DIR/downloads/electron-dist/wispr-flow ]]
	[[ ! -e $WORK_DIR/stage/app.asar ]]
	[[ ! -e $WORK_DIR/app.asar.contents ]]
	[[ ! -e $WORK_DIR/deb ]]
	[[ ! -e $WORK_DIR/appimage ]]
	[[ $(< "$STAGE/assets/logo.png") == 'new' ]]
}

@test "step 2: only the top-level downloads/ is spared, not a nested one" {
	# Near miss: a downloads/ inside another output must still be cleared.
	_source_build_linux
	_previous_workdir "$WORK_DIR"
	mkdir -p "$WORK_DIR/deb/downloads"
	printf 'x' > "$WORK_DIR/deb/downloads/keep-me-not"

	step2_stage_resources >/dev/null 2>&1

	[[ ! -e $WORK_DIR/deb ]]
	[[ -f $WORK_DIR/downloads/wispr-flow-setup-0.0.0.exe ]]
}

@test "step 2: a missing work dir is created, not an error" {
	_source_build_linux

	run step2_stage_resources
	[[ $status -eq 0 ]]
	[[ -f $STAGE/assets/logo.png ]]
}

# =============================================================================
# sync_stage_to_dist
# =============================================================================

@test "sync_stage_to_dist: mirrors the stage exactly and keeps default_app.asar" {
	_source_build_sh
	_stage_and_dist
	command -v rsync >/dev/null

	sync_stage_to_dist >/dev/null 2>&1

	_assert_exact_mirror
}

@test "sync_stage_to_dist: the cp fallback mirrors the same way" {
	_source_build_sh
	_stage_and_dist
	# Hide rsync: a PATH holding only the tools the fallback needs.
	local tool
	mkdir -p "$TEST_TMP/bin"
	for tool in cp find mkdir chmod rm; do
		ln -s "$(command -v "$tool")" "$TEST_TMP/bin/$tool"
	done
	PATH="$TEST_TMP/bin"
	run command -v rsync
	[[ $status -ne 0 ]]

	sync_stage_to_dist >/dev/null 2>&1

	_assert_exact_mirror
}

@test "sync_stage_to_dist: refuses a stage without app.asar" {
	_source_build_sh
	mkdir -p "$work_dir/stage"
	run sync_stage_to_dist
	[[ $status -ne 0 ]]
	[[ $output == *'staged app.asar missing'* ]]
}
