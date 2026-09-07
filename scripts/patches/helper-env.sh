#!/usr/bin/env bash
#===============================================================================
# patch-helper-env.sh
#
# Restores the session environment to the native-helper child process in the
# webpack-bundled Electron main process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# The shipped main bundle spawns the native helper with a REPLACEMENT env
# object that lists only telemetry keys -- it does NOT spread process.env.
# Up to 1.6.7 that object was inline at the spawn site:
#
#   helper.process = spawn(s, {
#     stdio:["pipe","pipe","pipe","pipe"],
#     env:{ sentryDSN, environment, segmentWriteKey,
#           postHogProjectKey, sentryLocalDebug } })
#
# As of 1.6.774 upstream hoisted it into a factory, so the spawn site reads
# `env:N()` and the object literal lives elsewhere in the module:
#
#   N = (packaged = app.isPackaged) => ({ sentryDSN, environment,
#         segmentWriteKey, postHogProjectKey, sentryLocalDebug,
#         developmentFileLogging })
#   ... spawn(s, { stdio:["pipe","pipe","pipe","pipe"], env:N() })
#
# The env is still telemetry-only either way, so the bug is unchanged -- but an
# anchor on the spawn site's `env:{` stopped matching and this patch silently
# no-op'd (caught by verify-patches.sh, which fails the build on the missing
# marker). We now anchor on the OBJECT rather than on where it is consumed.
#
# On macOS/Windows the helper talks to the OS through native APIs and needs no
# session env, so upstream never spread process.env. But the Linux helper's
# backend detection (the helper's src/backend/mod.rs::pick_injector;
# github.com/wispr-flow-linux/helper) gates
# the Wayland/X11 injection + clipboard + active-app backends on the session
# env vars WAYLAND_DISPLAY / DISPLAY (and, to actually connect, XDG_RUNTIME_DIR
# and DBUS_SESSION_BUS_ADDRESS). With the replacement env none of those reach
# the child, so the helper falls through to the no-op `stub` backend:
#
#   WARN  ...backend] injection: stub (no-op) -- OS integration disabled
#
# The mic records and shortcuts fire (keypress capture reads /dev/input
# directly, needing no env), but PasteText returns
#   "PasteText failed: no backend available (stub)"
# and nothing is ever injected into the focused field. This was misdiagnosed in
# helper-resolver.sh PATCH NOTE #3 as "harmless"; it is the cause of the dead
# text injection. See docs/learnings/helper-spawn-env.md.
#
# THE PATCH (surgical, one insertion point)
# -----------------------------------------
# Anchor on the telemetry env object's OWN opening -- `{sentryDSN:` -- rather
# than on the spawn call that consumes it. Property names are not mangled by the
# current bundler, so this survives re-minification AND survives the object
# being hoisted, inlined, or wrapped in a factory: wherever the object is built,
# that is where the spread belongs. `sentryDSN` appears exactly ONCE in the
# whole bundle (asserted below), so the anchor cannot drift onto another object.
#
# Insert a `...process.env,` spread at the FRONT of the object so the session
# env propagates, while the telemetry keys that follow still override anything of
# the same name. On mac/win this only adds the (harmless) parent env the helper
# already ignores, so the patch cannot regress those platforms.
#
#   {...process.env,sentryDSN:...}   (marker comment carries the grep token)
#
# stdio / fd-3 / exec-bit notes live in helper-resolver.sh PATCH NOTES.
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
  # default to the in-repo extracted bundle
  BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
  echo "ERROR: bundle not found: $BUNDLE" >&2
  exit 1
fi

# --- Idempotency guard --------------------------------------------------------
ENV_MARKER="WISPR_LINUX_HELPER_ENV"
if grep -q "$ENV_MARKER" "$BUNDLE"; then
  echo "Already patched ($ENV_MARKER present in $BUNDLE) - nothing to do."
  exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
  cp -p "$BUNDLE" "$BUNDLE.orig"
  echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (anchored on stable string/property literals, no minified ids) -----
python3 - "$BUNDLE" "$ENV_MARKER" <<'PY'
import sys, io
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# The telemetry-only replacement env object handed to the helper spawn. Anchored
# on its first property name (a preserved developer identifier), so it is found
# whether the object sits inline at the spawn site (<=1.6.7) or inside a factory
# the spawn calls (>=1.6.774). Asserted unique; if upstream ever spreads
# process.env itself, the check below makes this a clean no-op.
anchor = '{sentryDSN:'
n = data.count(anchor)
if n != 1:
    sys.exit(f"ERROR: expected exactly 1 telemetry env object anchor "
             f"('{anchor}'), found {n}.")

# Sanity-check the object really is the helper spawn's env: the 4-pipe stdio
# spawn (fd 3 = the helper IPC channel) must exist too. Cheap, and it fails
# closed if a future bundle reuses these property names for something else.
if data.count('stdio:["pipe","pipe","pipe","pipe"]') != 1:
    sys.exit('ERROR: expected exactly 1 four-pipe helper spawn site; '
             'the bundle layout may have changed -- inspect manually.')

after = data[data.find(anchor) + len(anchor):]
if after.startswith("...process.env") or after.startswith(f"/*{marker}*/"):
    sys.exit(0)  # already spreads the parent env -- nothing to do

# Insert the marker comment + spread at the front of the env object literal --
# i.e. just inside the `{`, BEFORE the property name the anchor also spans.
# (Appending after the whole anchor would land inside the `sentryDSN:` value
# position and produce `{sentryDSN:...process.env,`, a syntax error.)
repl = "{" + f"/*{marker}*/" + "...process.env," + anchor[1:]
data = data.replace(anchor, repl, 1)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print("Patched: spread process.env into the helper-spawn env object (1).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$ENV_MARKER" "$BUNDLE"; then
  echo "ERROR: post-patch verification failed (marker not found)." >&2
  echo "       Restoring backup." >&2
  cp -p "$BUNDLE.orig" "$BUNDLE"
  exit 1
fi

# Syntax-check: the spread is inside an object literal; catch any edit that
# serializes but doesn't parse before it ever reaches asar.
if command -v node >/dev/null; then
  if ! node --check "$BUNDLE"; then
    echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
    cp -p "$BUNDLE.orig" "$BUNDLE"
    exit 1
  fi
  echo "node --check OK"
fi
echo "OK: helper-spawn env now inherits the session environment in $BUNDLE"
echo
echo "Patched spawn now does (conceptually):"
echo "  env object := { ...process.env, sentryDSN, environment, ... }"
echo "  spawn(helper, { stdio:[...x4], env: <that object> });"
