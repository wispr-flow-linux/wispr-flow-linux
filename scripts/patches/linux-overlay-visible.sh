#!/usr/bin/env bash
#===============================================================================
# linux-overlay-visible.sh
#
# Calls setVisibleOnAllWorkspaces on Linux for the four overlay-type Wispr Flow
# windows (status indicator, overlay panel, context menu, calendar reminder) in
# the webpack-bundled Electron main process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# The four overlay BrowserWindows (status indicator, overlay panel, context
# menu, calendar reminder) each call:
#
#   <tD>&&<win>.setVisibleOnAllWorkspaces(!0,{visibleOnFullScreen:!0,
#                                             skipTransformProcessType:!0})
#
# where `<tD>` is the module-level `isMac` boolean. On Linux — and on Windows —
# this call is never made. On macOS it pins the window across all Mission
# Control spaces and prevents it from surfacing in Exposé. On Linux/GNOME the
# equivalent matters just as much:
#
#   * Without it, GNOME Wayland treats the status window as a
#     workspace-bound toplevel. When the user switches apps, the window can
#     appear in the Alt+Tab / Super+Tab switcher, interrupting dictation focus.
#   * setVisibleOnAllWorkspaces(true) on Linux sets _NET_WM_STATE_STICKY
#     (X11 / XWayland) and signals the Wayland compositor that the window
#     should persist across virtual desktops. GNOME then excludes it from
#     the application switcher and treats it as a persistent system overlay —
#     exactly the behaviour the Mac version already gets.
#
# WHY ONLY 4 OF 5 SITES
# ----------------------
# There are five <tD>&&<win>.setVisibleOnAllWorkspaces(...skipTransformProcessType...)
# calls in the bundle. The fifth is the meeting_recorder BrowserWindow — a real
# interactive window that should NOT be sticky across workspaces. That site is
# distinguished by the absence of a <win>.setFullScreenable(!1) call immediately
# after the setVisibleOnAllWorkspaces call; the four overlay sites all have it.
# The anchor below requires the trailing setFullScreenable, so the meeting
# recorder is skipped by construction.
#
# THE FIX
# -------
# At each of the four overlay sites, widen the isMac predicate to also be true
# on Linux:
#
#   <tD>&&<win>.setVisibleOnAllWorkspaces(...)
#     becomes
#   (<tD>||"linux"===process.platform)&&<win>.setVisibleOnAllWorkspaces(...)
#
# <tD> and <win> are minified symbols captured from the match — no minified
# token is hardcoded. The anchor is the preserved developer method names
# `setVisibleOnAllWorkspaces` + `skipTransformProcessType` (property names
# survive minification) plus the required trailing `setFullScreenable(!1)`.
#
# Usage: linux-overlay-visible.sh <path-to-.webpack/main/index.js>
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

LINUX_MARKER="WISPR_LINUX_OVERLAY_VISIBLE"
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

# Anchor: the four overlay-window sites have this exact shape:
#   <tD>&&<win>.setVisibleOnAllWorkspaces(!0,{visibleOnFullScreen:!0,skipTransformProcessType:!0}),<win>.setFullScreenable(!1)
#
# Captures:
#   tD  - the minified isMac flag (e.g. d.tD, ur.tD, s.tD, c.tD)
#   win - the minified BrowserWindow variable (e.g. n, s)
#
# The trailing ,<win>.setFullScreenable(!1) is what excludes the meeting
# recorder site (which has .webContents.on after setVisibleOnAllWorkspaces,
# not setFullScreenable).
site = re.compile(
    r'(?P<tD>[\w$]+\.tD)'
    r'(?P<vaw>&&(?P<win>[\w$]+)\.setVisibleOnAllWorkspaces\(!0,\{'
    r'visibleOnFullScreen:!0,skipTransformProcessType:!0\}\))'
    r'(?P<sfull>,(?P=win)\.setFullScreenable\(!1\))'
)

matches = list(site.finditer(data))

EXPECTED = 4
if len(matches) != EXPECTED:
    sys.exit(
        f"ERROR: expected exactly {EXPECTED} overlay setVisibleOnAllWorkspaces "
        f"site(s) with trailing setFullScreenable, found {len(matches)}. "
        f"Bundle layout may have changed; re-audit before patching."
    )

def widen(m):
    return (
        '(/*' + marker + '*/' + m.group('tD')
        + '||"linux"===process.platform)'
        + m.group('vaw')
        + m.group('sfull')
    )

data, n = site.subn(widen, data)
if n != EXPECTED:
    sys.exit(f"ERROR: substitution applied {n} times (expected {EXPECTED}).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: widened {n} overlay setVisibleOnAllWorkspaces sites to also "
      f"run on Linux (status, overlay panel, context menu, calendar reminder).")
PY

if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

if ! grep -qF '||"linux"===process.platform)&&' "$BUNDLE"; then
	echo "ERROR: widened predicate not in expected form. Restoring backup." >&2
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

echo "OK: overlay windows will call setVisibleOnAllWorkspaces on Linux in $BUNDLE"
echo
echo "Effect on Linux:"
echo "  Status indicator, overlay panel, context menu, calendar reminder windows"
echo "  now call setVisibleOnAllWorkspaces(true) on Linux — they will be"
echo "  treated as sticky system overlays by GNOME/KDE and excluded from"
echo "  the Alt+Tab switcher, matching macOS Mission Control behaviour."
