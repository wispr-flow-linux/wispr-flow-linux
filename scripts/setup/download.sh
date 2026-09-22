# shellcheck shell=bash
# shellcheck disable=SC2154  # project_root/work_dir/local_exe_path/electron_* are assigned by build.sh before this is used
#===============================================================================
# download.sh -- obtain the pinned Wispr Flow installer (or take the one the
#                user supplied), and fetch the Linux Electron runtime.
#
# Sourced by: build.sh
# Requires:   scripts/_common.sh (say/auto/warn/die/verify_sha256) and
#             scripts/setup/installer-pin.sh (WISPR_VERSION,
#             WISPR_INSTALLER_URL, WISPR_INSTALLER_SHA256) already sourced.
# Reads globals:
#   project_root, work_dir, local_exe_path, electron_version, electron_arch
# Sets globals:
#   installer_exe_path   (path to the .exe used for this build)
#
# Network note: fetch_electron() and download_installer() perform real
# downloads. download_installer() fetches the proprietary app from the pinned
# upstream URL unless you point it at a local --exe. Neither is exercised by
# --test-flags (build.sh exits first).
#===============================================================================

# Pick an available downloader. Echoes "wget" or "curl"; dies if neither.
_downloader() {
	if command -v wget >/dev/null 2>&1; then
		echo wget
	elif command -v curl >/dev/null 2>&1; then
		echo curl
	else
		die 'Neither wget nor curl is available to download files.'
	fi
}

# _fetch <url> <dest> -- download url to dest using whichever downloader exists.
_fetch() {
	local url="$1" dest="$2" tool
	tool=$(_downloader)
	if [[ $tool == wget ]]; then
		wget -O "$dest" "$url"
	else
		curl -fSL -o "$dest" "$url"
	fi
}

#-------------------------------------------------------------------------------
# download_installer -- obtain the Wispr Flow Windows installer for this build.
#   * --exe <path> supplied: repackage that local installer; no network fetch.
#   * --exe absent (default): download the pinned upstream installer
#     (installer-pin.sh) and refuse it unless its SHA-256 matches the pin
#     (see fetch_installer). The proprietary app is never bundled or committed
#     to the repo -- it is fetched/supplied fresh each build.
#
# Verification on the --exe path: WISPR_EXE_SHA256 (an explicit operator
# digest) is enforced when set; otherwise the local file is compared against
# the pin and a mismatch only WARNS, because --exe is the documented way to
# build a different installer than the pinned one (an older bundle for an
# anchor comparison, a new release before the pin moves).
#-------------------------------------------------------------------------------
download_installer() {
	say 'Locate Wispr Flow installer'

	if [[ -z ${local_exe_path:-} ]]; then
		fetch_installer
		return 0
	fi

	[[ -f $local_exe_path ]] || die "Local installer not found: $local_exe_path"
	installer_exe_path="$local_exe_path"
	auto "Using local installer: $installer_exe_path"

	if [[ -n ${WISPR_EXE_SHA256:-} ]]; then
		verify_sha256 "$installer_exe_path" "$WISPR_EXE_SHA256" \
			'Wispr Flow installer (WISPR_EXE_SHA256)' \
			|| die 'Installer checksum verification failed'
		return 0
	fi

	local actual _
	read -r actual _ < <(sha256sum "$installer_exe_path")
	if [[ $actual == "${WISPR_INSTALLER_SHA256:-}" ]]; then
		auto "Local installer matches the pinned ${WISPR_VERSION} digest"
	else
		warn "Local installer is not the pinned ${WISPR_VERSION} installer"
		warn "  (sha256 ${actual:0:12}..., pin ${WISPR_INSTALLER_SHA256:0:12}...)."
		warn '  The Linux patches were audited against the pin; a different'
		warn '  bundle can drift their anchors. The package is still labelled'
		warn "  ${APP_VERSION:-$WISPR_VERSION}."
	fi
}

#-------------------------------------------------------------------------------
# fetch_installer -- download the pinned upstream installer and verify it.
# Used when --exe is not supplied. The URL and digest come from
# installer-pin.sh, never from a live "latest" lookup: only the bump workflow
# resolves upstream (scripts/setup/resolve-installer-url.sh), and it moves the
# pin in a reviewable commit. A digest mismatch is fatal -- either the download
# is corrupt/tampered or upstream re-published the same version with different
# bytes, and in both cases the right fix is a new pin, not a build.
#
# The download is cached under downloads/ and reused on re-runs, but only
# after it re-verifies; a partial or stale file is discarded and re-fetched.
#-------------------------------------------------------------------------------
fetch_installer() {
	[[ -n ${WISPR_INSTALLER_URL:-} && -n ${WISPR_INSTALLER_SHA256:-} ]] \
		|| die 'installer pin is incomplete (see scripts/setup/installer-pin.sh)'

	local download_dir="$work_dir/downloads"
	mkdir -p "$download_dir" || die "cannot create $download_dir"
	installer_exe_path="$download_dir/wispr-flow-setup-${WISPR_VERSION}.exe"

	if [[ -f $installer_exe_path ]]; then
		if verify_sha256 "$installer_exe_path" "$WISPR_INSTALLER_SHA256" \
			'cached Wispr Flow installer' >/dev/null 2>&1; then
			auto "Reusing cached installer: $installer_exe_path"
			return 0
		fi
		warn "Cached installer failed its digest; re-downloading: $installer_exe_path"
		rm -f "$installer_exe_path"
	fi

	auto "No --exe supplied; downloading the pinned ${WISPR_VERSION} installer"
	auto "  $WISPR_INSTALLER_URL"
	local part="${installer_exe_path}.part"
	rm -f "$part"
	_fetch "$WISPR_INSTALLER_URL" "$part" \
		|| { rm -f "$part"; die "Failed to download installer from ${WISPR_INSTALLER_URL}"; }

	if ! verify_sha256 "$part" "$WISPR_INSTALLER_SHA256" \
		"Wispr Flow installer ${WISPR_VERSION}"; then
		rm -f "$part"
		die "Downloaded installer does not match the pinned sha256.
The pin (scripts/setup/installer-pin.sh) may be stale, or the download was
corrupted or tampered with. Refusing to build from it. Pass --exe to build a
local installer you trust, or wait for the bump workflow to move the pin."
	fi
	mv "$part" "$installer_exe_path" || die "cannot move $part into place"
	auto "Installer verified: $installer_exe_path"
}

#-------------------------------------------------------------------------------
# extract_installer -- turn the resolved Squirrel .exe into the extract/ tree
# that build-linux.sh consumes (extract/nupkg/lib/net45/resources/app.asar).
# Mirrors the documented manual 7z steps. Idempotent: a hand-prepared local
# extract/ tree is reused instead of re-extracted, so this is a no-op for devs
# who already extracted by hand -- and it's what lets CI build from a freshly
# downloaded installer (the extract/ tree is gitignored / never committed).
#
# A reused tree must hold the version this build is for. The Squirrel nupkg
# inside it is named WisprFlow-<version>-full.nupkg, so the tree's version is
# read from that; the wanted version is the pin on the fetch path, or whatever
# the --exe filename says (Setup-v<version>.exe; unknown when it doesn't). A
# known mismatch is fatal rather than silently staging the wrong bundle under
# the pinned label -- `rm -rf extract/` is the fix.
#-------------------------------------------------------------------------------

# _extracted_version <extract_dir> -- version of the nupkg in the tree, or ''.
_extracted_version() {
	local nupkg
	nupkg=$(find "$1" -maxdepth 1 -iname 'WisprFlow-*-full.nupkg' 2>/dev/null \
		| head -1)
	[[ -n $nupkg ]] || return 0
	nupkg=${nupkg##*/}
	nupkg=${nupkg#WisprFlow-}
	printf '%s' "${nupkg%-full.nupkg}"
}

# _installer_version -- the version this build's installer is meant to be:
# the pin when it was fetched, else what the --exe filename says, else ''.
_installer_version() {
	if [[ -z ${local_exe_path:-} ]]; then
		printf '%s' "${WISPR_VERSION:-}"
		return 0
	fi
	printf '%s\n' "${local_exe_path##*/}" \
		| sed -nE 's/.*[Ss]etup-v([0-9]+\.[0-9]+\.[0-9]+)\.exe$/\1/p'
}

extract_installer() {
	local extract_dir="$project_root/extract"
	local app_asar="$extract_dir/nupkg/lib/net45/resources/app.asar"

	if [[ -f $app_asar ]]; then
		local have want
		have=$(_extracted_version "$extract_dir")
		want=$(_installer_version)
		if [[ -n $have && -n $want && $have != "$want" ]]; then
			die "extract/ holds Wispr Flow ${have} but this build wants ${want}.
Remove it (rm -rf '${extract_dir}') to re-extract from the installer."
		fi
		auto "Reusing existing extracted tree at $extract_dir${have:+ (${have})}"
		return 0
	fi

	say 'Extract Squirrel installer (.exe -> nupkg -> app payload)'
	command -v 7z >/dev/null 2>&1 \
		|| die '7z (p7zip) is required to extract the installer'

	rm -rf "$extract_dir"
	mkdir -p "$extract_dir"

	# .exe -> *-full.nupkg (plus other Squirrel files)
	7z x -y -o"$extract_dir" "$installer_exe_path" >/dev/null \
		|| die "7z extraction failed for $installer_exe_path"

	local nupkg
	nupkg=$(find "$extract_dir" -maxdepth 1 -iname '*-full.nupkg' | head -1)
	[[ -n $nupkg ]] \
		|| nupkg=$(find "$extract_dir" -maxdepth 1 -iname '*.nupkg' | head -1)
	[[ -n $nupkg ]] || die "no .nupkg found after extracting $installer_exe_path"
	auto "Found package: $(basename "$nupkg")"

	# *-full.nupkg -> nupkg/lib/net45/... (the Electron payload)
	7z x -y -o"$extract_dir/nupkg" "$nupkg" >/dev/null \
		|| die "7z extraction failed for $nupkg"

	[[ -f $app_asar ]] || die "app.asar missing after extraction ($app_asar)"
	auto 'Extracted app payload (app.asar present)'
}

#-------------------------------------------------------------------------------
# fetch_electron -- download + stage the Linux Electron runtime, then RENAME the
# 'electron' binary to 'wispr-flow'.
#
# The rename is MANDATORY: with the launcher named 'electron', Electron sets
# app.isPackaged=false, which makes the app resolve DEV resource paths and load
# 0 DB migrations -> "no such table". Renaming to 'wispr-flow' flips
# isPackaged=true and all migrations run. (See build-linux.sh step6.)
#
# Honors ELECTRON_MIRROR / ELECTRON_CUSTOM_DIR like the upstream tooling:
#   base = ${ELECTRON_MIRROR:-https://github.com/electron/electron/releases/download/}v<ver>/
#   if ELECTRON_CUSTOM_DIR is set, it replaces the "v<ver>" path segment.
#
# Destination: <dest_dir>/ (default: work_dir/downloads/electron-dist) containing
# the unpacked dist with the launcher named 'wispr-flow'.
#-------------------------------------------------------------------------------
fetch_electron() {
	local dest_dir="${1:-$work_dir/downloads/electron-dist}"
	say "Fetch Linux Electron ${electron_version} (${electron_arch})"

	if [[ -x "$dest_dir/wispr-flow" ]]; then
		auto "Electron already staged + renamed at $dest_dir/wispr-flow; skipping fetch."
		return 0
	fi

	local zip_name="electron-v${electron_version}-linux-${electron_arch}.zip"
	local base url
	base="${ELECTRON_MIRROR:-https://github.com/electron/electron/releases/download/}"
	if [[ -n ${ELECTRON_CUSTOM_DIR:-} ]]; then
		url="${base}${ELECTRON_CUSTOM_DIR}/${zip_name}"
	else
		url="${base}v${electron_version}/${zip_name}"
	fi

	local download_dir="$work_dir/downloads"
	mkdir -p "$download_dir"
	local zip_path="$download_dir/$zip_name"

	if [[ ! -f $zip_path ]]; then
		auto "Downloading Electron dist: $url"
		_fetch "$url" "$zip_path" || die "Failed to download Electron from $url"
	else
		auto "Reusing cached Electron zip: $zip_path"
	fi

	# Optional checksum from upstream SHASUMS256.txt (best-effort).
	local expected_sha=''
	if command -v "$(_downloader)" >/dev/null 2>&1; then
		local sums_url
		if [[ -n ${ELECTRON_CUSTOM_DIR:-} ]]; then
			sums_url="${base}${ELECTRON_CUSTOM_DIR}/SHASUMS256.txt"
		else
			sums_url="${base}v${electron_version}/SHASUMS256.txt"
		fi
		local sums_file="$download_dir/SHASUMS256-${electron_version}.txt"
		if _fetch "$sums_url" "$sums_file" 2>/dev/null; then
			expected_sha=$(grep -F "$zip_name" "$sums_file" 2>/dev/null | awk '{print $1; exit}')
		fi
	fi
	verify_sha256 "$zip_path" "$expected_sha" "$zip_name" \
		|| die 'Electron dist checksum verification failed'

	auto "Extracting Electron dist into $dest_dir"
	mkdir -p "$dest_dir"
	if command -v unzip >/dev/null 2>&1; then
		unzip -oq "$zip_path" -d "$dest_dir" || die 'unzip of Electron dist failed'
	elif command -v 7z >/dev/null 2>&1; then
		7z x -y "$zip_path" -o"$dest_dir" >/dev/null || die '7z extract of Electron dist failed'
	else
		die 'Need unzip or 7z to extract the Electron dist'
	fi

	# MANDATORY rename: electron -> wispr-flow (see header).
	if [[ -f "$dest_dir/electron" ]]; then
		mv "$dest_dir/electron" "$dest_dir/wispr-flow" || die 'Failed to rename electron -> wispr-flow'
		chmod 0755 "$dest_dir/wispr-flow"
		auto 'Renamed launcher electron -> wispr-flow (sets app.isPackaged=true)'
	elif [[ -x "$dest_dir/wispr-flow" ]]; then
		auto 'Launcher already named wispr-flow'
	else
		die "No 'electron' launcher found under $dest_dir after extraction"
	fi
}
