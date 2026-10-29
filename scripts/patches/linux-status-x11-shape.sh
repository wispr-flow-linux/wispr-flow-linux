#!/usr/bin/env bash
#===============================================================================
# linux-status-x11-shape.sh -- make the Flow Bar clickable on X11 and XWayland
# by clipping the status window to the pill's own rectangles, in the Wispr Flow
# main bundle (.webpack/main/index.js). Issue #41.
#
# WHY THIS PATCH EXISTS
# ---------------------
# The status window is transparent and larger than the pill. Off Windows, Wispr
# decides which part takes the mouse with an alpha hit-test poll (module 16815,
# exported as `Bi`): every 400ms it reads screen.getCursorScreenPoint(), samples
# the pixel under it with webContents.capturePage(), and calls
# setIgnoreMouseEvents(true|false) on the whole window. On X11, Electron 42
# implements `ignore` as a 1x1 ShapeInput region and `unignore` as a reset of
# ShapeInput (shell/browser/native_window_views.cc). When the poll decides
# wrong the pill stays click-through for good: capturePage throws
# UnknownVizError with the GPU off, and under XWayland the cursor point goes
# stale while the pointer is over native Wayland windows (issue #41 comments).
# The bar renders, but hover, right-click and the cancel/finish buttons are
# dead.
#
# Windows does not depend on that poll alone. Wispr ships a StatusInputShape
# manager (`class m{window=null;enabled=!1;everEnabled=!1;...}`) that takes the
# renderer's validated ReportAlphaCatchRects message (interactive rects plus
# painted shapeRects, sender- and viewport-checked, capped at 128) and applies
# it with BrowserWindow.setShape(). It is gated on the main-process isWindows
# flag. On X11, setShape() sets the ShapeBounding region (Chromium
# X11Window::UpdateWindowRegion), and the X SHAPE extension intersects input
# with the bounding region. So once the window is clipped to the pill, input
# can stay unignored: the pill takes the mouse, everything else falls through,
# and no cursor polling or pixel capture is involved.
#
# THE PATCH
# ---------
# 1. A gate, evaluated once and stored on globalThis right after the license
#    banner: Linux, and the Ozone X11 backend -- `--ozone-platform=x11` (the
#    launcher's WISPR_USE_X11=1 XWayland mode), or no explicit platform with
#    DISPLAY set and WAYLAND_DISPLAY unset (a plain X11 session). An explicit
#    `--ozone-platform=wayland` always loses. Native Wayland keeps the shipped
#    behaviour; Electron 42 cannot set input regions there (#44).
# 2. Under the gate, the StatusInputShape manager runs at the status window's
#    lifecycle sites the Windows flag guards: creation (replaceWindow), the
#    rect report, BarVisible, show, reload (did-start-loading invalidate,
#    did-finish-load re-enable), render-process-gone, destroy and the
#    monitor-size invalidation. Windows-only surface recovery (the 1px bounds
#    pulse, the post-wake timers, always-on-top re-assertion) is not widened.
# 3. Under the gate, the status module's poll starter
#    (`ne=e=>{...&&(V=(0,g.Bi)(e))}`) unignores the window instead
#    of starting the poll. Every paired path that sets ignore=true
#    (creation, BarHidden, feature-tour suspend, render-process-gone) is
#    undone by that starter on its way back (show/BarVisible, tour resume,
#    did-finish-load). The one unpaired path is a notification's
#    EnableMouseEvents(false) when a toast clears: it leaves the poll running,
#    so upstream recovers on the next tick. With no poll the window would stay
#    dead, so under the gate that message unignores too; the renderer's next
#    rect report reshapes the window around the pill again.
# 4. Under the gate, an empty rect list becomes the manager's own off-surface
#    sentinel ({x:-2,y:-2,width:1,height:1}). Electron documents setShape([])
#    as "back to rectangular" (true on Windows); on X11 it yields an empty
#    region today. The sentinel pins the safe meaning -- nothing drawn, nothing
#    hit -- before the first report, so the window can never become a full
#    rectangle that blocks the apps beneath it.
# 5. Under the gate, linux-status-compact.sh's 200x110 box is skipped, when
#    that patch ran first (build-linux.sh order): the shape already passes
#    the transparent canvas through on X11, and the compact box clips the
#    toasts drawn above the pill (the "Undo" toast after a cancel). Native
#    Wayland keeps the compact box.
#
# THE ANCHORS
# -----------
# Every minified name is captured, not spelled: the creation site
#   <F>?<J>.replaceWindow(<w>):<w>.setIgnoreMouseEvents(!0,{forward:!0})
# yields the isWindows flag <F> and the manager <J>; the BarVisible site
#   <F>&&<J>.setEnabled(!0),<ne>(
# yields the poll starter <ne>. All other anchors are built from those names
# and each must match exactly once (checked on the shipped 1.6.1209 bytes)
# before anything is written.
#
# Usage: linux-status-x11-shape.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_X11_STATUS_SHAPE" "${1:-}"

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()

ID = r'[\w$]+'
GATE = 'globalThis.__wisprLinuxX11StatusShape'
DEFINE = (
	'/*' + marker + '*/' + GATE + '=(()=>{try{'
	'if("linux"!==process.platform)return!1;'
	'const e=require("electron").app.commandLine.getSwitchValue("ozone-platform");'
	'return e?"x11"===e:!!process.env.DISPLAY&&!process.env.WAYLAND_DISPLAY'
	'}catch(e){return!1}})();'
)


def one(pattern, label):
	ms = list(re.finditer(pattern, src))
	if len(ms) != 1:
		sys.exit(
			f"ERROR: expected 1 {label} anchor, found {len(ms)}. Bundle layout "
			f"may have changed; re-audit the status window's StatusInputShape "
			f"wiring (see this script's header) before patching.")
	return ms[0]


create = one(
	r'(?P<F>' + ID + r'\.' + ID + r')\?(?P<J>' + ID + r')\.replaceWindow\('
	r'(?P<w>' + ID + r')\):(?P=w)\.setIgnoreMouseEvents\(!0,\{forward:!0\}\)',
	'status-creation')
F, J = re.escape(create['F']), re.escape(create['J'])
visible = one(F + r'&&' + J + r'\.setEnabled\(!0\),(?P<ne>' + ID + r')\(',
	'BarVisible')
NE = re.escape(visible['ne'])

edits = []  # (match, replacement)
edits.append((create, f'({create["F"]}||{GATE})?' + create.group(0).split('?', 1)[1]))
edits.append((visible, f'({create["F"]}||{GATE})' + visible.group(0)[len(create['F']):]))

m = one(r'if\(' + F + r'\)\{if\(!' + J + r'\.applyReport\(', 'rect-report')
edits.append((m, f'if({create["F"]}||{GATE}){{' + m.group(0)[len(f'if({create["F"]}){{'):]))

m = one(F + r'\|\|' + NE + r'\(' + ID + r'\),(?P<f>' + F + r')&&!' + ID + r'&&'
	+ J + r'\.setEnabled\(!0\)', 'show')
s = m.group(0)
i = m.start('f') - m.start()
edits.append((m, s[:i] + f'({create["F"]}||{GATE})' + s[i + len(create['F']):]))

for pattern, label in (
	(F + r'&&' + ID + r'&&\(' + J + r'\.setEnabled\(!1\),' + J
		+ r'\.invalidateBounds\(\)\)', 'render-process-gone'),
	(F + r'&&' + J + r'\.invalidateBounds\(\),', 'did-start-loading'),
	(F + r'&&' + J + r'\.destroy\(', 'destroy'),
	(F + r'&&' + ID + r'&&\(' + J + r'\.invalidateBounds\(\),', 'bounds-change'),
):
	m = one(pattern, label)
	edits.append((m, f'({create["F"]}||{GATE})' + m.group(0)[len(create['F']):]))

# did-finish-load: re-enable the manager and the input on X11, without the
# Windows-only 1px bounds pulse (<de>) that follows it.
m = one(F + r'&&!(?P<r>' + ID + r')\.isDestroyed\(\)&&(?P=r)\.isVisible\(\)&&!'
	r'(?P<tour>' + ID + r')&&\(' + J + r'\.setEnabled\(!0\),' + NE
	+ r'\((?P=r)\),' + ID + r'\((?P=r)\)\)', 'did-finish-load')
r, tour = m['r'], m['tour']
edits.append((m, m.group(0) + f',{GATE}&&!{r}.isDestroyed()&&{r}.isVisible()&&!{tour}'
	f'&&({create["J"]}.setEnabled(!0),{visible["ne"]}({r}))'))

# The poll starter: unignore instead of polling on X11.
m = one(NE + r'=(?P<e>' + ID + r')=>\{' + ID + r'\|\|\(' + ID + r'\(\),(?P=e)&&!'
	r'(?P=e)\.isDestroyed\(\)&&\((?P<poll>' + ID + r'=\(0,' + ID + r'\.' + ID
	+ r'\)\((?P=e)\))\)\)\}', 'poll-starter')
s = m.group(0)
a, b = m.start('poll') - m.start(), m.end('poll') - m.start()
edits.append((m, s[:a] + f'{GATE}?{m["e"]}.setIgnoreMouseEvents(!1):' + s[a:b] + s[b:]))

# The manager: an empty shape is the off-surface sentinel on X11.
m = one(r'applyCurrentShape\(\)\{this\.enabled\?this\.applyShape\(this\.latestRects\)'
	r':this\.applyShape\(this\.everEnabled\?(?P<s>' + ID + r'):\[\]\)\}'
	r'applyShape\((?P<a>' + ID + r')\)\{', 'empty-shape')
edits.append((m, m.group(0) + f'{GATE}&&!{m["a"]}.length&&({m["a"]}={m["s"]});'))

# A toast's EnableMouseEvents(false): stay unignored on X11.
m = one(ID + r'\|\|\((?P<on>' + ID + r')\?' + NE + r'\([\w$.]+\):' + ID
	+ r'\(\)\?\.setIgnoreMouseEvents\(!0,\{forward:!0\}\)', 'EnableMouseEvents')
s = m.group(0)
i = m.start('on') - m.start()
edits.append((m, s[:i] + f'{m["on"]}||{GATE}' + s[i + len(m['on']):]))

# linux-status-compact.sh's Linux box, when present: not on X11.
COMPACT = '/*WISPR_LINUX_STATUS_COMPACT*/"linux"===process.platform)'
if 'WISPR_LINUX_STATUS_COMPACT' in src:
	m = one(re.escape(COMPACT), 'status-compact')
	edits.append((m, COMPACT[:-1] + f'&&!{GATE})'))

spans = sorted((e[0].start(), e[0].end()) for e in edits)
for (_, end), (start, _) in zip(spans, spans[1:]):
	if start < end:
		sys.exit("ERROR: X11 status-shape anchors overlap; re-audit the bundle.")

for m, text in sorted(edits, key=lambda e: e[0].start(), reverse=True):
	src = src[:m.start()] + text + src[m.end():]

# The gate goes right after the license banner (or at byte 0), the same
# place linux-early-singleton.sh uses; it is side-effect free.
first, nl, rest = src.partition('\n')
if nl and first.startswith('/*!') and first.rstrip().endswith('*/'):
	src = first + '\n' + DEFINE + '\n' + rest
else:
	src = DEFINE + '\n' + src

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(src)
print(f"Patched: status window shaped on Linux X11 ({len(edits)} sites).")
PY

# --- Verify the result --------------------------------------------------------
patch_verify_marker
patch_expect_shape -qF \
	'||globalThis.__wisprLinuxX11StatusShape)?' \
	-- 'X11 status creation site not in expected form.'
patch_expect_shape -qF \
	'globalThis.__wisprLinuxX11StatusShape?' \
	-- 'X11 poll-starter branch not in expected form.'
want=13
grep -qF 'WISPR_LINUX_STATUS_COMPACT' "$BUNDLE" && want=14
sites=$(grep -oF 'globalThis.__wisprLinuxX11StatusShape' "$BUNDLE" | wc -l)
if [[ $sites -ne $want ]]; then
	echo "ERROR: expected $want X11 status-shape gate reads, found $sites. Restoring backup." >&2
	patch_restore
	exit 1
fi

patch_finish "status window shaped on Linux X11 in $BUNDLE"
