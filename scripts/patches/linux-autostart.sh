#!/usr/bin/env bash
#===============================================================================
# linux-autostart.sh
#
# Makes "Start at Login" work on Linux in the webpack-bundled Electron main
# process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# Wispr Flow has two code paths that enable the login-item / autostart entry:
#
#  1. First-run init (Ho()): when no appLastClosedTime is recorded, the app
#     auto-enables itself at login for new users.
#  2. User-triggered IPC (SetOpenAtLogin): fires when the user toggles
#     "Start at Login" in Wispr Flow Settings.
#
# Both call Electron's app.setLoginItemSettings({openAtLogin: true|false}).
# On Linux this either silently does nothing, or writes a desktop file whose
# Exec line points to the raw Electron binary /usr/lib/wispr-flow/wispr-flow
# instead of the launcher wrapper /usr/bin/wispr-flow. Without the wrapper:
#   • --class=Wispr Flow is absent  → wrong WM_CLASS, icon ungrouped
#   • GPU/display-backend detection is skipped
#   • stale SingletonLock cleanup is skipped
#
# THE FIX
# -------
# For both call sites, add a Linux branch that directly writes (or removes)
# ~/.config/autostart/wispr-flow.desktop using Exec=/usr/bin/wispr-flow.
#
# SITE 1 — first-run init (Ho()):
#   Anchor: "Failed to set Windows open at login for new user"
#   Catch fn param: e   → closing sequence: String(e)}})}):
#   Else branch before patch: :y.app.setLoginItemSettings({openAtLogin:!0})
#
# SITE 2 — IPC handler (SetOpenAtLogin):
#   Anchor: "Failed to set Windows open at login" (no "for new user")
#   Catch fn param: t   → closing sequence: String(t)}})}):
#   Else branch before patch: :i.app.setLoginItemSettings({openAtLogin:e})
#
# The closing sequence }})}):
#   }}  closes the two brace levels of the error() argument object
#   )   closes .error()
#   }   closes the catch arrow-fn body (e=>{...} or t=>{...})
#   )   closes .catch(...)
#   :   ternary separator to the else branch
#
# Both sites get an inline Linux branch injected before the
# setLoginItemSettings fallback. The inline writer uses Node require()
# (available in the main process) and is safe on all platforms since it is
# gated on process.platform.
#
# Usage: linux-autostart.sh <path-to-.webpack/main/index.js>
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

LINUX_MARKER="WISPR_LINUX_AUTOSTART"
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

# Shared inline autostart writer factory.
# Returns the new ternary else-branch string for Linux:
#   ("linux"===process.platform ? <writer>(val) : <fallback>)
#
# The writer is a self-calling arrow that uses require() so imports are
# deferred to call time and don't affect the module on non-Linux platforms.
DESKTOP_CONTENT = (
    "[Desktop Entry]\\n"
    "Type=Application\\n"
    "Name=Wispr Flow\\n"
    "Exec=/usr/bin/wispr-flow\\n"
    "Hidden=false\\n"
    "NoDisplay=false\\n"
    "X-GNOME-Autostart-enabled=true\\n"
)

def make_replacement(pre, val, fallback):
    writer = (
        '("linux"===process.platform'
        '?(/*' + marker + '*/openAtLogin=>{'
        'const _d=require("path").join(require("os").homedir(),".config","autostart")'
        ',_f=_d+"/wispr-flow.desktop";'
        'try{openAtLogin?'
        '(require("fs").mkdirSync(_d,{recursive:!0}),'
        'require("fs").writeFileSync(_f,"' + DESKTOP_CONTENT + '")):require("fs").unlinkSync(_f)'
        '}catch(_e){}}'
        ')(' + val + '):' + fallback + ')'
    )
    return pre + ':' + writer

# ── Site 1: first-run init (Ho()) ─────────────────────────────────────────
# Catch fn uses `e` as its parameter name.
site1 = re.compile(
    r'("Failed to set Windows open at login for new user"'
    r'.{0,250}?'
    r'String\(e\)\}\}\)\}\)'
    r')'
    r':'
    r'([\w$]+\.app\.setLoginItemSettings\(\{openAtLogin:!0\}\))'
)

m1 = list(site1.finditer(data))
if len(m1) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 first-run setLoginItemSettings site, "
        f"found {len(m1)}. "
        f"Bundle layout may have changed; re-audit Ho() / appLastClosedTime."
    )

for m in reversed(m1):
    replacement = make_replacement(m.group(1), '!0', m.group(2))
    data = data[:m.start()] + replacement + data[m.end():]

# ── Site 2: IPC handler (SetOpenAtLogin) ──────────────────────────────────
# Catch fn uses `t` as its parameter name (distinct from site 1's `e`).
site2 = re.compile(
    r'("Failed to set Windows open at login"'
    r'.{0,250}?'
    r'String\(t\)\}\}\)\}\)'
    r')'
    r':'
    r'([\w$]+\.app\.setLoginItemSettings\(\{openAtLogin:e\}\))'
)

m2 = list(site2.finditer(data))
if len(m2) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 IPC setLoginItemSettings site, "
        f"found {len(m2)}. "
        f"Bundle layout may have changed; re-audit SetOpenAtLogin IPC handler."
    )

for m in reversed(m2):
    replacement = make_replacement(m.group(1), 'e', m.group(2))
    data = data[:m.start()] + replacement + data[m.end():]

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(
    f"Patched: added Linux XDG autostart writer to 2 setLoginItemSettings "
    f"sites (first-run Ho() + SetOpenAtLogin IPC handler)."
)
PY

if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found in $BUNDLE)." >&2
	echo "       The bundle was NOT restored; re-run build-linux.sh from scratch." >&2
	exit 1
fi

if ! grep -qF '/usr/bin/wispr-flow' "$BUNDLE"; then
	echo "ERROR: launcher path /usr/bin/wispr-flow not found in patched bundle." >&2
	echo "       The bundle was NOT restored; re-run build-linux.sh from scratch." >&2
	exit 1
fi

echo "OK: Linux autostart patched in $BUNDLE"
echo
echo "Effect on Linux:"
echo "  ~/.config/autostart/wispr-flow.desktop is written/removed when the"
echo "  user toggles 'Start at Login' in Settings, or on first run."
echo "  Exec=/usr/bin/wispr-flow ensures the launcher wrapper is used."
