#!/usr/bin/env bash
#===============================================================================
# patch-linux-status-compact.sh -- shrink the status-pill window to the pill's
# own footprint on Linux, in the Wispr Flow main bundle (.webpack/main/index.js).
#
# The bottom-docked status window is created 440x320, far larger than the pill
# it draws (98x30 at its largest, bottom-centred, 14px above the window bottom).
# Wispr makes the unused transparent canvas click-through by polling the pixel
# under the cursor and toggling setIgnoreMouseEvents; on native Wayland that
# does not work, so the whole invisible 440x320 box swallows clicks. The window
# is created resizable:false, so the compositor cannot shrink it either -- the
# size has to be fixed where the app computes it.
#
# Anchor: the default (bottom-edge) branch of the status-bounds function,
#   return{x:<o>+(<l>-440)/2,y:<c>+<d>-<s>,width:440,height:<s>}
# On Linux it returns a 200x110 box instead (still bottom-centred). Toasts that
# the status window draws above the pill are clipped as a result.
#
# Usage: patch-linux-status-compact.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -uo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
	echo "usage: $0 <.webpack/main/index.js>" >&2
	exit 2
fi

MARKER='WISPR_LINUX_STATUS_COMPACT'
if grep -qF "$MARKER" "$BUNDLE"; then
	echo "Already patched ($MARKER present) - nothing to do."
	exit 0
fi

cp -p "$BUNDLE" "$BUNDLE.statuscompact.orig" || exit 1

python3 - "$BUNDLE" "$MARKER" <<'PY' || exit 1
import io, re, sys
path, marker = sys.argv[1], sys.argv[2]
src = io.open(path, encoding="utf-8", errors="surrogateescape").read()
anchor = re.compile(
	r'return\{x:(?P<o>[\w$]+)\+\((?P<l>[\w$]+)-440\)/2,'
	r'y:(?P<c>[\w$]+)\+(?P<d>[\w$]+)-(?P<s>[\w$]+),'
	r'width:440,height:(?P=s)\}'
)
m = list(anchor.finditer(src))
if len(m) != 1:
	sys.exit(f"ERROR: expected 1 status-bounds anchor, found {len(m)}")
def sub(m):
	o, l, c, d = m['o'], m['l'], m['c'], m['d']
	return (
		'return(/*' + marker + '*/"linux"===process.platform)'
		f'?{{x:{o}+({l}-200)/2,y:{c}+{d}-110,width:200,height:110}}'
		':' + m.group(0)[len('return'):]
	)
src = anchor.sub(sub, src, count=1)
io.open(path, 'w', encoding="utf-8", errors="surrogateescape").write(src)
print("Patched: status window is 200x110 on Linux.")
PY

if ! grep -qF "$MARKER" "$BUNDLE" || ! node --check "$BUNDLE"; then
	echo "ERROR: verification failed; restoring backup." >&2
	cp -p "$BUNDLE.statuscompact.orig" "$BUNDLE"
	exit 1
fi
echo "OK: status window compacted on Linux in $BUNDLE"
