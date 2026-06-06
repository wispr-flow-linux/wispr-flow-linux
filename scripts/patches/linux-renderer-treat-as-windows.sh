#!/usr/bin/env bash
#===============================================================================
# linux-renderer-treat-as-windows.sh
#
# Makes a Wispr Flow RENDERER bundle (.webpack/renderer/<window>/index.js) treat
# Linux like Windows for its platform-conditional UI, WITHOUT lying to the
# preload-exposed bridge. It widens the single place each renderer reads the
# bridged `isWindows` boolean into a module-local, so every downstream consumer
# of that local takes the Windows branch on Linux too.
#
# WHY THIS PATCH EXISTS  (and why it replaces linux-platform-bool.sh)
# ------------------------------------------------------------------
# The renderer reads platform once, near the top of its main module:
#     const <obj> = window.electron,
#           <mac> = <obj>?.platform?.isMacOS  ?? !1,   // isMacOS  local
#           <win> = <obj>?.platform?.isWindows ?? !1;  // isWindows local
# On Linux BOTH booleans are false, so every `<win> ? winThing : macThing`
# consumer lands on the macOS default -- wrong for Linux. The audited consumers
# (re-verified against the shipped renderer bundles) are ALL ones where Linux
# correctly wants the Windows branch, and NONE is a Windows-only API call, store
# link, registry/UAC path, or "Windows" product branding (the renderer is UI
# only; the OS-API danger class lives in the MAIN bundle and gates on
# `process.platform`/`H8`, which this patch never touches):
#
#   * fresh-install default keyboard / PTT shortcut maps  (Ctrl/Win/Alt set)
#   * keyboard key-glyph labels                           (Windows glyphs)
#   * onboarding "Permissions" step gating
#       `<mac> || (<win> && !e.windowsHasMicPermission)`  (show the step)
#   * the mic-permission help asset                       (windows_mic_permissions)
#   * a couple of minor UI timings/props (recording-start delay, voiceProfile)
#
# The OLD patch (linux-platform-bool.sh, marker WISPR_LINUX_AS_WINDOWS) achieved
# this by flipping the PRELOAD boolean so `window.electron.platform.isWindows`
# returned `true` on Linux. That works but LIES on the documented bridge API:
# `platform.isWindows` is meant to report the real OS, and any FUTURE renderer
# site that reads it (correct branding, a Store link, a "Windows key" label)
# would silently fire on Linux. This patch instead leaves the bridge HONEST
# (`isWindows` stays `false` on Linux) and widens only the renderer-internal
# "treat as windows" local.
#
# THE FIX (one robust anchor per renderer)
# ----------------------------------------
# Widen the `isWindows` bind to also be true when the OS is linux, deriving the
# linux check from the SAME bridge object the bind already reads:
#
#     <obj>?.platform?.isWindows??!1
#       becomes
#     ((<obj>?.platform?.isWindows??!1)||"linux"===<obj>?.platform?.os)
#
# The inner parens are REQUIRED: JS forbids mixing `??` with `||` without
# grouping (`a ?? b || c` is a SyntaxError). `<obj>` is the minified
# window.electron local, which we read back out of the match rather than
# hardcoding. `platform.os` is the real OS string the bridge already exposes
# (left untouched), so no new bridge surface is needed. isMacOS is NOT touched
# (keeps Linux on the Ctrl / Windows-VK keycode side).
#
# ANCHORING (survives re-minification)
# ------------------------------------
# The anchor is the PRESERVED developer property chain `?.platform?.isWindows`
# plus the `??!1` default -- property names are not mangled by the current
# bundler, so this survives re-minification (or fails closed). The only minified
# token we touch (`<obj>`) is captured from the match and re-emitted verbatim, so
# nothing minified is hardcoded. The bind occurs EXACTLY ONCE per renderer that
# reads platform; we assert that and bail otherwise.
#
# Usage: linux-renderer-treat-as-windows.sh <path-to-renderer/<window>/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	# default to the in-repo extracted hub renderer bundle
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	BUNDLE="${BUNDLE%/scripts}"
	BUNDLE="$BUNDLE/extract/app/.webpack/renderer/hub/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

# --- Idempotency guard --------------------------------------------------------
LINUX_MARKER="WISPR_LINUX_RENDERER_ISWIN"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (window.electron local DERIVED from the match, not hardcoded) -------
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Anchor: the isWindows bind read into a module local --
#     <obj>?.platform?.isWindows??!1
# `?.platform?.isWindows` is a preserved developer property chain (stable across
# re-minification); `<obj>` is the minified window.electron local, captured so we
# can reuse the SAME object for the linux-OS check. The leading [^\w$] keeps us
# off an identifier that merely ends in the captured name; we re-emit it.
anchor = re.compile(
    r'(?P<pre>[^\w$])'
    r'(?P<obj>[\w$]+)\?\.platform\?\.isWindows\?\?!1'
)
matches = list(anchor.finditer(data))
if len(matches) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 `<obj>?.platform?.isWindows??!1` bind, "
        f"found {len(matches)}. The bundle layout may have changed (or this "
        f"renderer does not read isWindows); inspect around "
        f"`?.platform?.isWindows`."
    )

obj = matches[0].group('obj')

# Widen the bind: true on the real isWindows OR when the OS is linux. The inner
# parens around the `??` expression are mandatory (mixing ?? with || is a
# SyntaxError otherwise). Build by concatenation so no `$N`/`$&` sequence can be
# eaten by a replacement DSL (a lambda is used anyway). isMacOS is untouched.
def widen(m):
    return (
        m.group('pre')
        + '((' + obj + '?.platform?.isWindows??!1)'
        + '||"linux"===' + obj + '?.platform?.os)'
        + '/*' + marker + '*/'
    )

data, n = anchor.subn(widen, data, count=1)
if n != 1:
    sys.exit(f"ERROR: substitution applied {n} times (expected 1).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: derived window.electron local={obj!r}; isWindows bind widened "
      f"to also be true on linux (1 site).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# The widened bind must carry the linux-OS clause immediately before the marker
# (proves we hit the bind, not some stray marker placement).
if ! grep -qF '?.platform?.os)/*'"$LINUX_MARKER"'*/' "$BUNDLE"; then
	echo "ERROR: widened bind not in expected form. Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# Syntax-check: catch a replacement that serializes but doesn't parse (the
# ?? / || grouping is exactly the kind of thing that can mis-serialize).
if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi
echo "OK: renderer isWindows local now also true on Linux in $BUNDLE"
echo
echo "Renderer effect (conceptually):"
echo "  window.electron.platform.isWindows === false  (bridge stays HONEST)"
echo "  the renderer-internal 'isWindows' local       === true on Linux"
echo "  -> fresh installs seed Windows-style shortcut/PTT defaults"
echo "  -> keyboard glyph labels use the Windows set"
echo "  -> onboarding 'Permissions' step is surfaced"
