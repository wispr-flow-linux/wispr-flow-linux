#!/usr/bin/env bash
#===============================================================================
# linux-status-idle-unmap.sh -- genuinely unmap the idle "Flow Status
# Indicator" window on Linux, in the main bundle (.webpack/main/index.js).
#
# The bar can be visually hidden while its transparent native window remains
# mapped. In the reported GNOME/XWayland failure, native input rectangles
# excluded the dead pixel but physical clicks still failed. Unmapping Status
# restored clicks; remapping brought the failure back. Refs #71 and #76.
#
# linux-status-idle-unmap.js (beside this file) wraps the Status window's
# show/showInactive/hide so Wispr's native intent is preserved (`wanted`)
# and reconciles actual visibility against the renderer's semantic surface
# report on upstream's own status:reportAlphaCatchRects channel: the window
# is mapped only while wanted AND a live visual surface (recording
# indicator, notification, ...) is reported, and genuinely hidden otherwise.
# The report is accepted only from the Status window's own main frame loaded
# from renderer/status/index.html, with well-formed rectangle lists and a
# viewport matching the window's current content bounds at its zoom factor.
# The sibling renderer patch (linux-status-surface-report.sh, marker
# WISPR_LINUX_STATUS_SURFACE_REPORT) widens the collector so that report
# fires on Linux with shapeRects/viewport; this patch is separate from the
# always-on-top work in PR #73.
#
# Replacing the methods rather than patching each caller keeps this patch
# free of minified-identifier anchors: it only needs a place to stand at the
# top of the bundle. What it does depend on is upstream's Status window
# contract, checked fail-closed below before anything is written:
#
#   title:"Flow Status Indicator"                      the window the shim
#                                                      recognises by title
#   ReportAlphaCatchRects="status:reportAlphaCatchRects"
#                                                      the channel it listens on
#   "status","preload.js"),backgroundThrottling:!1     the Status window's
#                                                      webPreferences the shim
#                                                      pins at runtime
#
# Structural contracts use quote classes and exact occurrence counts.
#
# Insertion: right after the webpack license banner on line 1 when there is
# one (the same slot linux-early-singleton.sh and linux-autostart.sh use;
# none of the three depends on another's order), else at byte 0. The
# injected code has no side effects at load beyond registering one
# browser-window-created listener and one ipcMain listener.
#
# Verified against the pristine 1.6.1147 bundle.
#
# Usage: linux-status-idle-unmap.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_STATUS_IDLE_UNMAP" "${1:-}"

SHIM="$PATCH_LIB_DIR/linux-status-idle-unmap.js"

if ! python3 - "$BUNDLE" "$MARKER" "$SHIM" <<'PY'
import io, sys, re

path, marker, shim_path = sys.argv[1], sys.argv[2], sys.argv[3]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()
with io.open(shim_path, "r", encoding="utf-8") as f:
	shim = f.read()

if not shim.startswith("/*" + marker + "*/"):
	sys.exit(f"ERROR: {shim_path} must open with the {marker} marker.")
if not shim.endswith("\n"):
	shim += "\n"

# Upstream Status-window contract, each exactly once (tripwires.tsv mirrors
# these). A miss is "upstream changed the contract", not "the anchor moved":
# fail closed and leave the bundle untouched.
Q = r'[`"\']'
contract = {
	"Status window title": 'title:' + Q + 'Flow Status Indicator' + Q,
	"alpha-catch-rects channel": 'ReportAlphaCatchRects=' + Q + 'status:reportAlphaCatchRects' + Q,
	"Status window backgroundThrottling": Q + 'status' + Q + ',' + Q + r'preload\.js' + Q + r'\),backgroundThrottling:!1',
}
for label, pattern in contract.items():
	count = len(re.findall(pattern, src))
	if count != 1:
		sys.exit(f"ERROR: upstream contract changed: {label} found {count} times, expected 1.")

first, nl, rest = src.partition("\n")
if first.startswith("/*!") and first.rstrip().endswith("*/") and nl:
	src = first + "\n" + shim + rest
	where = "after the license banner"
else:
	src = shim + src
	where = "at the top of the bundle"

if src.count(marker) != 1:
	sys.exit("ERROR: expected the marker exactly once after injection.")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(src)
print(f"Patched: status idle-unmap shim injected {where}.")
PY
then
	patch_restore
	exit 1
fi

patch_verify_marker

patch_finish "Linux idle Status window genuinely unmapped in $BUNDLE"
