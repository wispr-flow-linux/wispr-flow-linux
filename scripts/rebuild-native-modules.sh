#!/usr/bin/env bash
#===============================================================================
# rebuild-native-modules.sh -- rebuild Wispr Flow's native sqlite addons for the
# Linux Electron 42 ABI, deterministically, from public npm + the in-repo V8
# patch. NO Wispr Flow code is involved.
#
# The shipped app carries WINDOWS PE .node for:
#   better-sqlite3-multiple-ciphers   (encrypted SQLCipher DB engine)
#   sqlite3                            (plain sqlite)
# On Linux they must be rebuilt against Electron's V8 14.8 / Node 24 ABI (146).
# better-sqlite3-multiple-ciphers does NOT compile against V8 14.8 unpatched;
# the clean-room patch in scripts/patches/ is applied to a pristine checkout.
#
# This is the single source of rebuild truth, shared by:
#   - .github/workflows/build-native-modules.yml (the producer -> release asset)
#   - scripts/build-linux.sh step4               (local-dev fallback)
#
# It builds a throwaway, lockfile-pinned npm project (npm ci against committed
# scripts/native-modules/package-lock.json), patches, rebuilds with an isolated
# electron-gyp header dir (so node-gyp can NEVER pick up system Node headers),
# harvests the two .node into <out_dir>, verifies them (ELF magic, arch, OpenSSL
# linkage, and -- when ELECTRON_BIN is set -- the runtime ABI), and writes a
# native-modules.lock provenance stamp + per-file .sha256.
#
# Usage:   rebuild-native-modules.sh <arch> <out_dir>
#   <arch>      x86_64 | aarch64 | amd64 | arm64 | x64
#   out_dir     where the verified .node + checksums + lock are written
# Env:
#   ELECTRON_VERSION   electron to target          (default: 42.3.0)
#   ELECTRON_BIN       electron binary for the runtime ABI assertion (optional
#                      but STRONGLY recommended; without it the ABI check is
#                      skipped and a wrong-ABI build could slip through)
#   REBUILD_KEEP=1     keep the scratch build dir (debugging)
#
# Requires: node, npm, npx, a C/C++ toolchain (cc/c++, make), python3, patch,
#           readelf, sha256sum. Exit 0 on success.
#===============================================================================
set -uo pipefail

#-- pinned versions (single source of truth; the lockfile pins the rest) -------
readonly BSC_VERSION='12.5.0'        # better-sqlite3-multiple-ciphers
readonly SQLITE_VERSION='5.1.7'      # sqlite3
readonly REBUILD_VERSION='4.0.4'     # @electron/rebuild
readonly ELECTRON_ABI='146'        # NODE_MODULE_VERSION (Electron 42/V8 14.8)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
electron_version="${ELECTRON_VERSION:-42.3.0}"
patch_file="$script_dir/patches/v8-14.8-better-sqlite3-multiple-ciphers.patch"
pinned_dir="$script_dir/native-modules"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'rebuild-native-modules: %s\n' "$*" >&2; exit 1; }

#===============================================================================
# arg parsing + arch normalization
#===============================================================================
[[ $# -ge 2 ]] || die 'usage: rebuild-native-modules.sh <arch> <out_dir>'

# electron_arch feeds @electron/rebuild --arch; asset_arch names the outputs and
# the provenance; elf_machine is the expected ELF e_machine (offset 18, LE).
case "$1" in
	x86_64|amd64|x64)
		electron_arch='x64'; asset_arch='x86_64'; elf_machine='3e00' ;;
	aarch64|arm64)
		electron_arch='arm64'; asset_arch='aarch64'; elf_machine='b700' ;;
	*) die "unsupported arch: $1 (want x86_64|aarch64|amd64|arm64|x64)" ;;
esac

out_dir="$2"
mkdir -p "$out_dir" || die "cannot create out_dir: $out_dir"
out_dir="$(cd "$out_dir" && pwd)"

#===============================================================================
# preflight: toolchain + pinned inputs
#===============================================================================
preflight() {
	local missing=''
	local tool
	for tool in node npm npx make python3 patch readelf sha256sum; do
		command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
	done
	# A C++ compiler under any of the usual names.
	if ! command -v c++ >/dev/null 2>&1 \
		&& ! command -v g++ >/dev/null 2>&1 \
		&& ! command -v clang++ >/dev/null 2>&1; then
		missing="$missing c++"
	fi
	[[ -z $missing ]] || die "missing required tools:$missing"

	[[ -f $patch_file ]] || die "V8 patch not found: $patch_file"
	[[ -f "$pinned_dir/package.json" ]] \
		|| die "pinned package.json not found: $pinned_dir/package.json"
	[[ -f "$pinned_dir/package-lock.json" ]] \
		|| die "pinned package-lock.json not found (run npm install" \
			"--package-lock-only in $pinned_dir)"
}

#===============================================================================
# ELF verification helpers
#===============================================================================
# Print the 4-byte ELF magic of $1 as lowercase hex (empty on read failure).
elf_magic() {
	LC_ALL=C od -An -j0 -N4 -tx1 "$1" 2>/dev/null | tr -d ' \n'
}

# Print the 2-byte e_machine of $1 (offset 18, little-endian) as hex.
elf_machine_of() {
	LC_ALL=C od -An -j18 -N2 -tx1 "$1" 2>/dev/null | tr -d ' \n'
}

# Fail unless $1 is a linux ELF for the expected arch, with no surprise OpenSSL
# shared-lib dependency (better-sqlite3-multiple-ciphers vendors SQLCipher; a
# NEEDED libcrypto/libssl would mean a runtime dep that breaks on distros with a
# different OpenSSL soname -- and the encrypted DB is the core data path).
verify_node() {
	local f="$1" magic machine needed
	[[ -f $f ]] || die "expected output missing: $f"

	magic="$(elf_magic "$f")"
	[[ $magic == '7f454c46' ]] \
		|| die "$f is not a linux ELF (magic=$magic)"

	machine="$(elf_machine_of "$f")"
	[[ $machine == "$elf_machine" ]] \
		|| die "$f e_machine=$machine, expected $elf_machine ($asset_arch)"

	needed="$(readelf -d "$f" 2>/dev/null \
		| grep -iE 'NEEDED.*(libcrypto|libssl)')"
	if [[ -n $needed ]]; then
		die "$f dynamically links OpenSSL ($needed) -- want a vendored/static" \
			"SQLCipher build; this would break on distros with a different" \
			"libcrypto soname. Fix the build flags, do not ship this."
	fi
}

# Validate the harvested addons under Electron via the shared smoke test (ABI +
# encrypted-DB round-trip + wrong-key reject). Skipped (loud warning) when
# ELECTRON_BIN is unset -- in CI the producer runs the same smoke test in a
# separate job on a full runner, since Electron may not start on the minimal
# old-glibc build container.
verify_smoke() {
	if [[ -z ${ELECTRON_BIN:-} ]]; then
		log 'WARNING: ELECTRON_BIN unset -- skipping the ABI + encrypted-DB smoke'
		log '  test. A wrong-ABI build (e.g. compiled against system Node headers)'
		log '  will NOT be caught here. Set ELECTRON_BIN to the staged Electron 42.'
		return 0
	fi
	bash "$pinned_dir/smoke-test.sh" "$out_dir" "$ELECTRON_BIN" "$ELECTRON_ABI" \
		|| die 'smoke test failed (see above)'
}

#===============================================================================
# the rebuild
#===============================================================================
main() {
	preflight

	local scratch
	scratch="$(mktemp -d)" || die 'mktemp failed'
	if [[ ${REBUILD_KEEP:-0} != 1 ]]; then
		# shellcheck disable=SC2064  # expand $scratch now, at trap-set time
		trap "rm -rf '$scratch'" EXIT
	else
		log "REBUILD_KEEP=1 -- scratch dir retained: $scratch"
	fi

	# Pristine, lockfile-pinned install. --ignore-scripts so the package's own
	# install-time node-gyp (which would target the HOST Node ABI) never runs;
	# @electron/rebuild below is the only compile, against Electron's ABI.
	log "Installing pinned deps (npm ci, --ignore-scripts) ..."
	cp "$pinned_dir/package.json" "$scratch/package.json"
	cp "$pinned_dir/package-lock.json" "$scratch/package-lock.json"
	( cd "$scratch" \
		&& npm ci --ignore-scripts --no-audit --no-fund >&2 ) \
		|| die 'npm ci failed (network? lockfile drift?)'

	local bsc_src="$scratch/node_modules/better-sqlite3-multiple-ciphers"
	[[ -d "$bsc_src/src" ]] \
		|| die "patched source tree absent: $bsc_src/src"

	# Apply the V8 14.8 patch to the PRISTINE checkout. --forward skips an
	# already-applied patch cleanly; --fuzz=0 refuses an imperfect match so a
	# drifted patch hard-fails instead of landing a half-correct build.
	log 'Applying V8 14.8 patch to better-sqlite3-multiple-ciphers ...'
	( cd "$bsc_src" \
		&& patch -p1 --forward --fuzz=0 < "$patch_file" >&2 ) \
		|| die 'V8 patch did not apply cleanly (drift vs pinned version?)'

	# Rebuild against Electron's headers in an ISOLATED gyp dir, so a stray
	# ~/.electron-gyp / ~/.node-gyp / env cannot feed wrong (system Node)
	# headers -- the patch is V8_MAJOR_VERSION-guarded and would compile clean
	# against the wrong V8, masking an ABI-broken binary.
	log "Rebuilding for Electron $electron_version (linux-$electron_arch) ..."
	(
		cd "$scratch" \
			&& export npm_config_runtime='electron' \
			&& export npm_config_target="$electron_version" \
			&& export npm_config_disturl='https://electronjs.org/headers' \
			&& export npm_config_arch="$electron_arch" \
			&& export npm_config_devdir="$scratch/.electron-gyp" \
			&& npx --yes @electron/rebuild -v "$electron_version" -f \
				-w better-sqlite3-multiple-ciphers -w sqlite3 \
				--arch="$electron_arch" >&2
	) || die '@electron/rebuild failed'

	# Harvest -- note the two packages emit DIFFERENT .node names.
	cp "$bsc_src/build/Release/better_sqlite3.node" \
		"$out_dir/better_sqlite3.node" \
		|| die 'better_sqlite3.node not produced'
	cp "$scratch/node_modules/sqlite3/build/Release/node_sqlite3.node" \
		"$out_dir/node_sqlite3.node" \
		|| die 'node_sqlite3.node not produced'

	# Verify what we produced before anyone trusts it.
	log 'Verifying outputs (ELF, arch, OpenSSL linkage) ...'
	verify_node "$out_dir/better_sqlite3.node"
	verify_node "$out_dir/node_sqlite3.node"
	verify_smoke

	# Checksums (consumer verifies these against the release assets).
	( cd "$out_dir" \
		&& sha256sum better_sqlite3.node node_sqlite3.node \
			> SHA256SUMS ) \
		|| die 'sha256sum failed'

	# Provenance stamp -- the consumer skips a rebuild/refetch ONLY when this
	# matches the build's (electron, pkg, patch) tuple. ELF magic alone cannot
	# tell a stale wrong-ABI binary from a correct one; this can.
	local patch_sha glibc gcc bsc_sha sqlite_sha
	patch_sha="$(sha256sum "$patch_file" | cut -d' ' -f1)"
	glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $NF}')"
	glibc="${glibc:-unknown}"
	gcc="$( { c++ --version || g++ --version; } 2>/dev/null | head -1)"
	bsc_sha="$(sha256sum "$out_dir/better_sqlite3.node" | cut -d' ' -f1)"
	sqlite_sha="$(sha256sum "$out_dir/node_sqlite3.node" | cut -d' ' -f1)"

	cat > "$out_dir/native-modules.lock" <<JSON
{
	"electron_version": "$electron_version",
	"abi": "$ELECTRON_ABI",
	"arch": "$asset_arch",
	"packages": {
		"better-sqlite3-multiple-ciphers": "$BSC_VERSION",
		"sqlite3": "$SQLITE_VERSION",
		"@electron/rebuild": "$REBUILD_VERSION"
	},
	"patch_sha256": "$patch_sha",
	"better_sqlite3_sha256": "$bsc_sha",
	"node_sqlite3_sha256": "$sqlite_sha",
	"build_glibc": "$glibc",
	"build_cc": "$gcc"
}
JSON

	log "Done. Wrote to $out_dir :"
	log '  better_sqlite3.node  node_sqlite3.node  SHA256SUMS  native-modules.lock'
}

main "$@"
