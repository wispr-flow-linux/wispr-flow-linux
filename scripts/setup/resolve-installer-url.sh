#!/usr/bin/env bash
#===============================================================================
# resolve-installer-url.sh -- resolve the latest Wispr Flow Windows installer
# download URL and version from the upstream "latest" redirect.
#
# Wispr Flow publishes a stable redirect endpoint that 302s to a versioned,
# CDN-hosted Setup .exe whose filename embeds the version:
#   https://dl.wisprflow.ai/windows/latest
#     -> https://dl.wisprflow.com/wispr-flow/win32/x64/Wispr%20Flow%20Setup-v1.5.695.exe
#
# Only a Windows x64 build is published (the arm64 Windows endpoint redirects to
# the homepage). The Linux arm64 package is built from the SAME x64 installer --
# the app bundle is arch-neutral JS/asar -- so this resolver is arch-independent.
#
# Output contract (stdout, one KEY=VALUE per line; ALL diagnostics to stderr):
#   URL=<final resolved download URL>
#   VERSION=<x.y.z extracted from the installer filename>
#
# Usage:   resolve-installer-url.sh [--latest-url <url>] [--version <x.y.z>]
#   --latest-url   override the upstream "latest" redirect endpoint
#   --version      skip filename parsing and emit this version verbatim
#
# Exit 0 on success; non-zero if the URL can't be resolved or the version can't
# be parsed. This is a standalone CI helper -- it sources nothing.
#===============================================================================
set -uo pipefail

readonly DEFAULT_LATEST_URL='https://dl.wisprflow.ai/windows/latest'

log() { printf '%s\n' "$*" >&2; }
die() { printf 'resolve-installer-url: %s\n' "$*" >&2; exit 1; }

latest_url="$DEFAULT_LATEST_URL"
version_override=''

while [[ $# -gt 0 ]]; do
	case "$1" in
		--latest-url)
			[[ -n ${2:-} ]] || die '--latest-url needs a value'
			latest_url="$2"; shift 2 ;;
		--version)
			[[ -n ${2:-} ]] || die '--version needs a value'
			version_override="$2"; shift 2 ;;
		-h|--help)
			grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)
			die "unknown argument: $1" ;;
	esac
done

command -v curl >/dev/null 2>&1 || die 'curl is required'

log "Resolving Wispr Flow installer from ${latest_url} ..."

# Follow the redirect chain with a HEAD request and report the final URL.
# -f fails on HTTP errors; -S surfaces them; -L follows redirects; -I = HEAD.
final_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
	--max-time 60 "$latest_url")"
rc=$?
if [[ $rc -ne 0 || -z $final_url ]]; then
	die "failed to resolve ${latest_url} (curl rc=${rc})"
fi

if [[ $final_url == "$latest_url" ]]; then
	die "no redirect followed from ${latest_url} (got the same URL back)"
fi

log "Resolved URL: ${final_url}"

# Extract the version from the filename, e.g. "...Setup-v1.5.695.exe" -> 1.5.695.
if [[ -n $version_override ]]; then
	version="$version_override"
else
	version="$(printf '%s\n' "$final_url" \
		| sed -nE 's/.*[Ss]etup-v([0-9]+\.[0-9]+\.[0-9]+)\.exe.*/\1/p')"
fi

if [[ -z $version ]]; then
	die "could not parse a version from ${final_url} (pass --version to override)"
fi

log "Resolved version: ${version}"

printf 'URL=%s\n' "$final_url"
printf 'VERSION=%s\n' "$version"
