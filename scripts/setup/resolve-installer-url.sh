#!/usr/bin/env bash
#===============================================================================
# resolve-installer-url.sh -- resolve the latest Wispr Flow Windows installer
# download URL, version and SHA-256 from the upstream release manifest.
#
# WHY A MANIFEST AND NOT THE "latest" REDIRECT
# --------------------------------------------
# Until ~2026-08-05 the stable redirect endpoint
#   https://dl.wisprflow.ai/windows/latest
# 302'd straight to a versioned, full Squirrel installer whose filename embedded
# the version:
#   -> .../win32/x64/Wispr%20Flow%20Setup-v1.5.695.exe
# Upstream then repointed that redirect at a ~6 MB .NET *web-bootstrap stub*:
#   -> .../win32/x64/WisprFlowInstaller.exe
# The stub is useless to this build for two independent reasons: its filename
# carries no version (so the old sed parse yields nothing and this script died),
# and it embeds no payload at all -- no `*-full.nupkg`, so no `app.asar` for
# extract_installer() to unpack. It only downloads the real installer at run
# time, resolving it through the JSON manifest the stub itself ships:
#   https://dl.wisprflow.com/wispr-flow/win32/latest.json
#   {"schemaVersion":1,"windows":{"x64":{"url":..., "sha256":..., "size":...}}}
# So we read the same manifest the stub reads. That URL still points at the
# versioned full Squirrel installer (filename version parse unchanged), and the
# manifest additionally publishes a **SHA-256**, which the redirect never did --
# so a fetched proprietary binary is now checksum-verifiable (see download.sh).
#
# A `last-known-good.json` sits alongside `latest.json` with the same schema;
# --latest-url points this script at either one.
#
# Output contract (stdout, one KEY=VALUE per line; ALL diagnostics to stderr):
#   URL=<versioned full-installer download URL>
#   VERSION=<x.y.z extracted from the installer filename>
#   SHA256=<hex digest from the manifest, or empty if the manifest omits it>
# SHA256 is emitted LAST and may be absent; parse by key, never by line number.
#
# Usage:   resolve-installer-url.sh [--latest-url <url>] [--version <x.y.z>]
#   --latest-url   override the upstream manifest URL (e.g. last-known-good.json)
#   --version      skip filename parsing and emit this version verbatim
#
# Exit 0 on success; non-zero if the manifest can't be fetched/parsed or the
# version can't be determined. Standalone CI helper -- it sources nothing.
#===============================================================================
set -uo pipefail

readonly DEFAULT_LATEST_URL='https://dl.wisprflow.com/wispr-flow/win32/latest.json'

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
command -v python3 >/dev/null 2>&1 || die 'python3 is required (manifest is JSON)'

log "Resolving Wispr Flow installer from ${latest_url} ..."

manifest="$(curl -fsSL --max-time 60 "$latest_url")"
rc=$?
if [[ $rc -ne 0 || -z $manifest ]]; then
	die "failed to fetch ${latest_url} (curl rc=${rc})"
fi

# Pull url + sha256 out of windows.x64. Only a Windows x64 build is published;
# the Linux arm64 package is built from the SAME x64 installer (the app bundle
# is arch-neutral JS/asar), so this resolver stays arch-independent.
# Emits "<url>\t<sha256>"; a missing/!=1 schemaVersion only warns (the shape is
# validated by the keys we actually read, not by the version number).
parsed="$(printf '%s' "$manifest" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)
except Exception as e:
    sys.exit(f"manifest is not valid JSON: {e}")
sv = m.get("schemaVersion")
if sv != 1:
    print(f"warning: unexpected manifest schemaVersion {sv!r} (expected 1)", file=sys.stderr)
try:
    entry = m["windows"]["x64"]
except (KeyError, TypeError):
    sys.exit("manifest has no windows.x64 entry")
url = (entry.get("url") or "").strip()
if not url:
    sys.exit("manifest windows.x64 entry has no url")
if not url.startswith("https://"):
    sys.exit(f"refusing non-https installer url: {url}")
sha = (entry.get("sha256") or "").strip().lower()
if sha and (len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha)):
    sys.exit(f"manifest sha256 is not a 64-hex digest: {sha!r}")
print(f"{url}\t{sha}")
')"
rc=$?
[[ $rc -eq 0 && -n $parsed ]] || die "could not parse ${latest_url}"

final_url="${parsed%%$'\t'*}"
sha256="${parsed#*$'\t'}"

log "Resolved URL: ${final_url}"

# Extract the version from the filename, e.g. "...Setup-v1.6.774.exe" -> 1.6.774.
# Works on the percent-encoded URL as-is (the space is %20, the version isn't).
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
if [[ -n $sha256 ]]; then
	log "Resolved sha256:  ${sha256}"
else
	log 'Manifest published no sha256 for this entry.'
fi

printf 'URL=%s\n' "$final_url"
printf 'VERSION=%s\n' "$version"
printf 'SHA256=%s\n' "$sha256"
