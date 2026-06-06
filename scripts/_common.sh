# shellcheck shell=bash
#===============================================================================
# _common.sh -- shared shell helpers for the Wispr Flow Linux build scripts.
#
# Sourced by: build.sh and the scripts/setup/* scripts.
# Provides: colored logging (say/auto/manual/warn/die), command checks, and
#           SHA-256 verification. The say/auto/manual/warn colors match the
#           ones already used by scripts/build-linux.sh and scripts/packaging/*
#           so the build output stays visually consistent across stages.
#
# This file is meant to be SOURCED, not executed.
#===============================================================================

# --- logging ------------------------------------------------------------------
say()    { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
auto()   { printf '  \033[1;32m[AUTO]\033[0m   %s\n' "$*"; }
manual() { printf '  \033[1;33m[MANUAL]\033[0m %s\n' "$*"; }
warn()   { printf '  \033[1;31m[WARN]\033[0m   %s\n' "$*" >&2; }
die()    { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- command presence ---------------------------------------------------------
# Returns 0 and prints "<cmd> found"; returns 1 and prints "<cmd> not found".
check_command() {
	if command -v "$1" >/dev/null 2>&1; then
		echo "$1 found"
		return 0
	fi
	echo "$1 not found"
	return 1
}

# --- checksum verification ----------------------------------------------------
# verify_sha256 <file> <expected_hash> [label]
# If expected_hash is empty, warn and return 0 (hash is optional for some
# upstream artifacts that publish no checksum).
verify_sha256() {
	local file_path="$1"
	local expected_hash="$2"
	local label="${3:-file}"

	if [[ -z $expected_hash ]]; then
		warn "No SHA-256 hash for ${label}, skipping verification"
		return 0
	fi

	echo "Verifying SHA-256 checksum for ${label}..."
	local actual_hash _
	read -r actual_hash _ < <(sha256sum "$file_path")

	if [[ $actual_hash != "$expected_hash" ]]; then
		warn "SHA-256 mismatch for ${label}!"
		warn "  Expected: $expected_hash"
		warn "  Actual:   $actual_hash"
		return 1
	fi

	echo "SHA-256 verified: ${label}"
	return 0
}
