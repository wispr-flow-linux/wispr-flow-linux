#!/usr/bin/env bash
#===============================================================================
# linux-status-picker-anchor.sh -- anchor the pickers the status pill opens at
# the pill's real screen position under native Wayland, in the Wispr Flow main
# bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ----------------------
# The status renderer anchors every popup it opens (auto-polish picker, fetch
# link picker, extension bubble menu, shortcut-join drawer) by sending main a
# screen point: window.screenX/Y plus the clicked button's client rect. Native
# Wayland never tells a client where its surface is, so window.screenX/Y are
# always 0 there and every popup opens at the screen's top-left corner. When
# the menu closes, main sends the cursor's screen point back and the renderer
# hit-tests it against the same window.screenX/Y + rect, so the "is the
# cursor still over the pill" check is also off by the window's position.
#
# Main already knows the missing offset: the status window's bounds are the
# bounds main itself asked for, computed from the display's real workArea, so
# statusWindow.getBounds() accounts for the dock and any layout without a
# constant. On native Wayland this patch adds bounds.x/y to the screen point
# each forwarding handler receives, and subtracts them from the cursor point
# main sends back, so both sides of the renderer's arithmetic agree again.
#
# THE RENDERER SITES AND WHERE EACH ONE LANDS (1.6.957)
# -----------------------------------------------------
# The status renderer reads window.screenX seven times, at six sites:
#   1. auto-polish button  -> ShowAutoPolishPicker     (patched, site A)
#   2. fetch-link button   -> ShowFetchLinkPicker      (patched, site B)
#   3. extension bubble,   -> ShowExtensionContextMenu (patched, site C)
#      RegisterExtensionStatusBubble "contextMenu" action
#   4. shortcut-join       -> ShowShortcutJoinDrawer   (patched, site D)
#      drawer (openDrawer)
#   5. onContextMenuDidHide hover check, two reads  <- DidHide (patched, site
#      E, both senders: the context-menu hide and the drawer's error path)
#   6. feature-tour anchor rects (ia) -> ReportAnchorRects. NOT patched: it is
#      shared by every renderer that hosts a tour anchor (hub, context menu,
#      scratchpad, ...), keyed by windowId rather than by the status window,
#      and it only places the product tour, not a picker.
#
# WHEN IT APPLIES
# ---------------
# Only native Wayland reports 0. Under X11, and under XWayland (the launcher's
# WISPR_USE_X11=1 passes --ozone-platform=x11), window.screenX/Y are real and
# adding the bounds would double them. The injected gate is therefore
#   "linux"===process.platform && WAYLAND_DISPLAY set &&
#   the ozone-platform switch is not "x11"
# which mirrors how the launcher picks the backend (scripts/launcher-common.sh).
# macOS and Windows never pass the gate, so the payload is forwarded as is.
#
# THE PATCH
# ---------
# Every site is anchored on its IPC property name (`.ShowAutoPolishPicker,!1,`
# and friends) plus, where the handler has one, its developer log string
# ("Showing auto polish picker", "Showing extension context menu", "Showing
# shortcut join drawer"). The forwarding call is matched as a shape, with
# the window registry (`A.RA` on 1.6.957), the callee and the payload name
# captured as [\w$]+, never spelled. Only the payload expression is rewritten:
#
#   (0,g.Bn)(A.RA.contextMenuWindow,d.qM.ShowAutoPolishPicker,e)
#   -> (0,g.Bn)(A.RA.contextMenuWindow,d.qM.ShowAutoPolishPicker,
#        /*WISPR_LINUX_PICKER_ANCHOR*/((p,b)=>b&&p?{...p,screenX:...+b.x,
#        screenY:...+b.y}:p)(e,<gate>&&A.RA.statusWindow?.getBounds()))
#
# and for DidHide the cursor point becomes {x:p.x-b.x,y:p.y-b.y}. Each site's
# count is asserted (A-D exactly one, E exactly two) before anything is
# written, so a moved or duplicated handler fails the build for a re-audit
# instead of shipping half-wired. One marker, six insertions.
#
# Usage: linux-status-picker-anchor.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_PICKER_ANCHOR" "${1:-}"

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()

Q = r'[`"\']'
ID = r'[\w$]+'
# The IPC send helper: `(0,g.Bn)(` today, a bare `Bn(` after a bundler swap.
CALLEE = (r'(?:\(0,' + ID + r'(?:\.' + ID + r')*\)|'
	+ ID + r'(?:\.' + ID + r')*)')
# `A.RA.contextMenuWindow,d.qM.<channel>,`: registry captured, enum spanned.
def fwd(window, channel):
	return (CALLEE + r'\((?P<reg>' + ID + r'(?:\.' + ID + r')*)\.' + window
		+ r',' + ID + r'\.' + ID + r'\.' + channel + r',')
NO_ARROW = r'(?:(?!=>)[^;])'

sites = [
	("A auto-polish picker", 1, "in", re.compile(
		r'\.ShowAutoPolishPicker,!1,(?P<p>' + ID + r')=>\{[^{}]{0,200}?'
		+ Q + r'Showing auto polish picker' + Q + r'[^{}]{0,200}?'
		+ fwd('contextMenuWindow', 'ShowAutoPolishPicker')
		+ r'(?P<arg>(?P=p))\)')),
	("B fetch-link picker", 1, "in", re.compile(
		r'\.ShowFetchLinkPicker,!1,(?P<p>' + ID + r')=>\{[^{}]{0,300}?'
		+ fwd('contextMenuWindow', 'ShowFetchLinkPicker')
		+ r'(?P<arg>(?P=p))\)')),
	("C extension bubble menu", 1, "in", re.compile(
		r'\.ShowExtensionContextMenu,!1,(?P<p>' + ID + r')=>\{'
		+ NO_ARROW + r'{0,300}?' + Q + r'Showing extension context menu' + Q
		+ NO_ARROW + r'{0,300}?'
		+ fwd('contextMenuWindow', 'ShowExtensionContextMenu')
		+ r'(?P<arg>(?P=p))\)')),
	("D shortcut-join drawer", 1, "in", re.compile(
		r'\.ShowShortcutJoinDrawer,!0,' + ID + r'=>[^;]{0,300}?'
		+ Q + r'Showing shortcut join drawer' + Q + r'[\s\S]{0,400}?'
		+ fwd('contextMenuWindow', 'ShowShortcutJoinDrawer')
		+ r'\{\.\.\.(?P<arg>' + ID + r'),')),
	("E DidHide cursor point", 2, "out", re.compile(
		fwd('statusWindow', 'DidHide') + r'\{cursorScreenPoint:'
		+ r'(?P<arg>' + ID + r'\.screen\.getCursorScreenPoint\(\))\}')),
]

found = []
for label, expected, _, rx in sites:
	ms = list(rx.finditer(src))
	if len(ms) != expected:
		sys.exit(
			f"ERROR: expected exactly {expected} '{label}' site(s), found "
			f"{len(ms)}. Bundle layout may have changed; re-audit the status "
			f"renderer's window.screenX sites and their main handlers "
			f"(see this script's header) before patching.")
	found.append(ms)

GATE = ('"linux"===process.platform&&!!process.env.WAYLAND_DISPLAY'
	'&&"x11"!==require("electron").app.commandLine'
	'.getSwitchValue("ozone-platform")')

def bounds(reg):
	return (GATE + '&&!' + reg + '.statusWindow?.isDestroyed?.()&&'
		+ reg + '.statusWindow?.getBounds()')

def wrap(direction, reg, arg):
	if direction == "in":
		fn = ('(p,b)=>b&&p?{...p,screenX:(p.screenX??0)+b.x,'
			'screenY:(p.screenY??0)+b.y}:p')
	else:
		fn = '(p,b)=>b&&p?{x:p.x-b.x,y:p.y-b.y}:p'
	return '/*' + marker + '*/((' + fn + ')(' + arg + ',' + bounds(reg) + '))'

# Splice right to left so earlier offsets stay valid.
edits = []
for (label, _, direction, _), ms in zip(sites, found):
	for m in ms:
		edits.append((m.start("arg"), m.end("arg"),
			wrap(direction, m.group("reg"), m.group("arg"))))
edits.sort(reverse=True)
for start, end, text in edits:
	src = src[:start] + text + src[end:]

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(src)
print(f"Patched: status-window offset applied at {len(edits)} site(s) "
      f"(4 picker forwards, 2 DidHide cursor points).")
PY

# --- Verify the result --------------------------------------------------------
patch_verify_marker
patch_expect_shape -qF "WISPR_LINUX_PICKER_ANCHOR*/((" -- \
	"picker-anchor wrapper not found after patching."

patch_finish "status pickers anchored at the pill on Wayland in $BUNDLE"
