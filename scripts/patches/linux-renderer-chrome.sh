#!/usr/bin/env bash
#===============================================================================
# patch-linux-renderer-chrome.sh
#
# Remaps the Linux platform class to "win32" in the Wispr Flow renderer hub
# bundle (.webpack/renderer/hub/index.js) so Linux adopts the entire tested
# win32 (frameless) CSS stylesheet instead of inheriting the unprefixed,
# mac-shaped base geometry.
#
# WHY THIS PATCH EXISTS
# ---------------------
# At startup the renderer tags <html> with the OS class:
#   document.documentElement.classList.add(window.electron.platform.os)
# On Linux this adds the class `linux`. Every platform CSS rule in the shipped,
# compiled stylesheet is keyed on `.darwin ...` or `.win32 ...`; there are ZERO
# `.linux` rules. So on Linux the document falls through to the UNPREFIXED base
# geometry, which is mac-shaped: a 68px phantom window-control inset shoves the
# sidebar collapse toggle ~3-4 icon-widths to the right, and the window control
# buttons render with no artwork (the mac traffic-light slots, unstyled).
#
# Because the stylesheet ships as compiled rules with HASHED class names,
# injecting a bespoke `.linux { ... }` rule is fragile (the hashes churn every
# build and we'd be guessing the cascade). Instead we REMAP the class at its
# single source: on Linux, add "win32" rather than "linux". Linux then adopts
# the whole tested win32 stylesheet -- frameless chrome, window controls on the
# right, the collapsed sidebar inset -- which is the closest-fit, fully-styled
# target. The user explicitly chose the "match Windows (frameless)" target.
#
# EXACT CURRENT CODE (extract/app/.webpack/renderer/hub/index.js; TWO sites):
#   document.documentElement.classList.add(window.electron.platform.os)
# `window.electron.platform.os` is a chain of PRESERVED developer property
# names (not minified), so it is a stable anchor across re-minification.
#
# THE PATCH (surgical, per-site, idempotent)
# ------------------------------------------
# We replace the ARGUMENT of each `classList.add(window.electron.platform.os)`
# call with a conditional that maps linux -> win32 and leaves every other OS
# untouched, tagged with an inline comment marker for idempotency:
#   classList.add(/*WISPR_LINUX_WIN32_CHROME*/"linux"===window.electron.platform.os?"win32":window.electron.platform.os)
# On mac/win the conditional yields the original value, so the patch cannot
# regress those platforms. There is an UNRELATED `classList.add(Yw.animated)`
# site in the same bundle; the anchor is tight enough (it requires the literal
# `window.electron.platform.os` argument) that it is never touched.
#
# The script is generic: it operates on whatever bundle path is passed, rewrites
# ALL matching sites, and asserts at least one site was rewritten (bailing with
# a clear error -- never a silent no-op -- if zero are found).
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	# default to the in-repo extracted renderer hub bundle
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	BUNDLE="$BUNDLE/extract/app/.webpack/renderer/hub/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

# --- Idempotency guard --------------------------------------------------------
LINUX_MARKER="WISPR_LINUX_WIN32_CHROME"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (anchored on the preserved developer property chain) ---------------
# The anchor is the literal `classList.add(window.electron.platform.os)`. The
# `window.electron.platform.os` chain is a sequence of developer property names
# that survive minification, so the patch survives re-minification (or fails
# loudly with a clear "found 0 sites" error -- never a silent no-op). The
# `classList.add(Yw.animated)` site has a minified argument, not this literal,
# so it is excluded by construction.
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Anchor: classList.add(window.electron.platform.os). The `os` chain is a
# preserved developer property name, so no minified identifier is hardcoded.
anchor = re.compile(
    r'classList\.add\((window\.electron\.platform\.os)\)'
)
sites = list(anchor.finditer(data))
if len(sites) < 1:
    sys.exit(
        "ERROR: found 0 `classList.add(window.electron.platform.os)` sites; "
        "the anchor is gone (re-minified or property renamed). Bailing rather "
        "than shipping an unpatched bundle."
    )

# Build the linux->win32 remap. Use a lambda replacement (concatenation) so no
# `$1`/`$&` interpolation can corrupt the injected snippet; m.group(1) is the
# preserved `window.electron.platform.os` chain captured from the match.
def remap(m):
    chain = m.group(1)
    return (
        'classList.add(/*' + marker + '*/"linux"==='
        + chain + '?"win32":' + chain + ')'
    )

data, n = anchor.subn(remap, data)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: rewrote {n} `classList.add(window.electron.platform.os)` "
      f"site(s) to map linux->win32.")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# Syntax-check: the conditional is a real JS expression; catch a replacement
# that serializes but doesn't parse before it ever reaches asar.
if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi
echo "OK: Linux->win32 platform-class remap applied to $BUNDLE"
echo
echo "Patched renderer now does (conceptually):"
echo '  document.documentElement.classList.add('
echo '    "linux" === window.electron.platform.os'
echo '      ? "win32"                      // Linux adopts the win32 stylesheet'
echo '      : window.electron.platform.os) // mac/win unchanged'
