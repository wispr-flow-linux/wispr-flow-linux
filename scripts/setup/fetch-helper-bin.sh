#!/usr/bin/env bash
#===============================================================================
# fetch-helper-bin.sh -- download the pinned prebuilt clean-room helper binary
# for a target arch and print its path (for the HELPER_BIN env var build.sh
# consumes).
#
# The helper lives in its own repo (github.com/wispr-flow-linux/helper) and is
# consumed as a prebuilt release asset pinned in helper-version.txt. Each release
# ships one binary per arch:
#   wispr-flow-linux-helper-x86_64    (amd64)
#   wispr-flow-linux-helper-aarch64   (arm64)
#
# This stages the matching asset into <dest>/wispr-flow-linux-helper, marks it
# executable, stamps the fetched tag into <dest>/.tag (so the staging engine
# can refetch when helper-version.txt moves past a cached copy), and prints
# that absolute path to stdout (diagnostics go to stderr).
# CI sets HELPER_BIN="$(scripts/setup/fetch-helper-bin.sh <arch>)" before
# invoking build.sh.
#
# Usage:   fetch-helper-bin.sh <arch> [dest_dir]
#   <arch>      x86_64 | aarch64 | amd64 | arm64
#   dest_dir    where to place the binary (default: <repo>/helper-bin)
#
# Requires: gh (authenticated) OR curl. Exit 0 on success.
#===============================================================================
set -uo pipefail

readonly HELPER_REPO='wispr-flow-linux/helper'

log() { printf '%s\n' "$*" >&2; }
die() { printf 'fetch-helper-bin: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 ]] || die 'usage: fetch-helper-bin.sh <arch> [dest_dir]'

# Normalize arch aliases to the asset suffix the helper release uses.
case "$1" in
	x86_64|amd64|x64) asset_arch='x86_64' ;;
	aarch64|arm64)    asset_arch='aarch64' ;;
	*) die "unsupported arch: $1 (want x86_64|aarch64|amd64|arm64)" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
dest_dir="${2:-$repo_root/helper-bin}"

version_file="$repo_root/helper-version.txt"
[[ -f $version_file ]] || die "helper-version.txt not found at ${version_file}"
tag="$(tr -d '[:space:]' < "$version_file")"
[[ -n $tag ]] || die 'helper-version.txt is empty'

asset="wispr-flow-linux-helper-${asset_arch}"
dest_bin="$dest_dir/wispr-flow-linux-helper"

mkdir -p "$dest_dir" || die "cannot create ${dest_dir}"

log "Fetching ${asset} from ${HELPER_REPO}@${tag} ..."

url="https://github.com/${HELPER_REPO}/releases/download/${tag}/${asset}"
fetched=false

# Prefer gh (honors auth/rate limits); fall back to curl on absence OR failure
# (github.token may lack cross-repo scope, but the release is public).
if command -v gh >/dev/null 2>&1; then
	tmp_dir="$(mktemp -d)"
	if gh release download "$tag" --repo "$HELPER_REPO" \
		--pattern "$asset" --dir "$tmp_dir" --clobber >&2; then
		mv "$tmp_dir/$asset" "$dest_bin" || die 'failed to move downloaded helper'
		fetched=true
	else
		log "gh release download failed; falling back to curl"
	fi
	rm -rf "$tmp_dir"
fi

if [[ $fetched == false ]]; then
	command -v curl >/dev/null 2>&1 \
		|| die 'gh unavailable/failed and curl is not installed'
	curl -fSL -o "$dest_bin" "$url" || die "curl download failed: ${url}"
fi

[[ -s $dest_bin ]] || die "downloaded helper is empty: ${dest_bin}"
chmod 0755 "$dest_bin" || die "cannot chmod ${dest_bin}"

# Stamp the tag this binary came from. resolve_helper_bin (build-linux.sh)
# compares it against helper-version.txt and refetches a stale cache after a
# pin bump; a manually pre-dropped binary has no stamp and is used as-is.
printf '%s\n' "$tag" > "$dest_dir/.tag" || die "cannot write ${dest_dir}/.tag"

log "Staged helper at ${dest_bin}"
printf '%s\n' "$dest_bin"
