#!/usr/bin/env bash
#===============================================================================
# patch-mac-gates.sh -- gate macOS-only startup checks to darwin in the
# Wispr Flow main bundle so they don't fire on Linux.
#
# Bug it fixes:
#   The app has a "must live in /Applications/Wispr Flow.app" guard implemented
#   as a regex on app.getAppPath(). On Linux the regex never matches, so in a
#   production build the app shows a blocking "Move Flow to Applications folder"
#   dialog and calls app.quit() -- killing the app on launch. The check is
#   inherently macOS-specific (it looks for a .app bundle under /Applications),
#   so we make the whole guard a no-op on non-darwin platforms.
#
# Surgical edit (idempotent, keeps a .macgate.orig backup, verified):
#   v=()=>{if(<earlyout>)return!1;const e=i.app.getAppPath() ...
#     becomes
#   v=()=>{if(<earlyout>)return!1;if("darwin"!==process.platform)return!1;const e=i.app.getAppPath() ...
#
# This cannot regress macOS (darwin still runs the full original check) and
# disables the guard on Linux/Windows where it is irrelevant.
#
# Usage: patch-mac-gates.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "usage: $0 <.webpack/main/index.js>" >&2
  exit 2
fi

python3 - "$BUNDLE" <<'PY'
import re, sys, shutil, subprocess

path = sys.argv[1]
src = open(path, 'r', encoding='utf-8', errors='surrogateescape').read()

GATE = 'if("darwin"!==process.platform)return!1;'

# Already patched? (gate sits immediately before the getAppPath() call)
if re.search(r'return!1;if\("darwin"!==process\.platform\)return!1;const\s+[\w$]+=[\w$]+\.app\.getAppPath', src):
    print("Already patched (darwin gate present before getAppPath). Nothing to do.")
    sys.exit(0)

# Anchor: the Applications-folder guard arrow fn. Every identifier here is
# minified and churns between builds (the arrow-fn var `v`, the early-out token
# `c.H8`, the result var, the `i.app` receiver), so we hardcode NONE of them.
# The stable token is the developer API name `.app.getAppPath()`; the
# surrounding `=()=>{if(<ident.ident>)return!1;const ...` shape disambiguates it
# from the other 11 getAppPath() call sites down to exactly one:
#   <id>=()=>{ if(<ident.ident>) return!1; const <id>=<id>.app.getAppPath()
anchor = re.compile(
    r'([\w$]+=\(\)=>\{if\([\w$]+\.[\w$]+\)return!1;)'  # group 1: arrow + early-out guard
    r'(const\s+[\w$]+=[\w$]+\.app\.getAppPath\(\))'    # group 2: getAppPath() call
)
matches = anchor.findall(src)
if len(matches) != 1:
    print(f"ERROR: expected exactly 1 Applications-folder guard anchor, found {len(matches)}.",
          file=sys.stderr)
    print("       The bundle layout may have changed; inspect manually.", file=sys.stderr)
    sys.exit(1)

shutil.copyfile(path, path + ".macgate.orig")
print("Backup written:", path + ".macgate.orig")

patched = anchor.sub(lambda m: m.group(1) + GATE + m.group(2), src, count=1)

# Verify the gate landed adjacent to getAppPath().
if not re.search(r'return!1;if\("darwin"!==process\.platform\)return!1;const\s+[\w$]+=[\w$]+\.app\.getAppPath', patched):
    print("ERROR: verification failed -- darwin gate not adjacent to getAppPath. Aborting.", file=sys.stderr)
    sys.exit(1)

open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: mac-only gate inserted.")
PY

# Syntax-check the patched bundle.
if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: on Linux/Windows the Applications-folder guard now returns false (no dialog, no quit)."
