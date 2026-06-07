#!/usr/bin/env bash
#===============================================================================
# fetch-native-bin.sh -- download the pinned prebuilt Linux native sqlite addons
# for a target arch, verify them, and print their directory (for the
# NATIVE_MODULES_DIR env var build-linux.sh consumes).
#
# The addons (better_sqlite3.node + node_sqlite3.node) are rebuilt from public
# npm + the in-repo V8 patch by .github/workflows/build-native-modules.yml and
# published as release assets pinned in native-modules-version.txt. Each release
# ships, per arch:
#   better_sqlite3-x86_64.node   node_sqlite3-x86_64.node
#   better_sqlite3-aarch64.node  node_sqlite3-aarch64.node
#   native-modules-<arch>.lock   (provenance)   SHA256SUMS (over all .node)
#
# This stages the matching pair into <dest>/{better_sqlite3,node_sqlite3}.node
# (the plain names the Step-4 swap expects), AFTER:
#   1. sha256 verification against the release's SHA256SUMS, and
#   2. provenance verification -- the asset's native-modules.lock patch_sha256
#      MUST equal this checkout's patch file, and its ABI must be 146. This is
#      what makes the binary trustworthy: ELF magic alone cannot tell a stale,
#      wrong-ABI, or wrong-patch build from a correct one.
# It prints the dest dir to stdout (diagnostics go to stderr). CI sets
# NATIVE_MODULES_DIR="$(scripts/setup/fetch-native-bin.sh <arch>)" before build.
#
# Usage:   fetch-native-bin.sh <arch> [dest_dir]
#   <arch>      x86_64 | aarch64 | amd64 | arm64 | x64
#   dest_dir    where to place the binaries (default: <repo>/native-modules)
# Env:
#   EXPECT_ELECTRON_VERSION   if set, the lock's electron_version must match it
#
# Requires: gh (authenticated) OR curl; sha256sum. Exit 0 on success.
#===============================================================================
set -uo pipefail

readonly NATIVE_REPO='wispr-flow-linux/wispr-flow-linux'
readonly EXPECT_ABI='146'

log() { printf '%s\n' "$*" >&2; }
die() { printf 'fetch-native-bin: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 ]] || die 'usage: fetch-native-bin.sh <arch> [dest_dir]'

case "$1" in
	x86_64|amd64|x64) asset_arch='x86_64' ;;
	aarch64|arm64)    asset_arch='aarch64' ;;
	*) die "unsupported arch: $1 (want x86_64|aarch64|amd64|arm64|x64)" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
dest_dir="${2:-$repo_root/native-modules}"

version_file="$repo_root/native-modules-version.txt"
[[ -f $version_file ]] || die "native-modules-version.txt not found"
tag="$(tr -d '[:space:]' < "$version_file")"
[[ -n $tag ]] || die 'native-modules-version.txt is empty'

patch_rel='scripts/patches/v8-14.8-better-sqlite3-multiple-ciphers.patch'
patch_file="$repo_root/$patch_rel"
[[ -f $patch_file ]] || die "patch file not found: $patch_file"

command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required'

mkdir -p "$dest_dir" || die "cannot create ${dest_dir}"
dest_dir="$(cd "$dest_dir" && pwd)"

bsc_asset="better_sqlite3-${asset_arch}.node"
sqlite_asset="node_sqlite3-${asset_arch}.node"
lock_asset="native-modules-${asset_arch}.lock"
tmp_dir="$(mktemp -d)" || die 'mktemp failed'
# shellcheck disable=SC2064  # expand $tmp_dir now, at trap-set time
trap "rm -rf '$tmp_dir'" EXIT

log "Fetching ${asset_arch} native modules from ${NATIVE_REPO}@${tag} ..."

# Download an asset by name into $tmp_dir: prefer gh (auth/rate limits), fall
# back to curl on absence OR failure (the release is public). Mirrors
# fetch-helper-bin.sh.
fetch_asset() {
	local name="$1" url
	url="https://github.com/${NATIVE_REPO}/releases/download/${tag}/${name}"
	if command -v gh >/dev/null 2>&1; then
		if gh release download "$tag" --repo "$NATIVE_REPO" \
			--pattern "$name" --dir "$tmp_dir" --clobber >&2; then
			return 0
		fi
		log "gh download of ${name} failed; falling back to curl"
	fi
	command -v curl >/dev/null 2>&1 \
		|| die "gh unavailable/failed and curl is not installed"
	curl -fSL -o "$tmp_dir/$name" "$url" \
		|| die "download failed: ${url}"
}

fetch_asset "$bsc_asset"
fetch_asset "$sqlite_asset"
fetch_asset "$lock_asset"
fetch_asset 'SHA256SUMS'

# 1. Checksum verification -- check only this arch's two lines so other-arch
#    assets we did not download do not fail the -c run.
log 'Verifying checksums ...'
grep -E "  \./($bsc_asset|$sqlite_asset)\$" "$tmp_dir/SHA256SUMS" \
	> "$tmp_dir/SHA256SUMS.arch" \
	|| die "SHA256SUMS has no entries for ${asset_arch}"
( cd "$tmp_dir" && sha256sum -c SHA256SUMS.arch >&2 ) \
	|| die 'checksum verification FAILED'

# 2. Provenance verification -- read a "key": "value" string from the lock.
lock_field() {
	grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$tmp_dir/$lock_asset" \
		| head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}
log 'Verifying provenance (patch + ABI) ...'
asset_patch="$(lock_field patch_sha256)"
repo_patch="$(sha256sum "$patch_file" | cut -d' ' -f1)"
[[ -n $asset_patch ]] || die 'lock has no patch_sha256'
[[ $asset_patch == "$repo_patch" ]] \
	|| die "patch mismatch: asset built with ${asset_patch}, this checkout has" \
		"${repo_patch} -- republish native modules for the current patch"
asset_abi="$(lock_field abi)"
[[ $asset_abi == "$EXPECT_ABI" ]] \
	|| die "ABI mismatch: asset abi=${asset_abi}, expected ${EXPECT_ABI}"
if [[ -n ${EXPECT_ELECTRON_VERSION:-} ]]; then
	asset_ev="$(lock_field electron_version)"
	[[ $asset_ev == "$EXPECT_ELECTRON_VERSION" ]] \
		|| die "electron mismatch: asset=${asset_ev}," \
			"expected ${EXPECT_ELECTRON_VERSION}"
fi

# Stage under the plain names the Step-4 swap reads, plus the provenance lock.
cp "$tmp_dir/$bsc_asset" "$dest_dir/better_sqlite3.node" \
	|| die 'failed to stage better_sqlite3.node'
cp "$tmp_dir/$sqlite_asset" "$dest_dir/node_sqlite3.node" \
	|| die 'failed to stage node_sqlite3.node'
cp "$tmp_dir/$lock_asset" "$dest_dir/native-modules.lock" || true

log "Staged native modules at ${dest_dir}"
printf '%s\n' "$dest_dir"
