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
# new state to the renderer) opens with (1.6.897):
#
#   <fn>=<e>=>{let <t>,<n>;if(<log>().info(`[Drag Overlay]: Setting drag
#   overlay state to ${<e>}`),<U>=<e>,<e>?...
#
# Every identifier here (<fn>, <e>, <t>, <n>, <log>, <U>) is minified and
# churns between releases; the only stable anchor is the developer log string
# literal `[Drag Overlay]: Setting drag overlay state to `. We do NOT hardcode
# any of those tokens -- the regex captures them and the replacement reuses
# the captured parameter name, so it survives re-minification renaming them all
# to something else next release.
#
# The `let <t>,<n>;` between the function's `{` and its `if(` is the
# minifier's hoisted declaration, and it is not stable either: it is absent
# on 1.5.789 and could be split, reordered or dropped by the next
# re-minification. The anchor therefore spans it as a bounded prelude of up to
# 80 non-brace characters (`[^{}]{0,80}`) rather than as exact text, per
# docs/learnings/patching-minified-js.md ("adjacency"): the fence cannot
# cross a nested block, and the developer literal after it keeps the match
# unique. The prelude is captured and reproduced verbatim.
#
# We inject one braced statement after the prelude and before the `if(...)`,
# forcing the handler's own `<e>` parameter to `false` on Linux before
# anything downstream reads it:
#
#   if(/*WISPR_LINUX_DISABLE_PILL_DRAG*/"linux"===process.platform){<e>=!1}
#
# The braces are deliberate: they put the injected code outside what the
# `[^{}]` prelude can absorb, so a re-run that got past the marker guard
# would find no anchor and fail closed instead of patching twice.
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

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_DISABLE_PILL_DRAG" "${1:-}"

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, shutil, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()

# Anchor: the drag-overlay-state-change handler's opening, keyed on the
# preserved developer log string. Captures every minified identifier instead
# of hardcoding any of them (they churn every release), and spans whatever
# declaration prelude sits between the `{` and the `if(` as a bounded,
# brace-fenced run rather than as exact text (see
# docs/learnings/patching-minified-js.md).
anchor = re.compile(
	r'=(?P<fn>[\w$]+)=>\{(?P<prelude>[^{}]{0,80}?)'
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
		"=" + fn + "=>{" + m.group("prelude")
		+ "if(/*" + marker + '*/"linux"===process.platform){' + fn + "=!1}"
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
patch_verify_marker

patch_finish "pill drag-to-reposition disabled on Linux in $BUNDLE"
