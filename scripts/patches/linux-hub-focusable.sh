#!/usr/bin/env bash
#===============================================================================
# linux-hub-focusable.sh -- make the Flow Hub window focusable (and therefore
# WM-managed) on Linux, in the webpack-bundled Electron main process
# (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS (issue #36)
# ---------------------------------
# The Hub BrowserWindow config is created with `focusable:!1` on EVERY
# platform:
#
#   const t={title:"Flow Hub",...,show:!1,...,webPreferences:{...,
#     preload:require("path").resolve(__dirname,"../renderer","hub",
#     "preload.js"),devTools:...},focusable:!1};
#
# macOS recovers: the focus-suppression helpers (`withHubFocusSuppressed` and
# friends) toggle `setFocusable(!0)` back on behind an isMac gate. Windows
# tolerates it (focusable:false only implies skipTaskbar there). Linux gets
# NEITHER: per the Electron docs, `focusable:false` on Linux "makes the window
# stop interacting with wm" -- the window is created as an X11
# override-redirect (unmanaged) window. The result is exactly issue #36: the
# Hub floats above every other window, has no Alt+Tab entry, and cannot be
# moved, minimized, maximized, or switched away from on X11.
#
# THE PATCH (surgical, ONE property at the Hub window-config site)
# ----------------------------------------------------------------
# Rewrite the Hub config's `focusable:!1` to a platform expression:
#
#   focusable:!1
#     becomes
#   focusable:/*WISPR_LINUX_HUB_FOCUSABLE*/"linux"===process.platform
#
# Linux evaluates to `true` (normal, WM-managed, focusable window); darwin and
# win32 evaluate to `false` -- behaviorally identical to the shipped `!1`, so
# the macOS focus-suppression dance and the Windows treatment are unchanged.
#
# WHY ONLY THE HUB SITE
# ---------------------
# The 1.6.7 bundle has exactly THREE `focusable:!1` window configs:
#   1. the floating overlay (status pill) -- intentionally non-focusable HUD
#   2. the "Flow Context Menu" overlay    -- intentionally non-focusable;
#      toggles setFocusable at runtime when opened
#   3. the Hub                            -- the bug
# The scratchpad window sets no `focusable` key (defaults true). We therefore
# anchor on the Hub's OWN developer literals -- the `"hub","preload.js"`
# preload path inside its webPreferences -- and touch nothing else.
#
# Anchor (unique in the bundle), keyed on stable developer string literals --
# NOT on minified symbols (the config var and platform-flag symbols churn
# every release):
#   "hub","preload.js"),devTools:<no-braces>},focusable:!1}
# The devTools value is captured as `[^{}]*` so the match cannot escape the
# webPreferences object; if upstream ever puts braces in that expression or
# moves `focusable` off the tail of the config, the EXPECTED count assertion
# below fails loudly instead of patching the wrong site.
#
# Usage: linux-hub-focusable.sh <path-to-.webpack/main/index.js>
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
LINUX_MARKER="WISPR_LINUX_HUB_FOCUSABLE"
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
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Anchor: the Hub renderer preload path (developer strings, minifier-stable)
# through the end of webPreferences, then the `focusable:!1` that closes the
# Hub config object. `[^{}]*` keeps the devTools expression from spanning into
# another object; every minified identifier inside it is left uncaptured.
site = re.compile(
    r'("hub","preload\.js"\),devTools:[^{}]*\},)'  # g1: preload anchor ->
    r'focusable:!1\}'                              #     webPreferences close
)
matches = list(site.finditer(data))

# How many Hub window configs of this shape SHOULD exist. The 1.6.7 audit
# found exactly one. If the bundle ever sprouts another (or the config shape
# moves), EXPECTED must be bumped deliberately after re-auditing -- we do not
# silently patch an unknown count.
EXPECTED = 1
if len(matches) != EXPECTED:
    sys.exit(
        f"ERROR: expected exactly {EXPECTED} Hub focusable window-config "
        f"site(s), found {len(matches)}. Bundle layout may have changed; "
        f"re-audit the \"hub\",\"preload.js\" / focusable:!1 sites before "
        f"patching."
    )

# The marker comment lives inside the rewritten property value so the
# idempotency grep and this site both key on the same insertion (a re-run
# short-circuits on the marker grep; the original `focusable:!1` adjacency is
# gone anyway).
def fix(m):
    return (
        m.group(1)
        + 'focusable:/*' + marker + '*/"linux"===process.platform}'
    )

data = site.sub(fix, data, count=EXPECTED)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: rewrote the Hub config's focusable:!1 to a linux-gated "
      f"platform expression ({EXPECTED} site).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# Confirm the rewritten property is well-formed: the marker must sit inside
# the focusable value, followed by the linux platform test that closes the
# Hub config object.
if ! grep -qF \
	'focusable:/*'"$LINUX_MARKER"'*/"linux"===process.platform}' \
	"$BUNDLE"; then
	echo "ERROR: rewritten property not in expected form. Restoring backup." >&2
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
echo "OK: Hub window focusable-on-Linux rewrite applied in $BUNDLE"
echo
echo "Patched Hub window config now does (conceptually):"
echo "  {title:'Flow Hub', ..., focusable: isLinux}   // was: focusable: false"
echo
echo "Linux gets a normal WM-managed, focusable, Alt+Tab-able Hub window;"
echo "darwin/win32 still evaluate focusable:false exactly as shipped."
