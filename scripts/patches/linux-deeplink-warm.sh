#!/usr/bin/env bash
#===============================================================================
# linux-deeplink-warm.sh -- deliver `wispr-flow:` deep links to an already
# running app on Linux, in the Wispr Flow main bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# linux-deeplink.sh fixes the cold start. When the app is already running, the
# OS launches a second instance with the URL in argv; that instance loses the
# single-instance lock and Electron hands its argv to the primary through the
# `second-instance` event. The primary's handler scans that argv for the URL,
# but the scan is gated to win32:
#
#   e.app.on("second-instance",(t,r)=>{ ...
#     else{if(y.H8){const e=ee(r.find(e=>e.startsWith("wispr-flow:")||
#       e.startsWith("wispr-flow/")));if(e)return void re(e)}
#     n().info("User tried to open the app a second time while it was
#       already running"),(0,$.Xj)()}})
#
# so on Linux the URL is dropped and the handler only focuses the Hub. Every
# link opened while the app runs (a browser sign-in callback, a settings link)
# takes this path, since linux-early-singleton.sh makes each later launch hand
# its argv over before doing anything else.
#
# Confirmed against the shipped minified bytes of 1.6.1147. `y.H8` is the same
# win32 flag linux-deeplink.sh derives at the cold-start site.
#
# THE PATCH (surgical, one site)
# ------------------------------
#   if(y.H8){const e=ee(r.find(e=>e.startsWith("wispr-flow:")...
#     becomes
#   if(y.H8||"linux"===process.platform){/*WISPR_LINUX_WARM_DEEPLINK*/const ...
#
# The anchor is the scan of a handler-local argv array (`<argv>.find(...)`,
# never `process.argv.find(...)`, which is the cold-start site) for the
# `wispr-flow:` scheme literal, inside the `second-instance` listener. The
# win32 accessor and the argv name are read back out of the match. Windows
# (the flag still wins) and macOS (neither branch is true; it uses open-url)
# are unchanged.
#
# Usage: linux-deeplink-warm.sh [path-to-.webpack/main/index.js]
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_WARM_DEEPLINK" "${1:-}" \
	"extract/app/.webpack/main/index.js"

python3 - "$BUNDLE" "$MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# The win32-gated scan of the second-instance argv for the scheme literal:
#
#   if(<winflag>){const <v>=<parse>(<argv>.find(<a>=>
#       <a>.startsWith("wispr-flow:")
anchor = re.compile(
    r'if\((?P<flag>[\w$]+(?:\.[\w$]+)?)\)\{'        # if(<winflag>){
    r'const\s+[\w$]+='                              #   const <v>=
    r'[\w$]+\('                                     #   <parse>(
    r'(?P<argv>[\w$]+)\.find\('                     #   <argv>.find(
    r'(?P<a>[\w$]+)=>'                              #     <a>=>
    r'(?P=a)\.startsWith\("wispr-flow:"\)'          #     <a>.startsWith(...)
)
matches = list(anchor.finditer(data))
if len(matches) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 second-instance argv deep-link guard, "
        f"found {len(matches)}. The bundle layout may have changed; "
        f"inspect manually around `second-instance`."
    )
m = matches[0]
flag, argv = m.group('flag'), m.group('argv')

# The scan must sit in the second-instance listener, and <argv> must be that
# listener's argv parameter: (event, argv) => ...
listener = re.compile(
    r'\.on\("second-instance",\([\w$]+,' + re.escape(argv) + r'\)=>\{'
)
owners = [o for o in listener.finditer(data, 0, m.start())]
if not owners or m.start() - owners[-1].end() > 1000:
    sys.exit(
        f"ERROR: the {argv}.find(...) scan is not inside a "
        f"second-instance listener taking ({argv}); refusing to patch."
    )

def widen(match):
    head = match.group(0)
    body = head[head.index('){') + 2:]               # after the original `{`
    return (
        'if(' + flag + '||"linux"===process.platform)'
        '{/*' + marker + '*/' + body
    )

data, n = anchor.subn(widen, data, count=1)
if n != 1:
    sys.exit(f"ERROR: substitution applied {n} times (expected 1).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: derived win32 flag={flag!r}, argv={argv!r}; "
      f"second-instance deep-link guard widened to include linux (1 site).")
PY

patch_verify_marker

patch_expect_shape -q \
	'"linux"===process.platform){/\*'"$MARKER"'\*/const' \
	-- 'marker not adjacent to the second-instance argv guard.'

patch_finish "Linux second-instance deep-link guard widened in $BUNDLE"
echo
echo "Patched second-instance handler now does (conceptually):"
echo "  if (isWin32 || process.platform === 'linux') {"
echo "    const url = argv.find(a => a.startsWith('wispr-flow:'));"
echo "    if (url) return dispatchDeepLink(url);"
echo "  }"
