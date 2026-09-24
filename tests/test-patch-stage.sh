#!/usr/bin/env bash
#===============================================================================
# test-patch-stage.sh -- run the real patch stage over the real Wispr bundle.
#
# tests/linux-patches.bats pins each patch against fixtures copied from
# shipped bytes. That is fast and runs everywhere, and it cannot say whether
# the fixtures still match the bundle the pin ships, or whether the repacked
# asar parses. This closes that gap. It sources scripts/build-linux.sh, runs
# its step 2 (unpack) and step 3 (every main and renderer patch) over a
# pristine app.asar, repacks the way step 7 does, and asserts:
#
#   1. step 3 exits 0 and prints no [WARN] line. A patch that misses its
#      anchor dies there (issue #104); the [WARN] check keeps catching the
#      softer skips a patch may still log.
#   2. a second step 3 pass prints no [WARN] line and leaves the tree
#      byte-identical (backups aside): idempotency, and the anchor-survives-
#      its-own-patch rule in docs/learnings/patching-minified-js.md.
#   3. drop_patch_backups leaves no *.orig in the tree, and the repacked
#      asar's header lists none.
#   4. every JS file under .webpack/ in the repacked asar parses
#      (node --check).
#   5. scripts/verify-patches.sh finds every marker in the repacked asar.
#
# Usage:
#   tests/test-patch-stage.sh              # the pinned version: reuses
#                                          # extract/ when it holds it, else
#                                          # downloads the pinned installer
#                                          # (cached under build-linux/downloads)
#   tests/test-patch-stage.sh <resources>  # a dir holding a pristine app.asar
#                                          # with app.asar.unpacked beside it
#
# Not wired into CI: the pinned installer is ~350 MB. Run it before a patch
# change ships and on every upstream bump. Needs node and npx (@electron/asar);
# 7z and curl or wget on the download path. Work happens in a temp dir;
# build-linux/stage and extract/ are never written.
#===============================================================================

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=scripts/_common.sh
source "$project_root/scripts/_common.sh"
# shellcheck source=scripts/setup/installer-pin.sh
source "$project_root/scripts/setup/installer-pin.sh"
# shellcheck source=scripts/setup/download.sh
source "$project_root/scripts/setup/download.sh"
# pass/fail counters, print_summary, assert_asar_no_patch_backups.
# shellcheck source=tests/test-artifact-common.sh
source "$project_root/tests/test-artifact-common.sh"

usage() {
	sed -n '2,/^#===.*===$/{ /^#===/d; s/^# \{0,1\}//p }' "${BASH_SOURCE[0]}"
}

# _check <label> <cmd...>: PASS/FAIL on the command's exit status.
_check() {
	local label="$1"
	shift
	if "$@"; then
		pass "$label"
	else
		fail "$label"
	fi
}

# The [WARN] lines a step 3 log carries, colour escapes stripped.
_warn_lines() {
	sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -F '[WARN]'
}

# One digest over every file in a tree except the patch backups, which a
# re-run may legitimately rewrite and drop_patch_backups removes anyway.
_tree_digest() {
	(cd "$1" && find . -type f ! -name '*.orig' -print0 \
		| LC_ALL=C sort -z | xargs -0 sha256sum) | sha256sum | cut -d' ' -f1
}

# Print the pristine resources dir to use: the argument, the repo's extract/
# tree when it already holds the pinned version, else a fresh download of the
# pinned installer extracted into the temp dir. Progress goes to stderr.
_resolve_resources() {
	local arg="$1" tmp="$2" have
	if [[ -n $arg ]]; then
		[[ -f $arg/app.asar ]] || die "no app.asar in $arg"
		printf '%s' "$arg"
		return 0
	fi
	have=$(_extracted_version "$project_root/extract")
	if [[ $have == "$WISPR_VERSION" \
		&& -f $project_root/extract/nupkg/lib/net45/resources/app.asar ]]; then
		echo "Using extract/ (Wispr Flow $have, the pinned version)" >&2
		printf '%s' "$project_root/extract/nupkg/lib/net45/resources"
		return 0
	fi
	# download.sh globals: cache the installer where build.sh would, extract
	# into the temp dir so a wrong-version extract/ is never touched.
	work_dir="$project_root/build-linux"
	local_exe_path=''
	fetch_installer >&2 || return 1
	project_root="$tmp" extract_installer >&2 || return 1
	printf '%s' "$tmp/extract/nupkg/lib/net45/resources"
}

main() {
	local src_arg="${1:-}"
	if [[ $src_arg == '-h' || $src_arg == '--help' ]]; then
		usage
		exit 0
	fi
	local tool
	for tool in node npx; do
		command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
	done

	local tmp
	tmp=$(mktemp -d) || exit 1
	# shellcheck disable=SC2064  # $tmp must expand now, not at trap time
	trap "rm -rf '$tmp'" EXIT

	local src
	src=$(_resolve_resources "$src_arg" "$tmp") || exit 1
	echo "Pristine resources: $src"

	# Source the pipeline without running it (its main is guarded), then point
	# its work tree at the temp dir. RESOURCES_SRC is what step 2 unpacks.
	# shellcheck source=scripts/build-linux.sh
	source "$project_root/scripts/build-linux.sh"
	WORK_DIR="$tmp/work"
	STAGE="$WORK_DIR/stage"
	RESOURCES_SRC="$src"
	local contents="$WORK_DIR/app.asar.contents"
	local main_bundle="$contents/.webpack/main/index.js"
	local rc

	echo '=== step 2: unpack ==='
	# Subshells throughout: a step that exits would otherwise take this
	# harness with it and skip every remaining assertion.
	( step2_stage_resources ) > "$tmp/step2.log" 2>&1
	rc=$?
	_check 'step 2 exits 0' test "$rc" -eq 0
	_check 'step 2 unpacked the main bundle' test -f "$main_bundle"
	if [[ ! -f $main_bundle ]]; then
		sed 's/^/  | /' "$tmp/step2.log"
		print_summary
	fi

	echo '=== pass 1: patch stage ==='
	( step3_patch_bundle ) > "$tmp/pass1.log" 2>&1
	rc=$?
	sed 's/^/  | /' "$tmp/pass1.log"
	_check 'step 3 exits 0' test "$rc" -eq 0
	local warns
	warns=$(_warn_lines "$tmp/pass1.log")
	_check 'step 3 printed no [WARN] line' test -z "$warns"
	[[ -n $warns ]] && printf '%s\n' "$warns" | sed 's/^/    /'

	echo '=== pass 2: idempotency ==='
	local before after
	before=$(_tree_digest "$contents")
	( step3_patch_bundle ) > "$tmp/pass2.log" 2>&1
	rc=$?
	sed 's/^/  | /' "$tmp/pass2.log"
	after=$(_tree_digest "$contents")
	_check 'second step 3 pass exits 0' test "$rc" -eq 0
	warns=$(_warn_lines "$tmp/pass2.log")
	_check 'second pass printed no [WARN] line' test -z "$warns"
	[[ -n $warns ]] && printf '%s\n' "$warns" | sed 's/^/    /'
	_check 'patched tree byte-identical after the second pass' \
		test "$before" = "$after"

	echo '=== repack ==='
	# The pack step 7 runs, minus its helper and native-module guards: this
	# test stages neither, and the Windows .node the pristine asar unpacks
	# would fail them by design.
	drop_patch_backups "$contents"
	_check 'no *.orig left in the contents tree' \
		test "$(find "$contents" -type f -name '*.orig' | wc -l)" -eq 0
	npx --yes @electron/asar pack "$contents" "$tmp/app.asar" \
		--unpack '*.node' > "$tmp/pack.log" 2>&1
	rc=$?
	_check 'asar pack exits 0' test "$rc" -eq 0
	if [[ ! -f $tmp/app.asar ]]; then
		sed 's/^/  | /' "$tmp/pack.log"
		print_summary
	fi
	assert_asar_no_patch_backups "$tmp/app.asar"

	echo '=== parse check ==='
	npx --yes @electron/asar extract "$tmp/app.asar" "$tmp/verify" \
		> /dev/null 2>&1 || die 'asar extract of the repacked archive failed'
	local broken=0 total=0 f
	while IFS= read -r -d '' f; do
		total=$((total + 1))
		if ! node --check "$f" > /dev/null 2>&1; then
			broken=$((broken + 1))
			echo "  SyntaxError in ${f#"$tmp"/verify/}"
		fi
	done < <(find "$tmp/verify/.webpack" -name '*.js' -type f -print0)
	_check "all $total JS files under .webpack/ parse" \
		test "$broken" -eq 0 -a "$total" -gt 0

	echo '=== marker check ==='
	bash "$project_root/scripts/verify-patches.sh" "$tmp/app.asar" \
		> "$tmp/verify.log" 2>&1
	rc=$?
	sed 's/^/  | /' "$tmp/verify.log"
	_check 'verify-patches.sh: every marker present in the repacked asar' \
		test "$rc" -eq 0

	print_summary
}

main "$@"
