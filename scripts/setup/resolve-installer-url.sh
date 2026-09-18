#!/usr/bin/env bash
#===============================================================================
# resolve-installer-url.sh -- resolve the latest Wispr Flow Windows installer
# download URL and version.
#
# Wispr Flow publishes a stable redirect endpoint:
#   https://dl.wisprflow.ai/windows/latest
# It used to 302 straight to a versioned, CDN-hosted Setup .exe whose filename
# embedded the version (.../Wispr%20Flow%20Setup-v1.5.695.exe). As of the
# WisprFlowInstaller.exe bootstrapper rollout, it instead 302s to a small
# (~6 MB) unversioned stub that downloads the real installer at run time, so
# the version can no longer be read off that filename.
#
# Instead we read the Squirrel.Windows `RELEASES` manifest that sits next to
# the installer in the same CDN directory -- it is unaffected by the
# bootstrapper change and always names the current full nupkg, e.g.:
#   <SHA1> WisprFlow-1.6.897-full.nupkg <size>
# From that we recover the version and build the direct Setup .exe URL, which
# still exists at the same path template the bootstrapper used to redirect to.
# We verify that URL resolves before returning it, so a further CDN layout
# change fails loudly here instead of downloading garbage downstream.
#
# Only a Windows x64 build is published (the arm64 Windows endpoint redirects to
# the homepage). The Linux arm64 package is built from the SAME x64 installer --
# the app bundle is arch-neutral JS/asar -- so this resolver is arch-independent.
#
# Output contract (stdout, one KEY=VALUE per line; ALL diagnostics to stderr):
#   URL=<direct download URL for the versioned Setup .exe>
#   VERSION=<x.y.z, from the RELEASES manifest (or filename if still present)>
#
# Usage:   resolve-installer-url.sh [--latest-url <url>] [--version <x.y.z>]
#   --latest-url   override the upstream "latest" redirect endpoint
#   --version      skip version discovery and emit this version verbatim
#                  (the Setup .exe URL is still built from it and verified)
#
# Exit 0 on success; non-zero if the URL/version can't be resolved. This is a
# standalone CI helper -- it sources nothing.
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
# Works when the redirect still lands directly on the versioned Setup .exe.
if [[ -n $version_override ]]; then
	version="$version_override"
else
	version="$(printf '%s\n' "$final_url" \
		| sed -nE 's/.*[Ss]etup-v([0-9]+\.[0-9]+\.[0-9]+)\.exe.*/\1/p')"
fi

# Fallback: the redirect now lands on an unversioned bootstrapper stub
# (WisprFlowInstaller.exe), so the filename has no version to parse. Read the
# Squirrel.Windows RELEASES manifest in the same CDN directory instead -- it
# names the current full nupkg, e.g. "WisprFlow-1.6.897-full.nupkg".
installer_dir=''
if [[ -z $version ]]; then
	installer_dir="${final_url%/*}"
	releases_url="${installer_dir}/RELEASES"
	log "Filename has no version; trying RELEASES manifest at ${releases_url} ..."

	releases_body="$(curl -fsSL --max-time 60 "$releases_url")"
	rc=$?
	if [[ $rc -ne 0 || -z $releases_body ]]; then
		die "failed to fetch ${releases_url} (curl rc=${rc})"
	fi

	version="$(printf '%s\n' "$releases_body" \
		| sed -nE 's/.*-([0-9]+\.[0-9]+\.[0-9]+)-full\.nupkg.*/\1/p' | head -1)"
fi

if [[ -z $version ]]; then
	die "could not determine a version from ${final_url} (pass --version to override)"
fi

log "Resolved version: ${version}"

# Build the direct Setup .exe URL. When the redirect already landed on a
# versioned Setup .exe, that URL is used verbatim; otherwise (bootstrapper
# stub or --version override) it is built from the RELEASES manifest's
# directory using the naming template Wispr has used since v1 of this script.
if [[ $final_url == *[Ss]etup-v*.exe ]]; then
	download_url="$final_url"
else
	[[ -n $installer_dir ]] || installer_dir="${final_url%/*}"
	download_url="${installer_dir}/Wispr%20Flow%20Setup-v${version}.exe"
fi

# Verify the URL actually resolves before handing it to a downstream
# downloader -- a further CDN layout change should fail loudly here.
if ! curl -fsSLI -o /dev/null --max-time 60 "$download_url"; then
	die "built ${download_url} from version ${version}, but it does not" \
		" resolve (pass --version to override, or re-check the CDN layout)"
fi

printf 'URL=%s\n' "$download_url"
printf 'VERSION=%s\n' "$version"
