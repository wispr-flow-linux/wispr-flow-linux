#!/usr/bin/env bash
#===============================================================================
# patch-helper-resolver.sh
#
# Adds a 'linux' branch to the Wispr Flow helper-path resolver in the
# webpack-bundled Electron main process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# The shipped main bundle resolves the native helper binary with a TWO-WAY
# platform switch (isMac ? <mac path> : <windows path>) and NO Linux case.
# On Linux, process.platform === 'linux' is neither, so it falls into the
# Windows branch and builds a path ending in
#   ${resourcesRoot}\Release\Wispr Flow Helper.exe
# which (a) uses Windows backslashes and (b) points at a PE binary that does
# not exist on Linux -> existsSync() fails -> "Helper service script path not
# found" -> the entire text-injection feature is dead.
#
# UPSTREAM CODE, two shapes so far (see docs/reference/ipc-contract.md S8).
# Minified symbols churn per release; the names below are 1.6.897's:
#          f.tD = ("darwin"===process.platform) i.e. isMac;
#          S.ZI = the resources root dir (parent of the Release/ folder);
#          E.ty.isHelperProcessRunningManually = dev-mode flag;
#          d() = node:fs; l() = logger.
#
# Inline, through 1.6.897 (the ternary sits in the spawn function):
#
#   const s = f.tD
#     ? E.ty.isHelperProcessRunningManually
#         ? (l().info("Running Dev Mac Helper service"),
#            `${S.ZI}/swift-helper-app/DerivedData/Wispr Flow Helper/Build/Products/Debug/Wispr Flow.app/Contents/MacOS/Wispr Flow`)
#         : (l().info("Running packaged Mac Helper service"),
#            `${S.ZI}/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow`)
#     : E.ty.isHelperProcessRunningManually || !a.app.isPackaged
#         ? (l().info("Running Dev Windows Helper service"),
#            `${S.ZI}\\windows-helper-app\\Wispr Flow Helper\\Release\\Wispr Flow Helper.exe`)
#         : (l().info("Running packaged Windows Helper service"),
#            `${S.ZI}\\Release\\Wispr Flow Helper.exe`);
#   if(!d().existsSync(s)) return void l().error("Helper service script path not found", ...);
#
# Own module, since 1.6.937 (the same ternary is the body of an exported
# arrow function; the spawn function and the meeting recorder's native
# capture both call it):
#
#   const l = () => o.tD ? a.ty.isHelperProcessRunningManually ? (...) : (...)
#                        : a.ty.isHelperProcessRunningManually || !r.app.isPackaged ? (...) : (...);
#   ...
#   const s = (0, f.j)(); if(!d().existsSync(s)) return void l().error(...);
#
# THE PATCH (surgical, one insertion point)
# -----------------------------------------
# We do NOT rewrite the nested ternary (fragile to re-derive in minified code
# and risks the mac/win paths). Instead we PREPEND a Linux case to it:
#   const s = "linux"===process.platform
#     ? (l().info("Running packaged Linux Helper service"),
#        path.join(process.resourcesPath, "Release", "wispr-flow-linux-helper"))
#     : f.tD ? <mac> : <win>;
# On mac/win the new case is false, so the patch cannot regress them.
#
# Since 1.6.937 the ternary lives in its own exported resolver
# (`const l=()=>f.tD?...`) and the caller does `const s=(0,f.j)();
# if(!fs().existsSync(s))`, so an anchor on the existsSync guard no longer
# works. The ternary head is the same in both shapes, and it is keyed on stable
# strings (the Dev-Mac log line and isHelperProcessRunningManually), not on
# minified symbols.
#
# The Linux case uses process.resourcesPath rather than the minified `_.ZI`
# resources-root symbol. On a packaged build process.resourcesPath is the
# directory that contains Release/ and app.asar.
#
# stdio / fd-3 / exec-bit notes: see PATCH NOTES at the bottom of this file.
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
LINUX_MARKER="WISPR_LINUX_HELPER_BRANCH"
if grep -q "$LINUX_MARKER" "$BUNDLE"; then
  echo "Already patched ($LINUX_MARKER present in $BUNDLE) - nothing to do."
  exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
  cp -p "$BUNDLE" "$BUNDLE.orig"
  echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (the one minified symbol used is DERIVED from a developer string) --
# The logger accessor churns every release, so it is not hardcoded: it is read
# out of the "Running packaged Windows Helper service" log line. The insertion
# point is the ternary head, located by the isHelperProcessRunningManually
# property and the "Running Dev Mac Helper service" log line. Nothing else in
# the bundle is referenced, so a re-minify that renames every symbol still
# patches correctly, or fails loudly on the exactly-one assertion -- never a
# silent no-op.
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# Any JS string delimiter. A bundler swap can re-emit every "literal" as a
# `literal` (docs/learnings/patching-minified-js.md, "Quote style"), so no
# anchor below spells a quote.
Q = r'[`"\']'

# 1) Logger accessor, from the packaged-Windows-helper log line (stable string).
lg = set(re.findall(
    r'([\w$]+)\(\)\.info\(' + Q + r'Running packaged Windows Helper service' + Q,
    data))
if len(lg) != 1:
    sys.exit(f"ERROR: could not uniquely derive logger symbol (candidates: {sorted(lg)}).")
LOG = lg.pop()

# 2) Anchor: the head of the resolver's isMac ternary, keyed on the Dev-Mac log
#    line (stable string) and the isHelperProcessRunningManually property.
#    We PREPEND a Linux case to the ternary rather than inserting a statement
#    after it, so the anchor holds for both shapes Wispr has shipped:
#      <=1.6.897  const s=isMac?...:...;if(!fs().existsSync(s))...   (inline)
#      >=1.6.937  const l=()=>isMac?...:...   (own module; caller does
#                 `const s=(0,f.j)();if(!fs().existsSync(s))`)
#    No variable is reassigned, so no const->let flip is needed either.
head = re.compile(
    r'(?=[\w$]+\.[\w$]+\?[\w$]+\.[\w$]+\.isHelperProcessRunningManually\?\('
    + re.escape(LOG) + r'\(\)\.info\(' + Q + r'Running Dev Mac Helper service' + Q + r'\))'
)
if len(head.findall(data)) != 1:
    sys.exit(f"ERROR: expected exactly 1 helper-resolver ternary head, found {len(head.findall(data))}.")

linux_case = (
    '"linux"===process.platform/*' + marker + '*/?(' + LOG +
    '().info("Running packaged Linux Helper service"),'
    'require("path").join(process.resourcesPath,"Release","wispr-flow-linux-helper")):'
)
data = head.sub(lambda m: linux_case, data, count=1)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: derived logger={LOG!r}; Linux case prepended to the resolver ternary.")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$LINUX_MARKER" "$BUNDLE"; then
  echo "ERROR: post-patch verification failed (marker not found)." >&2
  echo "       Restoring backup." >&2
  cp -p "$BUNDLE.orig" "$BUNDLE"
  exit 1
fi

# Syntax-check: the override inserts a real JS statement; catch a replacement
# that serializes but doesn't parse before it ever reaches asar.
if command -v node >/dev/null; then
  if ! node --check "$BUNDLE"; then
    echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
    cp -p "$BUNDLE.orig" "$BUNDLE"
    exit 1
  fi
  echo "node --check OK"
fi
echo "OK: Linux helper-path branch inserted into $BUNDLE"
echo
echo "Patched resolver now does (conceptually):"
echo "  s = linux ? path.join(process.resourcesPath, 'Release', 'wispr-flow-linux-helper')"
echo "      : isMac ? <mac> : <win>;"
echo "  if (!fs.existsSync(s)) { ...feature dead... }"
echo
echo "Stage the helper at: <resourcesPath>/Release/wispr-flow-linux-helper (exec bit set)."

#===============================================================================
# PATCH NOTES (verified against extract/app/.webpack/main/index.js)
#===============================================================================
#
# 1. STDIO / fd-3 -- ALREADY CORRECT, NO PATCH NEEDED.
#    The helper spawn site (byte ~3666403) is platform-agnostic:
#      spawn(s, { stdio:["pipe","pipe","pipe","pipe"],
#                 env:{ sentryDSN, environment, segmentWriteKey,
#                       postHogProjectKey, sentryLocalDebug } })
#    The 4-pipe stdio (fd 3 = IPC return channel) is hard-coded for ALL
#    platforms, so our Linux helper gets fd 3 automatically. Good.
#
# 2. EXECUTABLE BIT -- NOT SET BY THE APP. MUST be set at build/stage time.
#    The spawn site does NOT chmod the helper. It only checks X_OK in the
#    *catch* block (i.e. after spawn already failed) for diagnostics:
#      catch(e){ try{ await fs.promises.access(s, fs.constants.X_OK); ... } }
#    So if the staged Linux helper is not already +x, spawn() throws ENOEXEC/
#    EACCES and the feature is dead. => build-linux.sh MUST chmod +x the
#    staged helper (and packaging must preserve the mode). This is handled in
#    build-linux.sh (stage_linux_helper) and verified there.
#
# 3. ENV -- the spawn passes a REPLACEMENT env object (sentry/segment/posthog
#    keys only), NOT a spread of process.env. The Rust helper ignores the
#    telemetry keys, BUT the missing session vars (WAYLAND_DISPLAY/DISPLAY/
#    XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS) make its backend detection fall
#    to the no-op `stub` injector -> text injection is silently dead. This is
#    NOT harmless; helper-env.sh prepends `...process.env,` to fix it.
#
# 4. PATH ROOT -- the Linux case uses process.resourcesPath (robust) instead
#    of the minified resources-root symbol. On a packaged build both resolve to
#    the dir that contains Release/ and app.asar, and process.resourcesPath is
#    safer across forge layouts.
#===============================================================================
