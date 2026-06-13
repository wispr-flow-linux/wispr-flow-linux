#!/usr/bin/env bash
#===============================================================================
# linux-status-autohide.sh
#
# Makes the Wispr Flow status pill completely invisible when idle on Linux,
# showing it only during an active dictation cycle (hotkey-down → recording
# → processing → idle) in the webpack-bundled Electron main process
# (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# On macOS and Windows the status pill is always visible — it sits above the
# Dock / taskbar and shows the current dictation state at a glance. On Linux
# many users find a persistent overlay intrusive, especially when watching
# video or working fullscreen. This patch makes the pill appear on demand:
#
#   1. App starts:        pill window is created but stays hidden (no window,
#                         no border, nothing visible).
#   2. Hotkey pressed:    pill instantly appears via showInactive().
#   3. Recording / proc.: pill stays visible (user sees the state animation).
#   4. Idle / dismissed:  after a 2-second grace period the pill hides again,
#                         giving the user time to see the result flash.
#
# TWO PATCH SITES
# ---------------
# SITE 1 — x() / showStatusWindow (module 95070):
#   Called once on startup (Po.SB()) and again when the window is recreated
#   after destruction. It calls e.showInactive() then sets up monitor-move
#   and ignore-mouse-events intervals. On Linux we immediately re-hide the
#   window if _wfLinuxStatusVisible is falsy (undefined on first call →
#   hidden; set to true by the state hook when dictation starts).
#
#   Anchor: e.showInactive() immediately followed by o().info("Showing
#           status window") — 1 occurrence in the file.
#
# SITE 2 — updateDictationStatus / he() (StateManager module):
#   Called on every dictation state change with e = the new state string.
#   Injected after H.RA.extensionSystem?.broadcastDictationEnd() which is a
#   1-of-1 anchor in the comma-operator chain. The injection position is
#   unconditional — the comma operator evaluates all expressions even when
#   the broadcastDictationEnd() call short-circuits.
#
#   On "listening":             clear the hide timer, set visible flag, show.
#   On "idle"/"dismissed"/"error": clear visible flag, schedule hide in 2 s.
#
# Usage: linux-status-autohide.sh <path-to-.webpack/main/index.js>
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

LINUX_MARKER="WISPR_LINUX_STATUS_AUTOHIDE"
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

# ── Site 1: suppress initial show in x() ─────────────────────────────────
# After e.showInactive(), on Linux, immediately re-hide if the visible flag
# is falsy. On first call _wfLinuxStatusVisible is undefined → !undefined is
# true → window stays hidden. The state hook (site 2) sets it to true when
# dictation starts, so subsequent calls from the recreation path respect the
# current session visibility.
site1 = re.compile(
    r'(e\.showInactive\(\))'
    r'(,o\(\)\.info\("Showing status window"\))'
)
m1 = list(site1.finditer(data))
if len(m1) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 showInactive/Showing site, found {len(m1)}. "
        f"Bundle layout may have changed; re-audit module 95070 (showStatusWindow)."
    )

# ── Site 2: hook state transitions in updateDictationStatus ───────────────
# H.RA.extensionSystem?.broadcastDictationEnd() is a 1-of-1 anchor directly
# inside the updateDictationStatus comma-operator chain. The injected code is
# unconditional even though broadcastDictationEnd() is behind a guard — the
# comma operator preceding d.ZZ.matchedRouteName always evaluates.
#
# _wfLinuxStatusVisible — tracks whether the pill should be shown.
#   Stored on H.RA (the shared app store) as a dynamic property.
# _wfLinuxHT            — setTimeout handle for the deferred hide call.
site2 = re.compile(
    r'(H\.RA\.extensionSystem\?\.broadcastDictationEnd\(\))'
    r'(,)'
)
m2 = list(site2.finditer(data))
if len(m2) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 broadcastDictationEnd site, "
        f"found {len(m2)}. "
        f"Bundle layout may have changed; re-audit updateDictationStatus."
    )

# Validate ordering: x() is later in the file than the StateManager.
if m1[0].start() < m2[0].start():
    sys.exit(
        "ERROR: unexpected ordering — x() appears before StateManager patch. "
        "Check bundle structure."
    )

# Build injection strings.
linux_hide_check = (
    '"linux"===process.platform&&!O.RA._wfLinuxStatusVisible&&e.hide()'
)
linux_state_hook = (
    '"linux"===process.platform'
    '&&(/*' + marker + '*/'
    'e==="idle"||e==="dismissed"||e==="error"'
    '?(H.RA._wfLinuxStatusVisible=!1,'
      'clearTimeout(H.RA._wfLinuxHT),'
      'H.RA._wfLinuxHT=setTimeout(()=>{'
        'H.RA.statusWindow&&!H.RA.statusWindow.isDestroyed()'
        '&&H.RA.statusWindow.hide()'
      '},2e3))'
    ':e==="listening"'
      '&&H.RA.statusWindow'
      '&&!H.RA.statusWindow.isDestroyed()'
      '&&(clearTimeout(H.RA._wfLinuxHT),'
         'H.RA._wfLinuxStatusVisible=!0,'
         'H.RA.statusWindow.showInactive()))'
)

# Apply in reverse offset order so earlier offsets remain valid.
# Site 1 (x(), higher offset) first, then site 2 (StateManager, lower).
p1 = m1[0]
repl1 = p1.group(1) + ',' + linux_hide_check + p1.group(2)
data = data[:p1.start()] + repl1 + data[p1.end():]

p2 = m2[0]
repl2 = p2.group(1) + ',' + linux_state_hook + p2.group(2)
data = data[:p2.start()] + repl2 + data[p2.end():]

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(
    f"Patched: {marker} — status pill auto-hides on Linux when idle; "
    f"appears on hotkey press, disappears 2 s after dictation ends."
)
PY

if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       The bundle was NOT restored; re-run build-linux.sh from scratch." >&2
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

echo "OK: status pill autohide patched on Linux in $BUNDLE"
echo
echo "Effect on Linux:"
echo "  Idle:      pill window is completely hidden (no window, no border)"
echo "  Listening: pill appears instantly on hotkey press"
echo "  Processing: pill stays visible while transcribing"
echo "  Idle/done: pill disappears 2 s after dictation ends"
