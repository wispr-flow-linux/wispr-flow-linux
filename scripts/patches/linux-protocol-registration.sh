#!/usr/bin/env bash
#===============================================================================
# linux-protocol-registration.sh -- stop the app from re-registering the
# `wispr-flow:` protocol handler through xdg-settings on every Linux start,
# in the Wispr Flow main bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS (issue #75)
# ---------------------------------
# The bundle registers its deep-link scheme at every start, on every platform:
#
#   t=e.app.setAsDefaultProtocolClient("wispr-flow"),
#   n().info("Protocol registration success:",t)
#
# On Linux, Electron implements that call by running
#
#   xdg-settings set default-url-scheme-handler wispr-flow wispr-flow.desktop
#
# and xdg-utils 1.1.3 (the version Ubuntu 22.04 ships) has a bug in the GNOME
# backend of exactly that command:
#
#   set_url_scheme_handler_gnome3()
#   {
#       binary="`desktop_file_to_binary "$2"`"
#       [ "$binary" ] || exit_failure_file_missing
#       set_browser_mime "$2" || return               # <- no MIME argument
#       set_browser_mime "$2" "x-scheme-handler/$1" || return
#   }
#
# set_browser_mime with no MIME argument defaults to text/html, so the first
# line makes the desktop file the default text/html handler before the second
# registers the scheme. xdg-utils 1.2.1 no longer has the stray line. On an
# affected desktop every Wispr Flow start therefore rewrites
# `text/html=wispr-flow.desktop` into ~/.config/mimeapps.list, over whatever
# the user chose, and .html files "open" in Wispr Flow.
#
# Reproduced with the 1.1.3 scripts against a scratch HOME under
# GNOME_DESKTOP_SESSION_ID: text/html goes firefox.desktop ->
# wispr-flow.desktop on the call, and again after the user sets it back.
# xdg-utils 1.2.1 leaves text/html alone on the same input.
#
# THE PATCH (surgical, one call)
# ------------------------------
# Short-circuit the call on Linux:
#
#   e.app.setAsDefaultProtocolClient("wispr-flow")
#     becomes
#   ("linux"===process.platform/*WISPR_LINUX_PROTOCOL_REGISTRATION*/||
#     e.app.setAsDefaultProtocolClient("wispr-flow"))
#
# Linux evaluates to `true` without spawning xdg-settings; darwin and win32
# still make the call exactly as shipped. The scheme is registered the way
# Linux packages do it instead: the desktop entry the makers write (and the
# Nix desktop item) declares `MimeType=x-scheme-handler/wispr-flow;`, which
# update-desktop-database indexes at install time. Nothing writes the user's
# mimeapps.list any more.
#
# The AppImage loses nothing: its desktop file is ai.wisprflow.WisprFlow.desktop
# and Electron asks xdg-settings for wispr-flow.desktop, so the runtime
# registration never succeeded there.
#
# Anchor: the developer API name plus the scheme literal, which survive
# minification. The `<e>.app` receiver is captured and kept, never hardcoded.
# The call occurs exactly once in the bundle (1.6.957 and 1.6.1102); a second
# setAsDefaultProtocolClient of any shape fails the count rather than being
# left to run.
#
# Usage: linux-protocol-registration.sh [path-to-.webpack/main/index.js]
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_PROTOCOL_REGISTRATION" "${1:-}" \
	"extract/app/.webpack/main/index.js"

# --- Patch (app receiver DERIVED, not hardcoded) ------------------------------
python3 - "$BUNDLE" "$MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Anchor: <e>.app.setAsDefaultProtocolClient("wispr-flow"). The receiver is a
# minified identifier that churns, so it rides along inside the match.
site = re.compile(
    r'[\w$]+\.app\.setAsDefaultProtocolClient\("wispr-flow"\)'
)
matches = list(site.finditer(data))
if len(matches) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 setAsDefaultProtocolClient(\"wispr-flow\") "
        f"call, found {len(matches)}. The bundle layout may have changed; "
        f"inspect manually around `setAsDefaultProtocolClient`."
    )

# Any other registration (another scheme, a path/args form, a computed scheme)
# would still reach xdg-settings on Linux. Refuse rather than leave it running.
total = data.count('setAsDefaultProtocolClient')
if total != 1:
    sys.exit(
        f"ERROR: expected exactly 1 setAsDefaultProtocolClient reference, "
        f"found {total}. A second registration would still run xdg-settings "
        f"on Linux; re-audit before patching."
    )

# Parenthesized so the `||` cannot rebind against whatever surrounds the call
# (today an assignment in a comma expression). Plain concatenation: the
# replacement goes through a lambda, so no `\g`/`$&` sequence is interpreted.
def gate(m):
    return (
        '("linux"===process.platform/*' + marker + '*/||'
        + m.group(0) + ')'
    )

data, n = site.subn(gate, data, count=1)
if n != 1:
    sys.exit(f"ERROR: substitution applied {n} times (expected 1).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print("Patched: setAsDefaultProtocolClient(\"wispr-flow\") short-circuited on "
      "linux (1 site).")
PY

# --- Verify the result --------------------------------------------------------
patch_verify_marker

# The gate must sit directly in front of the original call (proves the marker
# landed on the registration, not somewhere else).
patch_expect_shape -qP \
	'\("linux"===process\.platform/\*'"$MARKER"'\*/\|\|[\w$]+\.app\.setAsDefaultProtocolClient\("wispr-flow"\)\)' \
	-- 'gate not adjacent to the protocol registration.'

# Syntax-check the patched bundle.
patch_finish "Linux protocol registration short-circuited in $BUNDLE"
echo
echo "Patched startup now does (conceptually):"
echo "  const ok = process.platform === 'linux'"
echo "    || app.setAsDefaultProtocolClient('wispr-flow');"
echo
echo "Linux no longer runs xdg-settings at start; the wispr-flow: scheme is"
echo "registered by the desktop entry's MimeType=. darwin/win32 are unchanged."
