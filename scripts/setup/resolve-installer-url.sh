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
# --latest-url points this script at either one. The manifest path was first
# found by @khamsakamal48 in #55.
#
# FALLBACK: THE SQUIRREL RELEASES FILE
# ------------------------------------
# Only when latest.json is unreachable or unparsable (not JSON, no
# windows.x64.url), the script falls back to the Squirrel.Windows `RELEASES`
# file in the installer directory:
#   https://dl.wisprflow.com/wispr-flow/win32/x64/RELEASES
#   <SHA1> WisprFlow-1.6.957-full.nupkg <size>
# RELEASES publishes no SHA-256, and the pin refuses a URL without one, so this
# path earns its digest: it reads the version from the newest full-nupkg line,
# HEAD-verifies the Setup .exe URL built from it, downloads the .exe and
# sha256sums it, then 7z-extracts the `*-full.nupkg` and requires its SHA-1 to
# equal the RELEASES line. A manifest that parses but is refused (non-https
# url, malformed sha256) stays fatal and does NOT fall back. Needs sha256sum,
# sha1sum and 7z on this path only. stderr names the path taken.
#
# Output contract (stdout, one KEY=VALUE per line; ALL diagnostics to stderr):
#   URL=<versioned full-installer download URL>
#   VERSION=<x.y.z extracted from the installer filename>
#   SHA256=<hex digest from the manifest, or empty if the manifest omits it>
# SHA256 is emitted LAST and may be absent; parse by key, never by line number.
#
# Usage:   resolve-installer-url.sh [--latest-url <url>] [--releases-url <url>]
#                                  [--version <x.y.z>]
#   --latest-url    override the upstream manifest URL (last-known-good.json)
#   --releases-url  override the fallback RELEASES URL (default: x64/RELEASES
#                   beside the manifest)
#   --version       skip filename parsing and emit this version verbatim; on
#                   the fallback, pick that version's RELEASES line
#
# Exit 0 on success; non-zero if neither path resolves, the fallback fails a
# check, or the version can't be determined. Standalone CI helper -- it
# sources nothing.
#===============================================================================
set -uo pipefail

readonly DEFAULT_LATEST_URL='https://dl.wisprflow.com/wispr-flow/win32/latest.json'

log() { printf '%s\n' "$*" >&2; }
die() { printf 'resolve-installer-url: %s\n' "$*" >&2; exit 1; }

latest_url="$DEFAULT_LATEST_URL"
releases_url=''
version_override=''

while [[ $# -gt 0 ]]; do
	case "$1" in
		--latest-url)
			[[ -n ${2:-} ]] || die '--latest-url needs a value'
			latest_url="$2"; shift 2 ;;
		--releases-url)
			[[ -n ${2:-} ]] || die '--releases-url needs a value'
			releases_url="$2"; shift 2 ;;
		--version)
			[[ -n ${2:-} ]] || die '--version needs a value'
			version_override="$2"; shift 2 ;;
		-h|--help)
			grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
		*)
			die "unknown argument: $1" ;;
	esac
done

# The Squirrel installer directory sits one level below the manifest.
[[ -n $releases_url ]] || releases_url="${latest_url%/*}/x64/RELEASES"

command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v python3 >/dev/null 2>&1 || die 'python3 is required (manifest is JSON)'

# resolve_from_releases -- the fallback described in the header. Sets the
# globals final_url, version and sha256, or dies.
resolve_from_releases() {
	local body line rel_sha1 nupkg_name rel_dir tmp exe nupkg rc
	local -a lines=()

	log "Falling back to the Squirrel RELEASES file at ${releases_url} ..."
	case $releases_url in
		https://*|file://*) ;;
		*) die "refusing non-https RELEASES url: ${releases_url}" ;;
	esac
	local tool
	for tool in sha256sum sha1sum 7z; do
		command -v "$tool" >/dev/null 2>&1 \
			|| die "${tool} is required for the RELEASES fallback"
	done

	body="$(curl -fsSL --max-time 60 "$releases_url")"
	rc=$?
	if [[ $rc -ne 0 || -z $body ]]; then
		die "failed to fetch ${releases_url} (curl rc=${rc})"
	fi

	# "<SHA1> WisprFlow-<x.y.z>-full.nupkg <size>" lines only; deltas and
	# anything else are skipped. A leading BOM is tolerated.
	mapfile -t lines < <(printf '%s\n' "${body#$'\xef\xbb\xbf'}" \
		| tr -d '\r' \
		| sed -nE 's/^([0-9A-Fa-f]{40}) +([^ ]+-([0-9]+\.[0-9]+\.[0-9]+)-full\.nupkg) +[0-9]+ *$/\3 \1 \2/p' \
		| sort -V -k1,1)
	[[ ${#lines[@]} -gt 0 ]] \
		|| die "no <sha1> <name>-x.y.z-full.nupkg line in ${releases_url}"

	if [[ -n $version_override ]]; then
		line=''
		local l
		for l in "${lines[@]}"; do
			[[ ${l%% *} == "$version_override" ]] && line="$l"
		done
		[[ -n $line ]] \
			|| die "RELEASES has no full nupkg for" \
				"--version ${version_override}"
	else
		line="${lines[${#lines[@]}-1]}"
	fi
	read -r version rel_sha1 nupkg_name <<< "$line"
	rel_sha1="${rel_sha1,,}"
	log "RELEASES names ${nupkg_name} (sha1 ${rel_sha1})"

	rel_dir="${releases_url%/*}"
	final_url="${rel_dir}/Wispr%20Flow%20Setup-v${version}.exe"
	curl -fsSLI -o /dev/null --max-time 60 "$final_url" \
		|| die "built ${final_url} from RELEASES, but it does not resolve"

	tmp="$(mktemp -d)" || die 'mktemp failed'
	# shellcheck disable=SC2064  # expand $tmp now; it is local to this call
	trap "rm -rf '$tmp'" EXIT
	exe="$tmp/setup.exe"
	log "Downloading ${final_url} to digest it ..."
	curl -fsSL --max-time 900 -o "$exe" "$final_url" \
		|| die "failed to download ${final_url}"
	read -r sha256 _ < <(sha256sum "$exe")

	# Cross-check: the nupkg inside the .exe must be the one RELEASES names.
	7z x -y -o"$tmp/x" "$exe" >/dev/null 2>&1 \
		|| die "7z could not extract ${final_url}"
	nupkg="$(find "$tmp/x" -maxdepth 1 -iname "$nupkg_name" | head -1)"
	[[ -n $nupkg ]] || die "${final_url} does not contain ${nupkg_name}"
	local got_sha1
	read -r got_sha1 _ < <(sha1sum "$nupkg")
	[[ $got_sha1 == "$rel_sha1" ]] \
		|| die "SHA-1 mismatch: ${nupkg_name} in the .exe is ${got_sha1}," \
			"RELEASES says ${rel_sha1}"
	log "Nupkg SHA-1 matches RELEASES."
}

log "Resolving Wispr Flow installer from ${latest_url} ..."

final_url=''
version=''
sha256=''
via=''

manifest="$(curl -fsSL --max-time 60 "$latest_url")"
rc=$?
if [[ $rc -ne 0 || -z $manifest ]]; then
	log "failed to fetch ${latest_url} (curl rc=${rc})"
	resolve_from_releases
	via='RELEASES fallback'
else
	# Pull url + sha256 out of windows.x64. Only a Windows x64 build is
	# published; the Linux arm64 package is built from the SAME x64 installer
	# (the app bundle is arch-neutral JS/asar), so this resolver stays
	# arch-independent. Emits "<url>\t<sha256>"; a missing/!=1 schemaVersion
	# only warns (the shape is validated by the keys we actually read, not by
	# the version number). Exit 2 = unparsable (falls back), 1 = refused.
	parsed="$(printf '%s' "$manifest" | python3 -c '
import json, sys
def unparsable(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)
try:
    m = json.load(sys.stdin)
except Exception as e:
    unparsable(f"manifest is not valid JSON: {e}")
sv = m.get("schemaVersion") if isinstance(m, dict) else None
if sv != 1:
    print(f"warning: unexpected manifest schemaVersion {sv!r} (expected 1)", file=sys.stderr)
try:
    entry = m["windows"]["x64"]
    url = (entry.get("url") or "").strip()
except (KeyError, TypeError, AttributeError):
    unparsable("manifest has no windows.x64 entry")
if not url:
    unparsable("manifest windows.x64 entry has no url")
if not url.startswith("https://"):
    sys.exit(f"refusing non-https installer url: {url}")
sha = (entry.get("sha256") or "").strip().lower()
if sha and (len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha)):
    sys.exit(f"manifest sha256 is not a 64-hex digest: {sha!r}")
print(f"{url}\t{sha}")
')"
	rc=$?
	if [[ $rc -eq 2 ]]; then
		log "could not parse ${latest_url}"
		resolve_from_releases
		via='RELEASES fallback'
	elif [[ $rc -ne 0 || -z $parsed ]]; then
		die "could not parse ${latest_url}"
	else
		final_url="${parsed%%$'\t'*}"
		sha256="${parsed#*$'\t'}"
		via='latest.json'
	fi
fi

log "Resolved URL: ${final_url}"

# Extract the version from the filename, e.g. "...Setup-v1.6.774.exe" -> 1.6.774.
# Works on the percent-encoded URL as-is (the space is %20, the version isn't).
# The fallback already set it from RELEASES.
if [[ -z $version ]]; then
	if [[ -n $version_override ]]; then
		version="$version_override"
	else
		version="$(printf '%s\n' "$final_url" \
			| sed -nE 's/.*[Ss]etup-v([0-9]+\.[0-9]+\.[0-9]+)\.exe.*/\1/p')"
	fi
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
log "Resolved via: ${via}"

printf 'URL=%s\n' "$final_url"
printf 'VERSION=%s\n' "$version"
printf 'SHA256=%s\n' "$sha256"
