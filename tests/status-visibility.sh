#!/usr/bin/env bash
# Exercise real Electron IPC and native XWayland mapping with no signed-in profile.
set -uo pipefail
src=$(cd "$(dirname "$0")" && pwd) || exit 1
if [[ $# != 1 || ! -x $1 ]]; then
	echo "Usage: $0 <Electron executable>" >&2
	exit 2
fi
exe=$(realpath "$1") || exit 1
runtime=$(dirname "$exe")
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
for entry in "$runtime"/*; do
	name=$(basename "$entry")
	[[ $name == resources || $entry == "$exe" ]] && continue
	ln -s "$entry" "$work/$name" || exit 1
done
cp "$exe" "$work/electron" || exit 1
mkdir -p "$work/resources/app" "$work/tmp" || exit 1
cp "$src/../scripts/patches/linux-status-idle-unmap.js" \
	"$work/resources/app/" || exit 1
cp "$src/status-visibility.cjs" "$work/resources/app/" || exit 1
printf '%s\n' \
	'{"name":"wispr-visibility-test","version":"1.0.0","main":"status-visibility.cjs"}' \
	> "$work/resources/app/package.json" || exit 1
TMPDIR="$work/tmp" "$work/electron" --no-sandbox --ozone-platform=x11
