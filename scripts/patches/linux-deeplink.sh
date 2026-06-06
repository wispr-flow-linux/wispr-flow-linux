#!/usr/bin/env bash
#===============================================================================
# linux-deeplink.sh -- fix cold-start `wispr-flow:` deep-link handling on Linux
# in the Wispr Flow main bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# Wispr Flow registers itself as the `wispr-flow:` protocol handler
# (setAsDefaultProtocolClient("wispr-flow")) and routes inbound deep links to a
# dispatcher (the minified `L(...)`). There are THREE delivery paths:
#
#   * macOS  -> the `open-url` Electron event (handled, platform-correct).
#   * already-running app (any OS) -> the `second-instance` event, which scans
#       the new instance's argv for a `wispr-flow:` URL. That handler IS
#       platform-neutral in practice -- but note its inner argv scan is ALSO
#       wrapped in `if(<isWin32>){...}` (see below), so on Linux a deep link to
#       an already-running app falls through to the "focus the window" branch
#       and the URL payload is dropped too. We do NOT touch that site here.
#   * COLD START (app not yet running) -> on Windows AND Linux the OS launches
#       the app with the `wispr-flow:` URL appended to process.argv. The bundle
#       parses it out at startup with:
#
#         if(<isWin32>){
#           const e=B(process.argv.find(e=>
#             e.startsWith("wispr-flow:")||e.startsWith("wispr-flow/")));
#           e&&L(e);
#         }
#
#       This block is gated to win32 ONLY. macOS doesn't need it (it uses
#       open-url), but Linux DOES -- Linux delivers protocol URLs via argv just
#       like Windows. So launching from a `wispr-flow:` link while the app is
#       NOT running silently drops the URL on Linux. That is the bug.
#
# Confirmed against the shipped minified bytes (extract/.../main/index.js):
#   ...quitting"),void e.app.quit();if(f.H8){const e=B(process.argv.find(
#       e=>e.startsWith("wispr-flow:")||e.startsWith("wispr-flow/")));e&&L(e)}
#       e.app.on("second-instance",(t,r)=>{ ...
# where `f.H8` resolves to the win32 flag (`H8:()=>c` with
# `c="win32"===process.platform`; cf. `d.H8?"windows":d.tD?"macos"` and the
# `tD`=darwin flag used by helper-resolver.sh). `process.argv.find` occurs
# EXACTLY ONCE in the whole bundle, so it uniquely pins the cold-start site and
# can never collide with the `second-instance` handler (which scans `r.find`).
#
# THE PATCH (surgical, one site)
# ------------------------------
# Widen the win32 guard at THAT site only, so Linux is included:
#
#   if(f.H8){const e=B(process.argv.find(...
#     becomes
#   if(f.H8||"linux"===process.platform){/*WISPR_LINUX_DEEPLINK*/const e=B(...
#
# We anchor on `process.argv.find` (a stable developer API call, unique in the
# bundle) and capture the preceding `if(<winflag>){` -- where <winflag> is a
# minified `obj.prop` accessor we read back out of the match rather than
# hardcoding -- then rewrite just the `{` that opens that block. This cannot
# regress Windows (f.H8 still wins) or macOS (neither branch is true; open-url
# is unaffected). It does NOT touch any Squirrel/registry win32 logic elsewhere
# that may share the same flag, because the edit is scoped to the single
# `process.argv.find` cold-start site.
#
# Usage: linux-deeplink.sh [path-to-.webpack/main/index.js]
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
	# default to the in-repo extracted bundle
	BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	BUNDLE="$BUNDLE/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
	echo "ERROR: bundle not found: $BUNDLE" >&2
	exit 1
fi

# --- Idempotency guard --------------------------------------------------------
LINUX_MARKER="WISPR_LINUX_DEEPLINK"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
	cp -p "$BUNDLE" "$BUNDLE.orig"
	echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (win32 flag accessor DERIVED, not hardcoded) -----------------------
# The minified win32 accessor (`f.H8` today) churns between releases, so we read
# it back out of the match. The STABLE anchor is the developer API call
# `process.argv.find` plus the `wispr-flow:` scheme literal that follows it --
# both survive minification and together occur exactly once.
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Anchor: the cold-start win32 guard immediately followed by the argv scan for
# the wispr-flow: URL. Capture the win32 flag accessor (obj.prop) so we widen
# THIS guard only, never any other site that shares the flag.
#
#   if(<winflag>){const <v>=<B>(process.argv.find(<a>=>
#       <a>.startsWith("wispr-flow:")
anchor = re.compile(
    r'if\((?P<flag>[\w$]+(?:\.[\w$]+)?)\)\{'        # if(<winflag>){
    r'const\s+[\w$]+='                              #   const <v>=
    r'[\w$]+\('                                     #   <B>(
    r'process\.argv\.find\('                        #   process.argv.find(
    r'(?P<a>[\w$]+)=>'                              #     <a>=>
    r'(?P=a)\.startsWith\("wispr-flow:"\)'          #     <a>.startsWith("wispr-flow:")
)
matches = list(anchor.finditer(data))
if len(matches) != 1:
    sys.exit(
        f"ERROR: expected exactly 1 cold-start argv deep-link guard, "
        f"found {len(matches)}. The bundle layout may have changed; "
        f"inspect manually around `process.argv.find`."
    )

flag = matches[0].group('flag')

# Widen the guard: insert the linux clause and the marker right after the `{`
# that opens the win32-gated block. Build with concatenation so no `$N`/`$&`
# sequence can be eaten by a replacement DSL (we use a lambda anyway).
def widen(m):
    head = m.group(0)
    open_brace = head.index('){') + 1   # position of `)` before `{`
    # head[:open_brace] == 'if(<flag>)'  ; head[open_brace:] == '{const ...'
    return (
        'if(' + flag + '||"linux"===process.platform)'
        '{/*' + marker + '*/'
        + head[open_brace + 1:]          # skip the original '{'
    )

data, n = anchor.subn(widen, data, count=1)
if n != 1:
    sys.exit(f"ERROR: substitution applied {n} times (expected 1).")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: derived win32 flag={flag!r}; cold-start argv guard widened "
      f"to include linux (1 site).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found)." >&2
	echo "       Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# The widened guard must sit immediately before the argv scan (proves we hit the
# cold-start site, not some unrelated marker placement).
if ! grep -q '"linux"===process.platform){/\*'"$LINUX_MARKER"'\*/const' "$BUNDLE"; then
	echo "ERROR: marker not adjacent to the argv guard. Restoring backup." >&2
	cp -p "$BUNDLE.orig" "$BUNDLE"
	exit 1
fi

# Syntax-check: catch a replacement that serializes but doesn't parse before it
# ever reaches asar.
if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi

echo "OK: Linux cold-start deep-link guard widened in $BUNDLE"
echo
echo "Patched startup now does (conceptually):"
echo "  if (isWin32 || process.platform === 'linux') {"
echo "    const url = process.argv.find(a => a.startsWith('wispr-flow:'));"
echo "    if (url) dispatchDeepLink(url);"
echo "  }"
echo
echo "So launching from a 'wispr-flow:' link while the app is NOT running now"
echo "delivers the URL on Linux (macOS still uses open-url; the already-running"
echo "second-instance path is unchanged)."
