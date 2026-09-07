#!/usr/bin/env bash
#===============================================================================
# linux-status-position.sh
#
# Fixes the status pill / context-menu window position on Linux in the
# webpack-bundled Electron main process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# Two position-helper functions (v() for ContextMenuWindow, D() for
# StatusWindow) share a common bug: when computing the usable screen height
# they incorrectly add the bottom inset on Linux.
#
# The helpers follow this pattern:
#
#   let n = e.workAreaSize.height;
#   const i = bounds.height - workArea.height - topInset; // bottom inset
#   return <H8>
#          || <RA>.dockInfo.isVisible && <RA>.dockInfo.x === e.bounds.x
#                                     && <RA>.dockInfo.y === e.bounds.y
#          || (n += i),               // ← BUG on Linux
#          ...
#          { height: n }
#
# Intent:
#   • Windows (H8=true):  workArea already excludes the taskbar → skip n+=i.
#   • macOS visible Dock: workArea already excludes the Dock → skip n+=i.
#   • macOS hidden Dock:  extend n to the full screen bottom.
#
# On Linux, H8 is false and dockInfo (Mac-only) is absent, so (n+=i) fires
# unconditionally, pushing the window behind the GNOME panel.
#
# AUTOHIDE DOCK (second fix)
# --------------------------
# When Ubuntu Dock runs in autohide mode, _NET_WORKAREA does NOT reserve
# any space for the dock, so i = 0. Skipping n+=i has no effect; the pill
# bottom coincides with the physical screen bottom and overlaps the dock.
#
# Fix: after skipping n+=i, subtract a fixed clearance (56 CSS pixels) on
# Linux when i = 0. This places the pill just above the autohide dock:
#
#   dock height (icon-size 34, GNOME scale 5/3, Electron DPR 2):
#     (34 + 2×10) × (5/3) / 2 ≈ 45 CSS px
#   clearance applied:             56 CSS px
#   gap above dock:                ~11 CSS px
#
# For fixed (non-autohide) docks i > 0, so !i is false and the clearance
# is not applied — the pill lands exactly at the dock top.
#
# TWO AFFECTED FUNCTIONS
# ----------------------
# The same bug appears in two separate webpack modules:
#   v() – ContextMenuWindow position helper
#   D() – StatusWindow position helper
# Both are patched by a single regex (two matches, EXPECTED = 2).
#
# Usage: linux-status-position.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	BUNDLE="$(cd "$BUNDLE/.." && pwd)/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

LINUX_MARKER="WISPR_LINUX_STATUS_POSITION"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Anchor: the bottom-inset guard in the workArea height helpers.
#
# Pattern (both v() and D() share this shape):
#   <sym>.H8 || <ra>.RA.dockInfo.isVisible
#            && <ra>.RA.dockInfo.x === e.bounds.x
#            && <ra>.RA.dockInfo.y === e.bounds.y
#            || (n += i)
#
# Capture groups:
#   H8   – the isWindows flag (e.g. c.H8, d.H8)
#   rest – everything from the first || through ||(n+=i)
#   RA   – the store module symbol — used as backreference to avoid
#          false positives where two different RA symbols appear
site = re.compile(
    r'(?P<H8>[\w$]+\.H8)'
    r'(?P<rest>'
        r'\|\|(?P<RA>[\w$]+)\.RA\.dockInfo\.isVisible'
        r'&&(?P=RA)\.RA\.dockInfo\.x===e\.bounds\.x'
        r'&&(?P=RA)\.RA\.dockInfo\.y===e\.bounds\.y'
        r'\|\|\(n\+=i\)'
    r')'
)

matches = list(site.finditer(data))
EXPECTED = 2   # v() = context-menu, D() = status window
if len(matches) != EXPECTED:
    sys.exit(
        f"ERROR: expected exactly {EXPECTED} workArea bottom-inset guard(s), "
        f"found {len(matches)}. "
        f"Bundle layout may have changed; re-audit dockInfo.isVisible sites."
    )

def widen(m):
    return (
        # Widen the Windows guard to also include Linux → skips n+=i on Linux
        '(/*' + marker + '*/' + m.group('H8')
        + '||"linux"===process.platform)'
        + m.group('rest')
        # When i=0 (autohide dock / no bottom reservation in _NET_WORKAREA),
        # subtract dock clearance so the pill sits just above the dock.
        # 56 CSS px clears a typical GNOME dock (icon-size 34 at scale 5/3).
        # For fixed docks (i>0) !i is false, so no extra clearance is applied.
        + ',"linux"===process.platform&&!i&&(n-=56)'
    )

data, n = site.subn(widen, data)
if n != EXPECTED:
    sys.exit(f"ERROR: substitution applied {n} times (expected {EXPECTED}).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(
    f"Patched: widened {n} workArea bottom-inset guard(s) to skip n+=i on "
    f"Linux and added autohide-dock clearance (n-=56 when i=0)."
)
PY

if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi

echo "OK: status pill / context-menu position fixed on Linux in $BUNDLE"
echo
echo "Effect on Linux (fixed dock, GNOME panel 45 px at bottom):"
echo "  Before: pill y = workAreaSize.height + panelHeight - 320 (behind panel)"
echo "  After:  pill y = workAreaSize.height             - 320 (just above panel)"
echo
echo "Effect on Linux (autohide dock, i=0 so _NET_WORKAREA == screen):"
echo "  Before: pill bottom = screen bottom (overlaps dock)"
echo "  After:  pill bottom = screen bottom - 56 CSS px (~11 px above dock)"
