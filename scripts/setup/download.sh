# shellcheck shell=bash
# shellcheck disable=SC2154  # project_root/work_dir/local_exe_path/electron_* are assigned by build.sh before this is used
#===============================================================================
# download.sh -- locate the user-supplied Wispr Flow installer, and fetch the
#                Linux Electron runtime.
#
# Sourced by: build.sh
# Requires:   scripts/_common.sh (say/auto/warn/die/verify_sha256) already sourced.
# Reads globals:
#   project_root, work_dir, local_exe_path, electron_version, electron_arch
# Sets globals:
#   installer_exe_path   (path to the .exe used for this build)
#
# Network note: fetch_electron() and download_installer() perform real
# downloads. download_installer() fetches the proprietary app from Wispr's
# official endpoint unless you point it at a local --exe. Neither is exercised
# by --test-flags (build.sh exits first).
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
#   * --exe absent (default): resolve the latest upstream URL and download it
#     (see fetch_installer). The proprietary app is never bundled or committed
#     to the repo -- it is fetched/supplied fresh each build.
# A SHA-256 is verified IF one is known, in precedence order:
#   1. WISPR_EXE_SHA256 env      (explicit operator override, wins over all)
#   2. installer.sha256 file     (pinned in-tree)
#   3. the upstream release manifest's own sha256, captured by fetch_installer
#      (resolve-installer-url.sh emits SHA256=; only set on the fetch path, so
#      a --exe installer is never checked against the *latest* hash)
# Absence still only warns -- but on the default fetch path a hash is now always
# available, so a corrupted or tampered download fails the build.
#-------------------------------------------------------------------------------
download_installer() {
	say 'Locate Wispr Flow installer'

	if [[ -n ${local_exe_path:-} ]]; then
		[[ -f $local_exe_path ]] || die "Local installer not found: $local_exe_path"
		installer_exe_path="$local_exe_path"
		auto "Using local installer: $installer_exe_path"
	else
		fetch_installer
	fi

	# Optional SHA-256 verification (see precedence in the header comment).
	local expected_sha=''
	if [[ -n ${WISPR_EXE_SHA256:-} ]]; then
		expected_sha="$WISPR_EXE_SHA256"
	elif [[ -f "$project_root/installer.sha256" ]]; then
		expected_sha=$(awk '{print $1; exit}' "$project_root/installer.sha256")
	elif [[ -n ${resolved_installer_sha256:-} ]]; then
		expected_sha="$resolved_installer_sha256"
	fi
	verify_sha256 "$installer_exe_path" "$expected_sha" 'Wispr Flow installer' \
		|| die 'Installer checksum verification failed'
}

#-------------------------------------------------------------------------------
# fetch_installer -- resolve the latest upstream installer URL and download it.
# Used when --exe is not supplied. Mirrors what CI does, via the same
# resolve-installer-url.sh helper. Guards that the resolved version matches the
# pinned APP_VERSION (the version the Linux patches were verified against), so a
# fetched build can't silently mislabel or run against an un-audited bundle; on
# mismatch it aborts with guidance to pass --exe. The download is cached under
# downloads/ and reused on re-runs.
#-------------------------------------------------------------------------------
fetch_installer() {
	local resolver="$project_root/scripts/setup/resolve-installer-url.sh"
	[[ -x $resolver ]] || die "installer resolver not found: $resolver"

	auto 'No --exe supplied; resolving the latest Wispr Flow installer'
	local resolved url version sha
	resolved=$("$resolver") \
		|| die 'Failed to resolve the Wispr Flow installer URL (pass --exe to use a local installer)'
	url=$(printf '%s\n' "$resolved" | sed -nE 's/^URL=//p')
	version=$(printf '%s\n' "$resolved" | sed -nE 's/^VERSION=//p')
	sha=$(printf '%s\n' "$resolved" | sed -nE 's/^SHA256=//p')
	[[ -n $url ]] || die 'installer resolver returned no URL'
	# Publish the manifest hash for download_installer's verification step. Only
	# the fetch path sets it, so a local --exe is never judged against it.
	resolved_installer_sha256="$sha"
	if [[ -z $sha ]]; then
		warn 'upstream manifest published no sha256; the download cannot be verified'
	fi

	if [[ -n $version && $version != "${APP_VERSION:-}" ]]; then
		die "upstream latest is ${version} but this build is pinned to ${APP_VERSION}.
Pass --exe with a ${APP_VERSION} installer, or update the pinned version first."
	fi

	local download_dir="$work_dir/downloads"
	mkdir -p "$download_dir"
	installer_exe_path="$download_dir/wispr-flow-setup-${APP_VERSION}.exe"
	if [[ -f $installer_exe_path ]]; then
		auto "Reusing cached installer: $installer_exe_path"
	else
		auto "Downloading installer: $url"
		_fetch "$url" "$installer_exe_path" \
			|| die "Failed to download installer from ${url}"
	fi
}

#-------------------------------------------------------------------------------
# extract_installer -- turn the resolved Squirrel .exe into the extract/ tree
# that build-linux.sh consumes (extract/nupkg/lib/net45/resources/app.asar).
# Mirrors the documented manual 7z steps. Idempotent: a hand-prepared local
# extract/ tree is reused instead of re-extracted, so this is a no-op for devs
# who already extracted by hand -- and it's what lets CI build from a freshly
# downloaded installer (the extract/ tree is gitignored / never committed).
#-------------------------------------------------------------------------------
extract_installer() {
	local extract_dir="$project_root/extract"
	local app_asar="$extract_dir/nupkg/lib/net45/resources/app.asar"

	if [[ -f $app_asar ]]; then
		auto "Reusing existing extracted tree at $extract_dir"
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
