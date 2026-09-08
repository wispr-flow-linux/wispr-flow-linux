#!/usr/bin/env bash
#===============================================================================
# patch-linux-early-singleton.sh -- take the Electron single-instance lock at
# the very top of the Wispr Flow main bundle, before any other code runs.
#
# Bug it fixes (observed 2026-08-18 / 2026-08-26, 9 coredumps):
#   The vendor bundle calls app.requestSingleInstanceLock() only at the END of
#   its ~8.3 MB main bundle, after the full app has initialized (native
#   .node modules, better-sqlite3, helper IPC, window scaffolding). A second
#   launch therefore runs that entire init and then quits -- and teardown of
#   half-initialized native state aborts with
#       V8 FATAL: Error::ThrowAsJavaScriptException napi_throw -> SIGABRT
#   killing the second instance (and in the worst case destabilizing the
#   session with a crash loop: 4 SIGABRTs in 6s on 2026-08-26 12:23).
#
# Fix:
#   Prepend a guard before the webpack IIFE: if the lock is not acquired,
#   app.quit() + process.exit(0) immediately. Nothing else in the bundle ever
#   executes -- the abort class becomes unreachable. The already-running
#   primary still receives the `second-instance` event (delivered during the
#   failed lock handshake, before process.exit) and focuses its hub window,
#   which is exactly the UX a user expects from clicking the icon again.
#   `--quit-app` and wispr-flow: deep-link argv keep working: the primary's
#   existing second-instance handler reads them from the argv it receives.
#
# Lock-path note: the guard relies on Electron's default userData-derived
# singleton path, the same mechanism the vendor's late call uses (neither
# setPath('userData') before locking), so both resolve to the identical
# ~/.config/Wispr Flow/SingletonLock. Do not add a setPath here -- that could
# fork the lock namespace.
#
# Surgical edit (idempotent, keeps a .earlysingleton.orig backup, verified):
#   /*! For license ... */            <- vendor license comment stays first
#   /*WISPR_LINUX_EARLY_SINGLETON_V1*/try{...process.exit(0)}catch{}
#   !function(){...}                  <- webpack IIFE, untouched
#
# Usage: patch-linux-early-singleton.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
  echo "usage: $0 <.webpack/main/index.js>" >&2
  exit 2
fi

python3 - "$BUNDLE" <<'PY'
import sys, shutil

path = sys.argv[1]
src = open(path, 'r', encoding='utf-8', errors='surrogateescape').read()

MARKER = 'WISPR_LINUX_EARLY_SINGLETON_V1'
GUARD = (
    '/*' + MARKER + '*/'
    'try{var __wisprApp=require("electron").app;'
    'if(__wisprApp&&!__wisprApp.requestSingleInstanceLock()){'
    '__wisprApp.quit(),process.exit(0)}}catch(__wisprErr){}'
)

if MARKER in src:
    print("Already patched (marker %s present). Nothing to do." % MARKER)
    sys.exit(0)

# Keep the vendor license banner as line 1; insert the guard right after it
# (or at byte 0 when there is no banner). The banner shape is stable across
# webpack builds: /*! For license information please see ... */
first_line, _nl, rest = src.partition('\n')
if first_line.startswith('/*!') and first_line.rstrip().endswith('*/'):
    patched = first_line + '\n' + GUARD + '\n' + rest
else:
    patched = GUARD + '\n' + src

shutil.copyfile(path, path + ".earlysingleton.orig")
print("Backup written:", path + ".earlysingleton.orig")

# Verify: marker present exactly once, and located before the webpack IIFE
# start (`!function` at this build's head) so nothing precedes the guard
# except the license comment.
if patched.count(MARKER) != 1:
    print("ERROR: verification failed -- marker count != 1.", file=sys.stderr)
    sys.exit(1)
head = patched[:patched.index(MARKER)]
if 'function' in head.replace('For license information', ''):
    print("ERROR: verification failed -- code precedes the guard.",
          file=sys.stderr)
    sys.exit(1)

open(path, 'w', encoding='utf-8', errors='surrogateescape').write(patched)
print("OK: early single-instance guard inserted (%d bytes)." % len(GUARD))
PY

# Syntax-check the patched bundle.
if command -v node >/dev/null; then
  node --check "$BUNDLE" && echo "node --check OK"
fi
echo "Done: a second instance now exits before any initialization runs."
