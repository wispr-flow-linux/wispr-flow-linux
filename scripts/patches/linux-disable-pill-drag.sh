#!/usr/bin/env bash
#===============================================================================
# patch-linux-disable-pill-drag.sh -- make the status-pill drag-to-reposition
# gesture a no-op on Linux, in the Wispr Flow main bundle
# (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ----------------------
# Wispr Flow lets you drag the dictation status pill to reposition it. Dragging
# works by asking Electron to move the pill BrowserWindow to an absolute (x, y)
# on every pointer-move, and shows a full-work-area dimming "blackout" overlay
# window underneath while the drag is in progress (so you can see where you're
# dropping it).
#
# Absolute window positioning by the CLIENT has no equivalent in the base
# Wayland `xdg_toplevel` protocol -- only the compositor may place a top-level
# surface, unlike X11. So under native Wayland (the default backend on Linux;
# see docs/learnings/wayland-injection.md) every move request the drag issues
# is silently ignored. The user sees the dimming overlay appear and just sit
# there: the pill never visibly moves, and the drag can never complete on its
# own. Because the dimming window uses Wispr's alpha-based click-through hit
# test (opaque pixels capture pointer input, transparent ones pass it through),
# and the dimming layer is deliberately non-transparent, the stuck overlay also
# swallows pointer input -- including two-finger scroll -- over whatever screen
# real estate it now covers, until the user notices and presses Escape (which
# Wispr registers as a global shortcut specifically to cancel this state).
#
# There is no reachable Linux configuration where this feature can work as
# designed (X11 sessions could in principle support it, but Wispr Flow does not
# gate the feature to XWayland specifically, and forcing XWayland process-wide
# is its own can of worms -- see docs/decisions.md). Disabling drag entirely on
# Linux converts "grabs the pill, silently breaks, and can strand an
# input-blocking overlay over part of your screen" into a normal no-op click,
# which is the strictly-better failure mode. It has no fix on Linux other than
# not engaging the mechanism, and the pill still parks at its normal position
# via BrowserWindow's own docked default (see docs/decisions.md).
#
# THE PATCH (surgical, anchored on a stable developer log string)
# -----------------------------------------------------------------
# The renderer requests a drag-overlay state change over IPC; the main-process
# handler that actually enacts it (registers/unregisters the Escape shortcut,
# resizes the status window to the blackout-overlay bounds, and broadcasts the
# new state to the renderer) opens with:
#
#   <fn>=<e>=>{let <t>,<n>;if(<log>().info(`[Drag Overlay]: Setting drag
#   overlay state to ${<e>}`),<U>=<e>,<e>?...
#
# Every identifier here (<fn>, <e>, <t>, <n>, <log>, <U>) is minified and
# churns between releases; the only stable anchor is the developer log string
# literal `[Drag Overlay]: Setting drag overlay state to `. We do NOT hardcode
# any of those tokens -- the regex captures them and the replacement re-uses
# the captured parameter name, so it survives re-minification renaming them all
# to something else next release.
#
# We inject one statement immediately after `let <t>,<n>;` and before the
# `if(...)`, forcing the handler's own `<e>` parameter to `false` on Linux
# before anything downstream reads it:
#
#   <e>=(/*WISPR_LINUX_DISABLE_PILL_DRAG*/"linux"===process.platform)?!1:<e>;
#
# With <e> forced false on Linux: the Escape-shortcut branch always takes its
# harmless "unregister if registered" arm, the block that computes drag insets
# (guarded by `<e>?{...}`) never runs, and the final IPC broadcast to the
# status window always carries `isActive:false`. The blackout/resize path in
# the sibling `monitorMove` function is gated on that same state flag, so it
# never engages either. mac/win32 are untouched: the ternary evaluates to the
# original `<e>` there, so the function is byte-for-byte the original modulo
# the injected statement.
#
# Usage: patch-linux-disable-pill-drag.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
	echo "usage: $0 <.webpack/main/index.js>" >&2
	exit 2
fi

MARKER="WISPR_LINUX_DISABLE_PILL_DRAG"

if grep -qF "$MARKER" "$BUNDLE"; then
	echo "Already patched ($MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, shutil, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()

# Anchor: the drag-overlay-state-change handler's opening, keyed on the
# preserved developer log string. Captures every minified identifier instead
# of hardcoding any of them (they churn every release; see
# docs/learnings/patching-minified-js.md).
anchor = re.compile(
	r'=(?P<fn>[\w$]+)=>\{let (?P<t>[\w$]+),(?P<n>[\w$]+);'
	r'if\((?P<log>[\w$]+)\(\)\.info\('
	r'`\[Drag Overlay\]: Setting drag overlay state to \$\{(?P=fn)\}`\),'
)
matches = list(anchor.finditer(src))
EXPECTED = 1
if len(matches) != EXPECTED:
	sys.exit(
		f"ERROR: expected exactly {EXPECTED} drag-overlay handler anchor(s), "
		f"found {len(matches)}. Bundle layout may have changed; re-audit the "
		f"'[Drag Overlay]: Setting drag overlay state to' log site before "
		f"patching."
	)

shutil.copyfile(path, path + ".pilldrag.orig")
print("Backup written:", path + ".pilldrag.orig")

def widen(m):
	fn = m.group("fn")
	return (
		"=" + fn + "=>{let " + m.group("t") + "," + m.group("n") + ";"
		+ fn + "=(/*" + marker + '*/"linux"===process.platform)?!1:' + fn + ";"
		+ "if(" + m.group("log") + "().info("
		+ "`[Drag Overlay]: Setting drag overlay state to ${" + fn + "}`),"
	)

patched, n = anchor.subn(widen, src, count=EXPECTED)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(patched)
print(f"Patched: forced the drag-overlay activation flag to false on Linux "
      f"at {n} site(s).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -qF "$MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       Restoring backup." >&2
	cp -p "$BUNDLE.pilldrag.orig" "$BUNDLE"
	exit 1
fi

if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.pilldrag.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi
echo "OK: pill drag-to-reposition disabled on Linux in $BUNDLE"
