#!/usr/bin/env bash
#===============================================================================
# patch-linux-window-frame.sh -- make Wispr Flow's chrome windows frameless on
# Linux too, matching the Windows (win32) treatment, in the webpack-bundled
# Electron main process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# Some BrowserWindow configs in the main bundle pick a title-bar / frame
# treatment with a THREE-WAY platform switch of the shape:
#
#   isMac ? Object.assign(t,{frame:!1,titleBarStyle:"hidden",
#                            trafficLightPosition:{x:1e4,y:10},...})
#         : "win32"===process.platform &&
#             Object.assign(t,{titleBarStyle:"hidden",autoHideMenuBar:!0});
#
# macOS gets a frameless window with a hidden title bar and the traffic lights
# parked offscreen; Windows gets a hidden title bar (custom in-window chrome)
# with the menu bar suppressed. Linux matches NEITHER predicate, so `t` is left
# untouched and Electron renders its platform DEFAULT: a full native title bar +
# a visible menu bar. That clashes with the renderer CSS patch that makes Linux
# adopt the `.win32` chrome (a custom title bar with in-window
# minimize/maximize/close controls): those controls only render correctly inside
# a frameless / hidden-title-bar window, exactly like Windows.
#
# As of Wispr Flow 1.5.695 this is the meeting_recorder window. The other chrome
# windows no longer have this gap: the Flow Hub and scratchpad windows now use a
# TWO-WAY `isMac ? {frame:!1,...} : {frame:!1,autoHideMenuBar:!0}` switch whose
# else branch already gives Linux a frameless window, and the overlay / status /
# contextMenu / calendar_reminder windows set `frame:!1` unconditionally. Earlier
# Wispr versions keyed the mac branch on `titleBarStyle:"hiddenInset"`; that
# disappeared in the 1.5.695 refactor (which is why the old anchor no-oped and
# verify-patches.sh failed on the absent WISPR_LINUX_FRAMELESS marker).
#
# THE PATCH (surgical, widen ONE predicate at the window-config site)
# -------------------------------------------------------------------
# At the affected window-config site we widen the win32 predicate so Linux takes
# the SAME branch as Windows:
#
#   : "win32"===process.platform&&Object.assign(t,{titleBarStyle:"hidden",...})
#       becomes
#   : ("win32"===process.platform||"linux"===process.platform)&&Object.assign(...)
#
# Linux now receives  {titleBarStyle:"hidden", autoHideMenuBar:!0}  — identical
# to Windows. `titleBarStyle:"hidden"` hides the native title bar so the custom
# `.win32` chrome can draw min/max/close; `autoHideMenuBar:!0` removes the menu
# bar. The win32 branch already supplies everything Linux needs, so NO separate
# `frame:false` is required here (this window uses the hidden-title-bar style,
# not a fully `frame:false` window).
#
# WHY THIS CANNOT REGRESS WINDOWS UPDATE / LOGIN BEHAVIOUR
# -------------------------------------------------------
# We do NOT touch the global `isWin32` flag (the derived `H8` symbol from
# webpack module 137803/137804). Widening that flag would corrupt the
# Squirrel/registry/autoUpdater code paths that legitimately gate on win32
# (e.g. the path-validation `checkPath` sites and the Squirrel
# "already running" autoUpdater handler). Instead we widen ONLY the inline
# `"win32"===process.platform` literal that lives AT the BrowserWindow-config
# `Object.assign(t,{titleBarStyle:"hidden",...})` site. The anchor below pins
# the match to that title-bar Object.assign and nothing else, so Windows
# update/login/registry behaviour is byte-for-byte unchanged.
#
# Anchor (unique in the bundle), keyed on stable developer string literals --
# NOT on minified symbols (the platform flags `tD`/`H8` and the config var churn
# every release):
#   "win32"===process.platform  +
#   &&Object.assign(<var>,{titleBarStyle:"hidden",autoHideMenuBar:!0})
# These two literals adjacent uniquely identify the meeting_recorder
# window-config ternary -- the only window config of this shape (the Hub and
# scratchpad windows moved to a two-way switch whose else branch already gives
# Linux frame:!1, and the overlay/status/contextMenu/calendar_reminder windows
# set frame:!1 unconditionally, so all of those are already frameless on Linux).
# We no longer anchor on the mac branch: it churns (it dropped "hiddenInset" in
# 1.5.695), and the win32-predicate + hidden-title-bar Object.assign pair is
# already unique on its own. The EXPECTED count assertion below fails loudly if
# upstream ever reintroduces that pair at a second site.
#
# Usage: patch-linux-window-frame.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	# default to the in-repo extracted bundle
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	BUNDLE="$(cd "$BUNDLE/.." && pwd)/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

# --- Idempotency guard --------------------------------------------------------
LINUX_MARKER="WISPR_LINUX_FRAMELESS"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (anchored on stable developer string literals) ---------------------
# Each window-config site of the gap shape gets its inline win32 predicate
# widened to also match linux. We assert the match count and set a per-site
# flag; a partial application (some sites widened, some missed because the
# bundle layout changed) emits a WARNING: line that CI greps for.
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Anchor: the inline win32 predicate -> the hidden-title-bar Object.assign.
# Every minified id (config var, platform flag symbol) churns; we anchor purely
# on the developer string literals and capture the one minified token we must
# preserve verbatim: the config var in the Object.assign that the win32 branch
# mutates.
#
# We widen ONLY the `"win32"===process.platform` that sits immediately before
# the hidden-title-bar Object.assign. The marker comment is injected inside the
# widened predicate so the idempotency grep and the per-site count both key on
# the same insertion.
site = re.compile(
    r'("win32"===process\.platform)'                      # g1: win32 predicate
    r'(&&Object\.assign\((?P<var>[\w$]+),'                # g2: &&assign( + var
    r'\{titleBarStyle:"hidden",autoHideMenuBar:!0\}\))'   # ...hidden cfg )
)
matches = list(site.finditer(data))

# How many window configs of this shape SHOULD exist. The 1.5.695 audit found
# exactly one (the meeting_recorder window). If the bundle ever sprouts another
# of this exact shape, EXPECTED must be bumped deliberately after re-auditing --
# we do not silently widen an unknown count.
EXPECTED = 1
if len(matches) != EXPECTED:
    sys.exit(
        f"ERROR: expected exactly {EXPECTED} frameless window-config site(s), "
        f"found {len(matches)}. Bundle layout may have changed; re-audit "
        f"titleBarStyle/hiddenInset/autoHideMenuBar sites before patching."
    )

# Widen the predicate. The marker comment lives inside the parenthesised
# predicate so a re-run's idempotency grep is satisfied and re-application is a
# no-op (the new predicate no longer matches the original `"win32"===...&&`
# adjacency, and the marker grep short-circuits before we get here anyway).
def widen(m):
    return (
        '(/*' + marker + '*/' + m.group(1)
        + '||"linux"===process.platform)'
        + m.group(2)
    )

site_done = bool(matches)
data = site.sub(widen, data, count=EXPECTED)

# Partial-application guard (multi-site pattern). With EXPECTED==1 this is a
# belt-and-braces check, but it keeps the WARNING: contract if EXPECTED grows.
if not site_done:
    print(
        "  WARNING: " + marker + " partial -- meetingRecorder=" + str(site_done)
        + "; Linux chrome windows will render with a native title bar + menu "
        + "bar (the .win32 chrome controls will be misplaced)."
    )

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: widened {EXPECTED} win32 window-config predicate(s) to also "
      f"match linux (config var(s): "
      f"{', '.join(sorted({m.group('var') for m in matches}))}).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# Confirm the widened predicate is well-formed: the marker must sit inside a
# parenthesised win32||linux predicate immediately before the hidden-title-bar
# Object.assign.
if ! grep -q \
	'/\*'"$LINUX_MARKER"'\*/"win32"===process.platform||"linux"===process.platform)&&Object.assign' \
	"$BUNDLE"; then
	echo "ERROR: widened predicate not in expected form. Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# Syntax-check the patched bundle.
if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi
echo "OK: Linux frameless window-config branch widened in $BUNDLE"
echo
echo "Patched window config now does (conceptually):"
echo "  isMac ? {frame:false,titleBarStyle:'hidden',...}"
echo "        : (isWin32 || isLinux) && {titleBarStyle:'hidden',autoHideMenuBar:true};"
echo
echo "Linux now gets the same hidden-title-bar chrome as Windows; the renderer"
echo "CSS patch's .win32 min/max/close controls render in a frameless window."
