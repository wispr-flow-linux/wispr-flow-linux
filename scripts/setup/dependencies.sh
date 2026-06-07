# shellcheck shell=bash
# shellcheck disable=SC2154  # build_format/distro_family are assigned by build.sh (the sourcing script) before this is used
#===============================================================================
# dependencies.sh -- map logical build deps to distro packages and install them.
#
# Sourced by: build.sh
# Requires:   scripts/_common.sh (check_command/warn/die) already sourced.
# Reads globals: build_format, distro_family
#
# Logical deps for the Wispr Flow Linux build:
#   7z         (p7zip)        -- extract the Squirrel installer .exe / .nupkg
#   wget/curl                 -- download installer + Electron dist
#   wrestool,icotool (icoutils)-- extract icons from Windows resources
#   convert    (imagemagick)  -- icon conversion/resizing
#   rsync                     -- stage resource trees
#   node, npx                 -- @electron/asar pack/unpack + helpers
#   cargo                     -- build the clean-room Rust helper (release)
#   python3                   -- run the bundle patch suite (scripts/patches/*)
# Format-specific:
#   rpmbuild   (rpm-build)    -- only for --build rpm
#   dpkg-deb   (dpkg-dev/dpkg)-- only for --build deb
#
# python3 is REQUIRED: every patch under scripts/patches/ (helper-resolver,
# mac-gates, linux-window-frame, ...) drives its `re`-based rewrite through
# python3, and build-linux.sh Step 3 runs them unconditionally. Debian/Ubuntu
# ship python3 in the base image so it is silently present there, but minimal
# images (e.g. the fedora:42 rpm container) do not -- without it every patch
# fails `python3: command not found` and verify-patches.sh then fails the build.
#
# NOTE: the native sqlite addons are fetched as pinned, provenance-verified
# prebuilt assets (scripts/setup/fetch-native-bin.sh), so no C/C++ toolchain is
# required for the normal build. Only the OPTIONAL local from-source rebuild
# fallback (build-linux.sh Step 4 -> rebuild-native-modules.sh) needs a compiler
# + make; it reports any missing tool itself, so those are not forced system
# deps here.
#===============================================================================

check_dependencies() {
	echo 'Checking build dependencies...'

	# Logical commands the build needs. wget/curl is satisfied by EITHER, so we
	# check that pair specially below rather than listing both here.
	local common_deps='7z wrestool icotool convert rsync node npx cargo python3'
	local all_deps="$common_deps"

	case "$build_format" in
		deb) all_deps="$all_deps dpkg-deb" ;;
		rpm) all_deps="$all_deps rpmbuild" ;;
	esac

	# command -> package, per distro family.
	declare -A debian_pkgs=(
		[7z]='p7zip-full' [wrestool]='icoutils' [icotool]='icoutils'
		[convert]='imagemagick' [rsync]='rsync' [node]='nodejs' [npx]='npm'
		[cargo]='cargo' [dpkg-deb]='dpkg-dev' [rpmbuild]='rpm'
		[python3]='python3' [wget]='wget' [curl]='curl'
	)
	declare -A rpm_pkgs=(
		[7z]='p7zip p7zip-plugins' [wrestool]='icoutils' [icotool]='icoutils'
		[convert]='ImageMagick' [rsync]='rsync' [node]='nodejs' [npx]='npm'
		[cargo]='cargo' [dpkg-deb]='dpkg' [rpmbuild]='rpm-build'
		[python3]='python3' [wget]='wget' [curl]='curl'
	)

	local deps_to_install=''

	# Resolve the package name for a command for the current distro family.
	_pkg_for() {
		local cmd="$1"
		case "$distro_family" in
			debian) printf '%s' "${debian_pkgs[$cmd]:-}" ;;
			rpm)    printf '%s' "${rpm_pkgs[$cmd]:-}" ;;
			*)      printf '' ;;
		esac
	}

	# Queue a package once (some commands share a package, e.g. icoutils).
	_queue_pkg() {
		local pkg="$1"
		[[ -n $pkg ]] || return 0
		case " $deps_to_install " in
			*" $pkg "*) ;;
			*) deps_to_install="$deps_to_install $pkg" ;;
		esac
	}

	local cmd pkg
	for cmd in $all_deps; do
		if ! check_command "$cmd"; then
			pkg=$(_pkg_for "$cmd")
			if [[ -z $pkg ]]; then
				warn "Cannot auto-install '$cmd' on '$distro_family'; install it manually."
				continue
			fi
			_queue_pkg "$pkg"
		fi
	done

	# wget OR curl satisfies the download requirement.
	if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
		echo 'Neither wget nor curl found'
		_queue_pkg "$(_pkg_for curl)"
	fi

	if [[ -z $deps_to_install ]]; then
		echo 'All required build dependencies are present.'
		return 0
	fi

	echo "Missing system dependencies:$deps_to_install"

	# In test-flags / dry contexts the build never reaches here, but guard
	# anyway: if we cannot install, instruct the user and fail.
	local sudo_cmd='sudo'
	if (( EUID == 0 )); then
		sudo_cmd=''
		echo 'Installing as root (no sudo needed)...'
	else
		echo 'Attempting to install missing dependencies via sudo...'
		if sudo -n true 2>/dev/null; then
			echo 'Passwordless sudo detected.'
		elif ! sudo -v; then
			die 'Could not validate sudo credentials. Install the packages above manually and retry.'
		fi
	fi

	case "$distro_family" in
		debian)
			$sudo_cmd apt update || die "'apt update' failed"
			# shellcheck disable=SC2086  # word-splitting deps_to_install is intended
			$sudo_cmd apt install -y $deps_to_install || die "'apt install' failed"
			;;
		rpm)
			# shellcheck disable=SC2086  # word-splitting deps_to_install is intended
			$sudo_cmd dnf install -y $deps_to_install || die "'dnf install' failed"
			;;
		*)
			die "Cannot auto-install on '$distro_family'. Install manually:$deps_to_install"
			;;
	esac
	echo 'System dependencies installed successfully.'
}
