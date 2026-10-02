#!/usr/bin/env bash
#===============================================================================
# linux-status-window-visibility.sh -- keep the always-on "Flow Status
# Indicator" (Status window) glued to always-on-top on Linux, in the
# webpack-bundled Electron main process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS (refs #71)
# ------------------------------------
# The Status window is a transparent, frameless, always-on-top overlay. Its
# own 400 ms monitorMove interval (developer string "ignoring monitorMove
# interval") re-evaluates cursor/monitor state on every tick but never
# re-asserts `setAlwaysOnTop`. Intermittently -- most often at dictation
# start/stop, sleep/resume, and monitor/dock topology changes -- Electron
# drops `isAlwaysOnTop()` to `false` on Linux/XWayland. The app's own logs
# show the mechanism:
#
#   error "Status window not visible" { isAlwaysOnTop:false, isVisible:true }
#
# SCOPE (read this before filing against #71's click-through symptom)
# -----------------------------------------------------------------------
# This patch keeps the pill from silently falling BEHIND other windows once
# always-on-top drops. It does not and cannot make a captured (non
# click-through) window pass input through -- raising a window to the top
# makes it catch MORE pointer input over its rect, not less. The click/
# scroll dead-zone half of #71 (and #76) is a separate, still-open question
# about why the window's click-through state stops tracking reality; this
# patch only refs #71, it does not close it.
#
# The interval's own systemState early-out is intentionally NOT where the
# watchdog runs: upstream already re-asserts always-on-top at every
# dictation start (the function that logs "Status window not visible"), so
# the gap this patch closes is specifically the stretch BETWEEN dictations,
# including while idle -- which is exactly when `"active"!==systemState`
# makes the interval return early before doing anything else. The watchdog
# is therefore injected at the very head of the callback, before that
# early-out, so it keeps running on every tick regardless of dictation/idle
# state.
#
# THE PATCH (surgical, idempotent, .orig backup, verified against 1.6.957)
# --------------------------------------------------------------------------
#   ke=async()=>{if("active"!==u.RA.systemState)return;const e=performance.now();
#     becomes
#   ke=async()=>{{/*WISPR_LINUX_STATUS_VIS_WATCHDOG*/const w=u.RA.statusWindow;
#     w&&!w.isDestroyed()&&!w.isAlwaysOnTop()&&w.setAlwaysOnTop(!0,"screen-saver");}
#     if("active"!==u.RA.systemState)return;const e=performance.now();
#
# Nothing minified is hardcoded: the callback's own identifiers and the
# `<mod>.RA` state-object path are captured with `[\w$]+` and reused
# verbatim in the injected watchdog. The quote delimiter around `active` is
# matched as a class (backtick/double/single), not assumed to be `"`, per
# "Quote style" in docs/learnings/patching-minified-js.md. The injected
# watchdog is its own braced block (`{...}`), so on a second pass the
# anchor -- which requires the systemState check to sit immediately after
# the callback's opening `{` -- cannot match the code this patch itself
# produced; patch_begin's marker grep already short-circuits a re-run
# before that matters, but the shape stays fail-closed either way.
#
# WHY THIS CANNOT REGRESS NORMAL OPERATION
# -----------------------------------------
# - Healthy window: `isAlwaysOnTop()` is already `true` -> the watchdog's
#   `&&` chain short-circuits, no-op every tick, including during dictation
#   (upstream's own dictation-start re-assert already keeps it true then).
# - Broken state (compositor dropped always-on-top): re-asserting
#   `setAlwaysOnTop(!0,"screen-saver")` -- the exact level the bundle itself
#   already uses for this window elsewhere -- re-anchors the bar. Runs every
#   400 ms regardless of systemState, so it self-heals without waiting for
#   the next dictation to start.
# - Electron has no `ignoreMouseEvents()` getter (only the setter); this
#   patch does not probe it, and never touches click-through state.
#
# Usage: linux-status-window-visibility.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_STATUS_VIS_WATCHDOG" "${1:-}"

python3 - "$BUNDLE" "$MARKER" <<'PY'
import re, sys, io

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    src = f.read()

# Quote class: never assume `"` for a developer-string-adjacent literal
# (docs/learnings/patching-minified-js.md, "Quote style").
Q = r'[`"\']'

# Anchor: the monitorMove interval callback's opening -- its own identifier,
# the systemState early-out (quote-class matched), performance.now(), and
# the statusWindow-destroyed guard sharing the SAME state-object path
# (backreferenced, not re-captured) as the systemState check. Every
# identifier is [\w$]+; nothing minified is hardcoded.
anchor = re.compile(
    r'(?P<prelude>(?P<fn>[\w$]+)=async\(\)=>\{)'
    r'(?P<earlyout>if\(' + Q + r'active' + Q + r'!==(?P<wref>[\w$]+\.[\w$]+)\.systemState\)'
    r'return;const\s+[\w$]+=performance\.now\(\);)'
    r'(?P<guard>if\((?P=wref)\.statusWindow&&'
    r'!(?P=wref)\.statusWindow\.isDestroyed\(\)\)try\{)'
)

EXPECTED = 1
matches = [
    m for m in anchor.finditer(src)
    if 0 <= src.find("ignoring monitorMove interval", m.end()) - m.end() < 1500
]
if len(matches) != EXPECTED:
    sys.exit(
        f"ERROR: expected exactly {EXPECTED} monitorMove interval callback "
        f"site(s) near \"ignoring monitorMove interval\", found {len(matches)}. "
        f"Bundle layout may have changed -- refusing to guess."
    )

m = matches[0]
wref = m.group("wref")
inject = (
    "/*" + marker + "*/{const w=" + wref + ".statusWindow;"
    "w&&!w.isDestroyed()&&!w.isAlwaysOnTop()&&"
    'w.setAlwaysOnTop(!0,"screen-saver");}'
)
# Insert right after the callback's opening `{`, BEFORE the systemState
# early-out -- the watchdog must run even while systemState isn't "active".
patched = src[:m.end("prelude")] + inject + src[m.end("prelude"):]

if marker not in patched:
    sys.exit("ERROR: verification failed -- marker not present after replace. Aborting.")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(patched)
print(f"OK: status-window always-on-top watchdog inserted ahead of the "
      f"systemState early-out (marker: {marker}).")
PY

# --- Verify the result --------------------------------------------------------
patch_verify_marker

# Confirm the watchdog sits BEFORE the systemState early-out, not after: the
# marker must be immediately followed by the injected block, and that block
# must precede the "active" check textually.
patch_expect_shape -qP \
	'=async\(\)=>\{/\*'"$MARKER"'\*/\{const w=[\w$]+\.[\w$]+\.statusWindow;.*?\}if\([`"\x27]active[`"\x27]!==' \
	-- 'watchdog is not positioned ahead of the systemState early-out.'

patch_finish "Status window always-on-top watchdog installed ahead of the systemState early-out in $BUNDLE"
