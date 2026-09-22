#!/usr/bin/env bash
#===============================================================================
# write-installer-pin.sh -- rewrite scripts/setup/installer-pin.sh from a
# resolver result.
#
# Reads resolve-installer-url.sh's KEY=VALUE output on stdin (URL=, VERSION=,
# SHA256=), validates every field, and rewrites the three pin lines in place.
# Nothing is written unless all three values pass, so a half-resolved manifest
# (say, one that dropped its sha256) can never leave the pin internally
# inconsistent. Prints one "old -> new" line per field to stderr.
#
#   scripts/setup/resolve-installer-url.sh | scripts/setup/write-installer-pin.sh
#
# Usage:   write-installer-pin.sh [--pin <file>] < resolved.txt
#   --pin   the pin file to rewrite (default: installer-pin.sh beside this
#           script)
#
# Exit 0 when the pin holds the resolved values afterwards (including the
# no-op case); 1 on a bad or missing field, an unwritable pin, or a rewrite
# that did not take. Standalone -- it sources nothing.
#===============================================================================
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pin_file="$script_dir/installer-pin.sh"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'write-installer-pin: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--pin)
			[[ -n ${2:-} ]] || die '--pin needs a value'
			pin_file="$2"; shift 2 ;;
		-h|--help)
			grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)
			die "unknown argument: $1" ;;
	esac
done

[[ -f $pin_file && -w $pin_file ]] || die "pin file not writable: ${pin_file}"

# --- parse stdin -------------------------------------------------------------
# One KEY=VALUE per line; a repeated key keeps the last value. Unknown keys are
# ignored so the resolver can grow new fields without breaking the writer.
url='' version='' sha256=''
while IFS= read -r line; do
	case "$line" in
		URL=*)     url="${line#URL=}" ;;
		VERSION=*) version="${line#VERSION=}" ;;
		SHA256=*)  sha256="${line#SHA256=}" ;;
	esac
done

# --- validate ----------------------------------------------------------------
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
	|| die "VERSION is not x.y.z: '${version}'"
[[ $url =~ ^https://[^[:space:]\'\"]+$ ]] \
	|| die "URL is not a bare https URL: '${url}'"
[[ $url == *"Setup-v${version}.exe" ]] \
	|| die "URL does not name Setup-v${version}.exe: '${url}'"
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] \
	|| die "SHA256 is not a 64-hex digest: '${sha256}'"

# --- rewrite -----------------------------------------------------------------
# Each pin line is anchored on ^NAME= so a comment mentioning the name is never
# touched. Read the old values first so the log shows the move.
pin_value() { sed -nE "s/^$1='([^']*)'$/\1/p" "$pin_file" | head -1; }
old_version=$(pin_value WISPR_VERSION)
old_url=$(pin_value WISPR_INSTALLER_URL)
old_sha256=$(pin_value WISPR_INSTALLER_SHA256)

[[ -n $old_version && -n $old_url && -n $old_sha256 ]] \
	|| die "pin file is missing one of the three WISPR_* lines: ${pin_file}"

# '|' delimiter clears the '/' in the URL; the values were validated above to
# contain no '|', quote or whitespace.
[[ $url != *'|'* ]] || die "URL contains '|': '${url}'"
sed -i \
	-e "s|^WISPR_VERSION=.*|WISPR_VERSION='${version}'|" \
	-e "s|^WISPR_INSTALLER_URL=.*|WISPR_INSTALLER_URL='${url}'|" \
	-e "s|^WISPR_INSTALLER_SHA256=.*|WISPR_INSTALLER_SHA256='${sha256}'|" \
	"$pin_file" || die "sed failed on ${pin_file}"

# Re-read: a PASS is what the file says now, never what sed was asked to do.
[[ $(pin_value WISPR_VERSION) == "$version" ]] \
	|| die 'WISPR_VERSION did not take'
[[ $(pin_value WISPR_INSTALLER_URL) == "$url" ]] \
	|| die 'WISPR_INSTALLER_URL did not take'
[[ $(pin_value WISPR_INSTALLER_SHA256) == "$sha256" ]] \
	|| die 'WISPR_INSTALLER_SHA256 did not take'

log "WISPR_VERSION:          ${old_version} -> ${version}"
log "WISPR_INSTALLER_URL:    ${old_url} -> ${url}"
log "WISPR_INSTALLER_SHA256: ${old_sha256} -> ${sha256}"
