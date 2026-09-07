#!/usr/bin/env bash
#===============================================================================
# build.sh -- top-level orchestrator for the unofficial Wispr Flow Linux build.
#
# Wraps the validated staging engine (scripts/build-linux.sh) and the packaging
# makers (scripts/packaging/<fmt>.sh). This script does flag parsing, host
# detection, dependency + download dispatch, and packaging dispatch -- it does
# NOT reimplement staging logic.
#
# Flow:
#   parse_arguments
#     --test-flags? -> print resolved flags + exit 0 (NO build)
#   check_dependencies
#   download_installer  (--exe, else fetch latest) -> staged installer
#   scripts/build-linux.sh           -> patch + native + stage (ARCH/version via env)
#   fetch_electron (if not staged)   -> Linux Electron, launcher renamed wispr-flow
#   run_packaging                    -> scripts/packaging/<fmt>.sh
#===============================================================================
set -uo pipefail

#--- global state (set by sourced functions) -----------------------------------
arch=''
arch_deb=''
arch_rpm=''
electron_arch=''
distro_family=''
build_format=''
clean_action='no'
local_exe_path=''
release_tag=''
test_flags_mode=false
pkg_version=''
original_user=''
original_home=''
project_root=''
work_dir=''
installer_exe_path=''
resolved_installer_sha256=''
final_output_path=''

#--- package metadata (constants) ----------------------------------------------
readonly PACKAGE_NAME='wispr-flow'
readonly WM_CLASS='Wispr Flow'
export WM_CLASS
readonly APP_VERSION='1.6.774'
readonly ELECTRON_VERSION='42.3.0'
readonly ELECTRON_MAJOR='42'
# Exported so scripts/build-linux.sh stages the versions the orchestrator
# resolved (it defaults them when unset). They cannot be passed as
# command-prefix assignments (VAR=x cmd): bash rejects a temporary assignment
# to a readonly name, and the staging engine would silently fall back to its
# own defaults.
export APP_VERSION ELECTRON_VERSION ELECTRON_MAJOR
# Exported so packaging makers (Phase 2 deb/appimage) can read them from the
# environment; rpm.sh currently embeds its own metadata.
readonly MAINTAINER='Wispr Flow Linux (unofficial)'
readonly DESCRIPTION='Wispr Flow voice dictation for Linux (unofficial build)'
export MAINTAINER DESCRIPTION

# Lowercase alias used by the sourced setup helpers (download.sh).
electron_version="$ELECTRON_VERSION"

#--- source helpers ------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
source "$script_dir/scripts/_common.sh"
# shellcheck source=scripts/setup/detect-host.sh
source "$script_dir/scripts/setup/detect-host.sh"
# shellcheck source=scripts/setup/dependencies.sh
source "$script_dir/scripts/setup/dependencies.sh"
# shellcheck source=scripts/setup/download.sh
source "$script_dir/scripts/setup/download.sh"

#===============================================================================
# Package version derivation -- mirror the claude-desktop-debian scheme.
#
# The release tag has the shape  v<repoVer>+wispr<wisprVer>  (e.g.
# v1.0.0+wispr1.5.695). When a parseable tag is supplied, the package/filename
# version becomes  <wisprVer>-<repoVer>  (e.g. 1.5.695-1.0.0) so a downstream
# worker can reconstruct the release tag from a package filename. For local /
# no-tag builds the package version stays just <wisprVer> (the APP_VERSION
# constant), and APP_VERSION itself is NEVER altered -- staging always sees the
# bare upstream version.
#===============================================================================
derive_pkg_version() {
	pkg_version="$APP_VERSION"
	[[ -z $release_tag ]] && return 0

	local repo_ver
	repo_ver="$(printf '%s' "$release_tag" \
		| sed -nE 's/^v([0-9]+(\.[0-9]+)*)\+wispr.*/\1/p')"

	if [[ -n $repo_ver ]]; then
		pkg_version="${APP_VERSION}-${repo_ver}"
	else
		warn "Release tag '$release_tag' does not match v<repoVer>+wispr<...>;"
		warn "using bare package version '$pkg_version'."
	fi
}

#===============================================================================
# Staging dispatch -- invoke the validated build-linux.sh, parametrized by env.
#===============================================================================
run_staging() {
	say 'Stage app (patch + native + repack) via scripts/build-linux.sh'
	chmod +x "$script_dir/scripts/build-linux.sh" || die 'cannot chmod build-linux.sh'
	# build-linux.sh reads ARCH/APP_VERSION/ELECTRON_VERSION from the env (it
	# defaults them when unset, preserving its standalone behavior). The
	# version constants reach it as exports (see the constants block); ARCH is
	# per-invocation.
	ARCH="$electron_arch" \
		"$script_dir/scripts/build-linux.sh" \
		|| die 'scripts/build-linux.sh staging failed'
}

#===============================================================================
# Stage -> dist sync -- place the staged resources tree (build-linux/stage)
# into the Electron runtime's resources/ dir, which is what the packaging
# makers read. build-linux.sh writes the patched app.asar (+ app.asar.unpacked,
# Release/helper, assets, migrations) under $work_dir/stage; fetch_electron lays
# down the Electron runtime under electron-dist/. This bridges the two so
# <electron-dist>/resources/{app.asar,Release/wispr-flow-linux-helper} exists
# before packaging. Must run AFTER fetch_electron (its unzip populates
# electron-dist/) and BEFORE run_packaging.
#===============================================================================
sync_stage_to_dist() {
	local stage_dir="$work_dir/stage"
	local res_dir="$work_dir/downloads/electron-dist/resources"

	say 'Sync staged resources into electron-dist/resources'

	[[ -f "$stage_dir/app.asar" ]] \
		|| die "staged app.asar missing at $stage_dir -- staging incomplete"

	mkdir -p "$res_dir"
	if command -v rsync >/dev/null 2>&1; then
		rsync -a "$stage_dir/" "$res_dir/" \
			|| die 'rsync of staged tree into resources failed'
	else
		cp -a "$stage_dir/." "$res_dir/" \
			|| die 'copy of staged tree into resources failed'
	fi

	# The app never chmods the helper; the makers refuse a non-exec one.
	local helper="$res_dir/Release/wispr-flow-linux-helper"
	if [[ -f "$helper" ]]; then
		chmod 0755 "$helper" || warn "could not chmod $helper"
		auto 'Synced staged resources (app.asar + helper + native modules)'
	else
		warn "helper not present in staged tree ($helper)"
		warn '  the staging auto-fetch failed (see warnings above) -- packaging'
		warn '  will fail its helper check. Re-run with network access, or set'
		warn '  HELPER_BIN to a local build (see helper-version.txt /'
		warn '  wispr-flow-linux/helper).'
	fi
}

#===============================================================================
# Packaging dispatch -- hand the staged tree to scripts/packaging/<fmt>.sh.
#===============================================================================
run_packaging() {
	say "Package as .$build_format"

	local dist_dir="$work_dir/downloads/electron-dist"

	# Shared maker signature: <maker>.sh <dist_dir> <version> <arch>
	# where <arch> is the format-native arch. PACKAGE_NAME / WM_CLASS /
	# MAINTAINER / DESCRIPTION are read from the (exported) environment.
	case "$build_format" in
		rpm)
			chmod +x "$script_dir/scripts/packaging/rpm.sh" || die 'cannot chmod rpm.sh'
			"$script_dir/scripts/packaging/rpm.sh" "$dist_dir" "$pkg_version" "$arch_rpm" \
				|| die 'scripts/packaging/rpm.sh failed'
			final_output_path=$(find "$work_dir/rpm/rpmbuild/RPMS" -name "${PACKAGE_NAME}-${pkg_version}-*.rpm" 2>/dev/null | head -1)
			;;
		deb)
			chmod +x "$script_dir/scripts/packaging/deb.sh" || die 'cannot chmod deb.sh'
			"$script_dir/scripts/packaging/deb.sh" "$dist_dir" "$pkg_version" "$arch_deb" \
				|| die 'scripts/packaging/deb.sh failed'
			final_output_path=$(find "$work_dir/deb" -maxdepth 1 -name "${PACKAGE_NAME}_${pkg_version}_*.deb" 2>/dev/null | head -1)
			;;
		appimage)
			chmod +x "$script_dir/scripts/packaging/appimage.sh" || die 'cannot chmod appimage.sh'
			# appimage uses the rpm-style arch (x86_64 / aarch64).
			"$script_dir/scripts/packaging/appimage.sh" "$dist_dir" "$pkg_version" "$arch_rpm" \
				|| die 'scripts/packaging/appimage.sh failed'
			final_output_path=$(find "$work_dir/appimage" -maxdepth 1 -name "${PACKAGE_NAME}-${pkg_version}-*.AppImage" 2>/dev/null | head -1)
			;;
		nix)
			# The Nix build is driven by the flake, not by this packaging
			# dispatch: the derivation in nix/wispr-flow.nix runs its own
			# hermetic extract -> patch -> repack and builds the Rust helper
			# via rustPlatform, so it does not consume build-linux.sh's tree.
			say 'Nix build'
			cat <<'NIXMSG'
The Nix package is built straight from the flake, not through build.sh. It
never fetches the proprietary app -- point it at the installer .exe you
obtained yourself via WISPR_FLOW_EXE (needs --impure):

    WISPR_FLOW_EXE="/path/Wispr Flow Setup-v1.5.695.exe" \
      nix build .#wispr-flow-fhs --impure   # recommended (glibc FHS wrapper)

    WISPR_FLOW_EXE="/path/Wispr Flow Setup-v1.5.695.exe" \
      nix build .#wispr-flow --impure       # bare derivation (no FHS loader)

Overlay/non-flake callers can instead override:
    wispr-flow.override { installerExe = /path/to/Setup.exe; }
NIXMSG
			return 0
			;;
		*)
			die "Unknown build format '$build_format'"
			;;
	esac

	if [[ -n $final_output_path && -f $final_output_path ]]; then
		echo "Package created: $final_output_path"
	else
		warn 'Could not determine final package path.'
	fi
}

#===============================================================================
# Cleanup -- remove regenerable intermediate trees while preserving (a) the
# produced package and (b) the expensive downloads/ tree (installer + Electron
# runtime). The final artifact lives nested under the per-format dir (e.g.
# rpm/rpmbuild/RPMS), so prune scaffolding subdirs rather than the dir itself.
#===============================================================================
clean_intermediates() {
	local removed=0 target
	for target in \
		"$work_dir/stage" \
		"$work_dir/app.asar.contents" \
		"$work_dir/deb/pkgroot" \
		"$work_dir/rpm/pkgroot" \
		"$work_dir/rpm/rpmbuild/BUILD" \
		"$work_dir/rpm/rpmbuild/BUILDROOT" \
		"$work_dir/rpm/rpmbuild/SOURCES" \
		"$work_dir/rpm/rpmbuild/SPECS" \
		"$work_dir/rpm/rpmbuild/SRPMS"
	do
		[[ -e $target ]] || continue
		rm -rf "$target" && removed=$((removed + 1))
	done
	# AppImage AppDir scaffolding (the .AppImage artifact sits beside it, kept).
	local appdir
	for appdir in "$work_dir"/appimage/*.AppDir; do
		[[ -d $appdir ]] || continue
		rm -rf "$appdir" && removed=$((removed + 1))
	done
	auto "Cleanup: removed $removed intermediate tree(s); kept the package and downloads/."
}

print_resolved_flags() {
	echo '--- Resolved Flags ---'
	echo "Build format:   $build_format"
	echo "Arch (canon):   $arch"
	echo "Arch (deb):     $arch_deb"
	echo "Arch (rpm):     $arch_rpm"
	echo "Arch (electron):$electron_arch"
	echo "Distro family:  $distro_family"
	echo "Clean:          $clean_action"
	echo "Exe:            ${local_exe_path:-<none: fetch latest upstream>}"
	echo "Release tag:    ${release_tag:-<none>}"
	echo "App version:    $APP_VERSION"
	echo "Package version:$pkg_version"
	echo "Electron:       $ELECTRON_VERSION (major $ELECTRON_MAJOR)"
}

#===============================================================================
# Main
#===============================================================================
main() {
	project_root="$script_dir"

	say 'Host detection'
	detect_architecture
	detect_distro
	check_system_requirements

	say 'Argument parsing'
	parse_arguments "$@"
	derive_pkg_version

	if [[ $test_flags_mode == true ]]; then
		print_resolved_flags
		echo 'Test-flags mode: exiting WITHOUT building.'
		exit 0
	fi

	check_dependencies

	# Phase 2: resolve the installer (--exe, else fetch the latest upstream),
	# then 7z-extract it into the extract/ tree that staging consumes
	# (idempotent -- reuses a hand-prepared tree).
	download_installer
	extract_installer

	# Phase 3: patch + native rebuild + stage the app tree.
	run_staging

	# Phase 3b: stage the Linux Electron runtime (launcher renamed wispr-flow)
	# unless build-linux.sh / a prior run already produced it.
	fetch_electron "$work_dir/downloads/electron-dist"

	# Phase 3c: bridge the staged resources tree into the Electron runtime's
	# resources/ dir (what the makers read). Nix builds from the flake and
	# ignore this tree, so skip the sync there.
	if [[ $build_format != 'nix' ]]; then
		sync_stage_to_dist
	fi

	# Phase 4: package.
	run_packaging

	# Phase 5: optional cleanup of intermediate build files.
	if [[ $clean_action == 'yes' ]]; then
		say 'Cleanup intermediate build files'
		clean_intermediates
	fi

	say 'Build process finished.'
	[[ -n $final_output_path ]] && echo "Output: $final_output_path"
}

main "$@"
exit 0
