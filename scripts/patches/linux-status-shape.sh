#!/usr/bin/env bash
#===============================================================================
# patch-linux-status-shape.sh -- have the status-pill renderer publish the
# pill's painted bounding box in document.title, on Linux
# (.webpack/renderer/status/index.js).
#
# The status window is bigger than the pill it draws (200x110 vs ~48x14 at
# rest). Wispr makes the empty part click-through by polling pixel alpha and
# toggling setIgnoreMouseEvents, which does nothing on native Wayland, and
# Electron's setShape is a no-op there as well (checked on Electron 42: the
# compositor's pick at an empty point still hits the window afterwards). So the
# transparent margin swallows hover and clicks meant for the window underneath,
# e.g. the bottom buttons of any app the pill floats over.
#
# Only the compositor can shape a Wayland surface's input, and it cannot see the
# DOM. The renderer appends the snippet in linux-status-shape.js, which sets
#   document.title = "Status|x,y,w,h"
# (CSS px, window-relative) whenever the painted box changes. The title is the
# one channel a Wayland client has to the compositor without a new protocol or
# a preload/IPC change. The GNOME Window Bridge extension (wispr-flow-linux/
# helper) reads it and clips the window to that box; nothing else reads the
# title, and an app without the extension just shows the title "Status|...".
#
# Usage: patch-linux-status-shape.sh <path-to-renderer/status/index.js>
#===============================================================================
set -uo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
	echo "usage: $0 <renderer/status/index.js>" >&2
	exit 2
fi

MARKER='WISPR_LINUX_STATUS_SHAPE'
SNIPPET="$(dirname "${BASH_SOURCE[0]}")/linux-status-shape.js"

if grep -qF "$MARKER" "$BUNDLE"; then
	echo "Already patched ($MARKER present) - nothing to do."
	exit 0
fi
if [[ ! -f "$SNIPPET" ]]; then
	echo "ERROR: snippet not found: $SNIPPET" >&2
	exit 1
fi

cp -p "$BUNDLE" "$BUNDLE.shape.orig" || exit 1

# A leading newline and semicolon keep the snippet a separate statement even if
# the bundle's last line is a //# sourceMappingURL comment or lacks a ';'.
{
	printf '\n;'
	cat "$SNIPPET"
} >>"$BUNDLE" || {
	echo "ERROR: could not append to $BUNDLE; restoring backup." >&2
	cp -p "$BUNDLE.shape.orig" "$BUNDLE"
	exit 1
}

if ! grep -qF "$MARKER" "$BUNDLE" || ! node --check "$BUNDLE"; then
	echo "ERROR: verification failed; restoring backup." >&2
	cp -p "$BUNDLE.shape.orig" "$BUNDLE"
	exit 1
fi
echo "OK: status pill shape publisher appended to $BUNDLE"
