#!/usr/bin/env bash
#===============================================================================
# patch-linux-status-screenpos.sh -- give the status-pill renderer its real
# on-screen position on Linux (.webpack/renderer/status/index.js).
#
# The pill anchors the language / auto-polish / fetch pickers it opens by
# sending window.screenX + <button rect> to the context-menu window. Native
# Wayland never tells a client where its window is, so window.screenX/screenY
# are always 0 and every picker opens at the left edge of the screen.
#
# On Linux the pill is always bottom-centred just above the dock (the GNOME
# Window Bridge extension places it there), so compute that position instead:
#   x = screen.availLeft + (screen.availWidth - innerWidth) / 2
#   y = screen.height - innerHeight - 37
# (37 = ~49px dock + 2px gap - 14px pill bottom inset; only the vertical anchor
# of an upward-opening menu depends on it.)
#
# Usage: patch-linux-status-screenpos.sh <path-to-renderer/status/index.js>
#===============================================================================
set -uo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
	echo "usage: $0 <renderer/status/index.js>" >&2
	exit 2
fi

MARKER='WISPR_LINUX_SCREENPOS'
if grep -qF "$MARKER" "$BUNDLE"; then
	echo "Already patched ($MARKER present) - nothing to do."
	exit 0
fi

cp -p "$BUNDLE" "$BUNDLE.screenpos.orig" || exit 1

python3 - "$BUNDLE" "$MARKER" <<'PY' || exit 1
import io, sys
path, marker = sys.argv[1], sys.argv[2]
src = io.open(path, encoding="utf-8", errors="surrogateescape").read()
lin = '"linux"===window.electron?.platform?.os'
x = ('(/*' + marker + '*/' + lin +
     '?((screen.availLeft||0)+(screen.availWidth-innerWidth)/2)'
     ':window.screenX)')
y = '(' + lin + '?(screen.height-innerHeight-37):window.screenY)'
nx, ny = src.count('window.screenX'), src.count('window.screenY')
if nx < 1 or ny < 1:
	sys.exit(f"ERROR: expected window.screenX/Y uses, found {nx}/{ny}")
src = src.replace('window.screenX', '\0X').replace('window.screenY', '\0Y')
src = src.replace('\0X', x).replace('\0Y', y)
io.open(path, 'w', encoding="utf-8", errors="surrogateescape").write(src)
print(f"Patched {nx} screenX / {ny} screenY uses.")
PY

if ! grep -qF "$MARKER" "$BUNDLE" || ! node --check "$BUNDLE"; then
	echo "ERROR: verification failed; restoring backup." >&2
	cp -p "$BUNDLE.screenpos.orig" "$BUNDLE"
	exit 1
fi
echo "OK: status renderer screen position patched in $BUNDLE"
