#!/usr/bin/env bash
#===============================================================================
# linux-status-compact.sh -- shrink the status-pill window to the pill's own
# footprint on Linux, in the Wispr Flow main bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# The bottom-docked status window is far larger than the pill it draws: 440x320
# up to 1.6.957, 512x614 in 1.6.1209 and 1.6.1264, with the pill bottom-centred
# 14px above the window bottom. Wispr makes the unused transparent canvas
# click-through by polling the pixel under the cursor and toggling
# setIgnoreMouseEvents; on native Wayland that does not work, so the whole
# invisible box swallows clicks. The window is created resizable:false, so the
# compositor cannot shrink it either -- the size has to be fixed where the app
# computes it. The size also matters to Mutter: it refuses focus on map to a
# window mostly covered by an "above" window, so a 512x614 pill window kept on
# top by the helper's GNOME extension takes focus from anything small that maps
# near the bottom centre (wl-clipboard's surface included).
#
# THE ANCHOR
# ----------
# The default (bottom-edge) branch of the status-bounds function returns a
# horizontally centred box whose x offset and width use the same width value,
# and whose y offset and height use the same height value:
#
#   1.6.957 and earlier (literal width):
#     return{x:o+(l-440)/2,y:c+d-s,width:440,height:s}
#   1.6.1209 and 1.6.1264 (width and height are default parameters):
#     p=(e,t,n,r,s,o=320,a=i,l=440)=>{...return{x:u+(h-l)/2,y:p+m-o,
#       width:l,height:o}}
#
# Every name is captured as [\w$]+ (a literal width is matched by the same
# class) and the width/height are back-referenced, so the anchor is the
# centred-bottom shape itself, not any minified name or number. It matches
# exactly once in both 1.6.1209 and 1.6.1264 (checked by @Z3roS4n on the
# shipped bytes, PR #67); the count is asserted before anything is written.
#
# THE PATCH
# ---------
# On Linux the branch returns a 200x110 box instead, still bottom-centred:
#
#   return(/*WISPR_LINUX_STATUS_COMPACT*/"linux"===process.platform)
#     ?{x:u+(h-200)/2,y:p+m-110,width:200,height:110}
#     :{x:u+(h-l)/2,y:p+m-o,width:l,height:o}
#
# Toasts that the status window draws above the pill are clipped as a result.
#
# Usage: linux-status-compact.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_STATUS_COMPACT" "${1:-}"

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()

ID = r'[\w$]+'
anchor = re.compile(
	r'return\{x:(?P<o>' + ID + r')\+\((?P<l>' + ID + r')-(?P<w>' + ID
	+ r')\)/2,y:(?P<c>' + ID + r')\+(?P<d>' + ID + r')-(?P<s>' + ID
	+ r'),width:(?P=w),height:(?P=s)\}'
)
ms = list(anchor.finditer(src))
if len(ms) != 1:
	sys.exit(
		f"ERROR: expected 1 status-bounds anchor, found {len(ms)}. Bundle "
		f"layout may have changed; re-audit the status window's bounds "
		f"function (see this script's header) before patching.")

m = ms[0]
o, l, c, d = m['o'], m['l'], m['c'], m['d']
text = (
	'return(/*' + marker + '*/"linux"===process.platform)'
	f'?{{x:{o}+({l}-200)/2,y:{c}+{d}-110,width:200,height:110}}'
	':' + m.group(0)[len('return'):]
)
src = src[:m.start()] + text + src[m.end():]

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(src)
print("Patched: status window is 200x110 on Linux.")
PY

# --- Verify the result --------------------------------------------------------
patch_verify_marker
patch_expect_shape -qF \
	'return(/*'"$MARKER"'*/"linux"===process.platform)?{x:' \
	-- 'compact status-bounds branch not in expected form.'

patch_finish "status window compacted on Linux in $BUNDLE"
