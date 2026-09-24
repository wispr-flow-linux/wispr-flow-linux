# shellcheck shell=bash
#===============================================================================
# _lib.sh -- the shell every scripts/patches/*.sh shares. Sourced, never run.
#
#   patch_begin <marker> <bundle-arg> [default-bundle]
#       Resolve the bundle (the argument, else <default-bundle> relative to
#       the repo root, else usage), exit 0 "Already patched" when <marker> is
#       in it, write the pristine <bundle>.orig backup when absent. Sets
#       MARKER, BUNDLE, BACKUP.
#   patch_verify_marker
#       After the Python body: the marker must be in the bundle, else restore
#       and exit 1.
#   patch_expect_shape <grep-args...> -- <message>
#       An extra fixed/regex form check on the patched bundle (the widened
#       predicate, the rewritten property); restore and exit 1 on a miss.
#   patch_finish <ok-line>
#       node --check the bundle when node is present (restore and exit 1 on
#       a parse error), then print "OK: <ok-line>".
#   patch_restore
#       Put the backup back.
#
# Callers run under `set -euo pipefail`; each function returns 0 or exits
# with the status the patch scripts have always used (2 usage, 1 failure, 0
# already patched). The messages are the ones tests/linux-patches.bats and
# scripts/build-linux.sh key on, so change them there too.
#
# Anchor and marker discipline: docs/learnings/patching-minified-js.md. The
# upstream literals each patch depends on live in tripwires.tsv beside this
# file; scripts/check-upstream-tripwires.sh runs them over a pristine tree
# before any patch does, so "upstream changed the thing" and "the anchor
# missed" are different failures.
#===============================================================================

PATCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

patch_begin() {
	MARKER="$1"
	BUNDLE="${2:-}"
	local default="${3:-}"
	if [[ -z "$BUNDLE" && -n "$default" ]]; then
		# default to the in-repo extracted bundle
		BUNDLE="$(cd "$PATCH_LIB_DIR/../.." && pwd)/$default"
	fi
	if [[ -z "$BUNDLE" ]]; then
		echo "usage: $0 <bundle.js>" >&2
		exit 2
	fi
	if [[ ! -f "$BUNDLE" ]]; then
		echo "ERROR: bundle not found: $BUNDLE" >&2
		exit 1
	fi
	if grep -qF -- "$MARKER" "$BUNDLE"; then
		echo "Already patched ($MARKER present in $BUNDLE) - nothing to do."
		exit 0
	fi
	BACKUP="$BUNDLE.orig"
	if [[ ! -f "$BACKUP" ]]; then
		cp -p "$BUNDLE" "$BACKUP"
		echo "Backup written: $BACKUP"
	fi
}

patch_restore() {
	cp -p "$BACKUP" "$BUNDLE"
}

patch_verify_marker() {
	if ! grep -qF -- "$MARKER" "$BUNDLE"; then
		echo "ERROR: post-patch verification failed (marker not found)." >&2
		echo "       Restoring backup." >&2
		patch_restore
		exit 1
	fi
}

patch_expect_shape() {
	local args=()
	while [[ $# -gt 0 && $1 != '--' ]]; do
		args+=("$1")
		shift
	done
	[[ ${1:-} == '--' ]] && shift
	local message="${1:?patch_expect_shape needs a message after --}"
	if ! grep "${args[@]}" -- "$BUNDLE"; then
		echo "ERROR: $message Restoring backup." >&2
		patch_restore
		exit 1
	fi
}

patch_finish() {
	if command -v node >/dev/null; then
		if ! node --check "$BUNDLE"; then
			echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
			patch_restore
			exit 1
		fi
		echo "node --check OK"
	fi
	echo "OK: $1"
}
