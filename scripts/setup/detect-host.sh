# shellcheck shell=bash
# shellcheck disable=SC2034  # globals set here are consumed by build.sh (the sourcing script)
# shellcheck disable=SC2154  # project_root is assigned by build.sh before parse_arguments runs
#===============================================================================
# detect-host.sh -- host detection + CLI flag parsing for the Wispr Flow build.
#
# Sourced by: build.sh
# Requires:   scripts/_common.sh (say/warn/die) already sourced.
#
# Sets these globals (declared in build.sh):
#   arch            canonical uname-style arch: x86_64 | aarch64
#   arch_deb        Debian naming:              amd64  | arm64
#   arch_rpm        RPM naming:                 x86_64 | aarch64
#   electron_arch   Electron release naming:    x64    | arm64
#   distro_family   debian | rpm | nix | unknown
#   build_format    deb | rpm | appimage | nix  (default from distro_family)
#   clean_action    yes | no
#   local_exe_path  path to a local installer .exe (from --exe), or empty
#   release_tag     optional release tag string
#   test_flags_mode true | false
#   original_user, original_home
#
# Arch naming convention (documented):
#   This box is Nobara/Fedora x86_64 -> arch=x86_64, arch_rpm=x86_64,
#   arch_deb=amd64, electron_arch=x64. The rpm maker (scripts/packaging/rpm.sh)
#   expects x86_64; the future deb maker will expect amd64. We thread BOTH and
#   let run_packaging() pick the right one per format.
#===============================================================================

# --- architecture -------------------------------------------------------------
detect_architecture() {
	local raw_arch
	raw_arch=$(uname -m) || die 'Failed to detect machine architecture'
	echo "Detected machine architecture: $raw_arch"

	case "$raw_arch" in
		x86_64|amd64)
			arch='x86_64'
			arch_deb='amd64'
			arch_rpm='x86_64'
			electron_arch='x64'
			;;
		aarch64|arm64)
			arch='aarch64'
			arch_deb='arm64'
			arch_rpm='aarch64'
			electron_arch='arm64'
			;;
		*)
			die "Unsupported architecture: $raw_arch (supported: x86_64/amd64, aarch64/arm64)"
			;;
	esac
	echo "Canonical arch: $arch (deb=$arch_deb rpm=$arch_rpm electron=$electron_arch)"
}

# Map a requested --arch value (amd64|arm64|x86_64|aarch64) onto all the
# per-format arch globals. Used by parse_arguments when --arch overrides
# the detected host arch (e.g. cross-target test runs).
set_arch_from_request() {
	local req="$1"
	case "${req,,}" in
		amd64|x86_64|x64)
			arch='x86_64'; arch_deb='amd64'; arch_rpm='x86_64'; electron_arch='x64' ;;
		arm64|aarch64)
			arch='aarch64'; arch_deb='arm64'; arch_rpm='aarch64'; electron_arch='arm64' ;;
		*)
			die "Invalid --arch '$req' (must be amd64|arm64)" ;;
	esac
}

# --- distribution -------------------------------------------------------------
detect_distro() {
	if [[ -f /etc/NIXOS ]]; then
		distro_family='nix'
		echo 'Detected NixOS'
	elif [[ -f /etc/fedora-release ]]; then
		distro_family='rpm'
		echo "Detected Fedora: $(cat /etc/fedora-release)"
	elif [[ -f /etc/redhat-release ]]; then
		distro_family='rpm'
		echo "Detected Red Hat-based: $(cat /etc/redhat-release)"
	elif [[ -f /etc/debian_version ]]; then
		distro_family='debian'
		echo "Detected Debian-based (version $(cat /etc/debian_version))"
	elif [[ -f /etc/os-release ]] && grep -Eqi 'rhel|fedora|centos|rocky|alma|suse' /etc/os-release; then
		distro_family='rpm'
		echo 'Detected RPM-family distribution via /etc/os-release'
	else
		distro_family='unknown'
		warn 'Could not detect distribution family (deb/rpm autodetect unavailable; AppImage still works)'
	fi

	local pretty
	pretty=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2)
	echo "Distribution: ${pretty:-Unknown}"
	echo "Distribution family: $distro_family"
}

# --- system requirements ------------------------------------------------------
check_system_requirements() {
	# Allow root only in CI/container; otherwise require a normal user (we sudo
	# explicitly when a privileged action is actually needed).
	if (( EUID == 0 )); then
		if [[ -n ${CI:-} || -n ${GITHUB_ACTIONS:-} || -f /.dockerenv ]]; then
			echo 'Running as root in CI/container environment (allowed)'
		else
			die 'Do not run this script as root/sudo. Run as a normal user; it will sudo only when needed.'
		fi
	fi

	original_user=$(whoami)
	original_home=$(getent passwd "$original_user" | cut -d: -f6)
	[[ -n $original_home ]] || die "Could not determine home directory for user $original_user"
	echo "Running as user: $original_user (Home: $original_home)"
}

# --- argument parsing ---------------------------------------------------------
parse_arguments() {
	# Defaults. work_dir matches the existing build-linux.sh layout.
	work_dir="$project_root/build-linux"

	case "$distro_family" in
		debian) build_format='deb' ;;
		rpm)    build_format='rpm' ;;
		nix)    build_format='nix' ;;
		*)      build_format='appimage' ;;
	esac

	while (( $# > 0 )); do
		case "$1" in
			-b|--build|--arch|-e|--exe|-c|--clean|-r|--release-tag)
				if [[ -z ${2:-} || $2 == -* ]]; then
					die "Argument for $1 is missing"
				fi
				case "$1" in
					-b|--build)       build_format="${2,,}" ;;
					--arch)           set_arch_from_request "$2" ;;
					-e|--exe)         local_exe_path="$2" ;;
					-c|--clean)       clean_action="${2,,}" ;;
					-r|--release-tag) release_tag="$2" ;;
				esac
				shift 2
				;;
			--test-flags)
				test_flags_mode=true
				shift
				;;
			-h|--help)
				print_usage
				exit 0
				;;
			*)
				warn "Unknown option: $1"
				echo 'Use -h or --help for usage information.' >&2
				exit 1
				;;
		esac
	done

	# --- validation ---
	case "$build_format" in
		deb|rpm|appimage|nix) ;;
		*) die "Invalid build format '$build_format' (must be deb|rpm|appimage|nix)" ;;
	esac

	case "$clean_action" in
		yes|no) ;;
		*) die "Invalid --clean '$clean_action' (must be yes|no)" ;;
	esac

	if [[ -n $local_exe_path && ! -f $local_exe_path ]]; then
		die "--exe path does not exist: $local_exe_path"
	fi

	# Warn if building a native package for the "wrong" distro family.
	if [[ $build_format == 'deb' && $distro_family != 'debian' ]]; then
		warn "Building .deb on a non-Debian system ($distro_family); this may fail."
	elif [[ $build_format == 'rpm' && $distro_family != 'rpm' ]]; then
		warn "Building .rpm on a non-RPM system ($distro_family); this may fail."
	fi
}

print_usage() {
	cat <<EOF
Usage: ./build.sh [options]

Builds an unofficial Wispr Flow Linux package from the Windows installer.

Options:
  -b, --build <fmt>      Package format: deb | rpm | appimage | nix
                         (default: auto-detected from distro -> '$build_format')
      --arch <arch>      Target architecture: amd64 | arm64
                         (default: detected host arch -> '$arch')
  -e, --exe <path>       Path to a Wispr Flow installer .exe you obtained
                         yourself (optional; default: fetch the latest installer
                         from Wispr's official endpoint)
  -c, --clean <yes|no>   Remove intermediate build files when done (default: no)
  -r, --release-tag <t>  Optional release tag to embed in the package version
      --test-flags       Parse + print resolved flags, then exit WITHOUT building
  -h, --help             Show this help and exit

Notes:
  * deb / appimage are stubbed until Phase 2; nix is deferred to Phase 6.
  * The build wraps scripts/build-linux.sh (staging) and
    scripts/packaging/<fmt>.sh (packaging); it never rewrites them.
  * Native sqlite addons are fetched as a pinned prebuilt from the
    wispr-flow-linux/native-modules repo (pinned in native-modules-version.txt).
    Set WISPR_NATIVE_REBUILD=1 to build a local, non-portable copy from source
    instead (dev only; needs node/npm + a C/C++ toolchain).
EOF
}
