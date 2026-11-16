#!/usr/bin/env bash
#===============================================================================
# linux-status-surface-report.sh -- let the Status renderer report its visible
# surfaces on Linux, and send the initial report, in the renderer bundle
# (.webpack/renderer/status/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# linux-status-idle-unmap.sh unmaps the Status window while the renderer
# reports no visible surface, so the idle transparent canvas stops swallowing
# clicks. It reads upstream's own status:reportAlphaCatchRects report, which
# has two platform gaps on Linux:
#
#   * shapeRects (the visual-only surfaces: the idle pill's own shape, the
#     hover tooltip, the language pill) are only filled when upstream's
#     platform flag says Windows, and the collector's selector omits
#     data-status-window-shape on Linux, so those elements are never even
#     scanned; and
#   * the collector reports only when a rectangle changes, so a Status window
#     that maps with nothing to report never sends one and the shim cannot
#     tell "no surface" from "no report yet".
#
# The click-through rectangles (rects) are platform-neutral; only the shape
# half is gated.
#
# THE ANCHOR
# ----------
# The collector is a webpack module that
#
#   * contains the developer string "flow-bar-hot-area" (the Status renderer's
#     own surface registration) exactly once,
#   * declares `const s="data-alpha-catch"` (the click-through attribute),
#   * reads the platform flag `i.H8` exactly three times inside the collector:
#     the remeasure dispatcher, the per-element shape test, and the initial
#     scan's selector; and
#   * registers `status-window-shape-remeasure` then scans once.
#
# The module opening and end are found structurally, the platform-flag read is
# captured by name, and the three reads are asserted before anything is
# written. Matches exactly once in 1.6.1209 and 1.6.1264 (the same module
# shape also shipped on 1.6.897 and 1.6.1147).
#
# THE PATCH
# ---------
# 1. Each of the three platform-flag reads becomes
#      (<flag>||"linux"===window.electron.platform.os)
#    so Linux fills shapeRects from the same elements Windows does and scans
#    for them. The idle pill's hot area (registered through upstream's own
#    hook into rects) is platform-neutral and is reported on Linux unchanged.
# 2. The initial scan is followed by the report queue's flush
#    (`<queue>(),()=>`), so the shim receives one report even when the window
#    maps with no surfaces.
#
# Verified against 1.6.1209 and 1.6.1264.
#
# Usage: linux-status-surface-report.sh <path-to-.webpack/renderer/status/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_STATUS_SURFACE_REPORT" "${1:-}"

if ! python3 - "$BUNDLE" "$MARKER" <<'PY'
import io
import re
import sys

path, marker = sys.argv[1:]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    source = f.read()
Q = r'[`"\']'
ID = r'[\w$]+'

def unique(pattern, text, label):
    matches = list(re.finditer(pattern, text))
    if len(matches) != 1:
        sys.exit(f'ERROR: expected one {label}, found {len(matches)}')
    return matches[0]

unique(Q + 'flow-bar-hot-area' + Q, source, 'semantic flow-bar reporter')
anchor = unique(r'(?:const|let|var) ' + ID + '=' + Q + 'data-alpha-catch' + Q,
                source, 'Status rectangle collector')
openers = list(re.finditer(r'\d+\(' + ID + ',' + ID + ',' + ID + r'\)\{'
                          + Q + 'use strict' + Q + ';', source[:anchor.start()]))
if not openers:
    sys.exit('ERROR: cannot locate collector module opening')
start = openers[-1].start()
following = re.search(r'\},\d+\(' + ID + ',' + ID + ',' + ID + r'\)\{',
                      source[anchor.end():])
if not following:
    sys.exit('ERROR: cannot locate collector module end')
end = anchor.end() + following.start() + 1
collector = source[start:end]
shape = unique('(' + ID + ')=' + Q + 'data-status-window-shape' + Q,
               collector, 'visual surface attribute').group(1)
event = unique('(' + ID + ')=' + Q + 'status-window-shape-remeasure' + Q,
               collector, 'remeasure event').group(1)
gate = unique(r'(' + ID + r'\.' + ID + r')&&' + ID + r'\?\.hasAttribute\('
              + re.escape(shape) + r'\)', collector, 'visual surface platform gate').group(1)
if collector.count(gate) != 3:
    sys.exit('ERROR: expected three matching visual-surface platform reads')
# The resize callback both scans DOM and forces a report when geometry changes.
resize = unique(r'(' + ID + r')=\(\)=>\{(' + ID + r')\(\),(' + ID
                + r')\(\)\};window\.addEventListener\(' + Q + 'resize' + Q
                + r',\1\)', collector, 'resize report callback')
queue = resize.group(3)
initial = unique(r'document\.addEventListener\(' + re.escape(event) + ','
                 + ID + r',!0\),(' + ID + r')\(\),\(\)=>',
                 collector, 'initial surface scan')
# Force a report even if all maps start empty (nothing changed during scan).
collector = (collector[:initial.end()] .removesuffix('()=>') + queue + '(),()=>'
             + collector[initial.end():])
collector = collector.replace(gate, '(' + gate + '||"linux"===window.electron.platform.os)')
patched = source[:start] + '/*' + marker + '*/' + collector + source[end:]
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(patched)
print('Patched Status visual surfaces and initial report for Linux')
PY
then
	patch_restore
	exit 1
fi
patch_verify_marker
patch_expect_shape -qF '||"linux"===window.electron.platform.os)' \
	-- 'Linux surface-report gate missing'
patch_finish "Status renderer reports Linux visible surfaces in $BUNDLE"
