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
# EXACT CURRENT CODE (recovered from extract/app/.webpack/main/index.js,
# byte offset ~3663489; see docs/reference/ipc-contract.md S8). Minified
# symbols: f.tD = ("darwin"===process.platform) i.e. isMac;
#          _.ZI = the resources root dir (parent of the Release/ folder);
#          E.ty.isHelperProcessRunningManually = dev-mode flag;
#          d() = node:fs; l() = logger.
#
#   const s = f.tD
#     ? E.ty.isHelperProcessRunningManually
#         ? (l().info("Running Dev Mac Helper service"),
#            `${_.ZI}/swift-helper-app/DerivedData/Wispr Flow Helper/Build/Products/Debug/Wispr Flow.app/Contents/MacOS/Wispr Flow`)
#         : (l().info("Running packaged Mac Helper service"),
#            `${_.ZI}/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow`)
#     : E.ty.isHelperProcessRunningManually
#         ? (l().info("Running Dev Windows Helper service"),
#            `${_.ZI}\\windows-helper-app\\Wispr Flow Helper\\Release\\Wispr Flow Helper.exe`)
#         : (l().info("Running packaged Windows Helper service"),
#            `${_.ZI}\\Release\\Wispr Flow Helper.exe`);
#   if(!d().existsSync(s)) return void l().error("Helper service script path not found", ...);
#
# THE PATCH (surgical, one insertion point)
# -----------------------------------------
# We do NOT rewrite the nested ternary (fragile to re-derive in minified code
# and risks the mac/win paths). Instead we insert a single Linux *override*
# immediately AFTER the resolver assignment and BEFORE the existsSync() guard.
# When running on Linux we reassign `s` to the bundled Rust helper, staged at
#   ${resourcesRoot}/Release/wispr-flow-linux-helper
# (forward slashes; same Release/ folder the Windows helper used, so _.ZI is
# reused unchanged). On mac/win the override is a no-op, so the patch cannot
# regress those platforms.
#
# Anchor (unique in the bundle), keyed on the stable string literal -- NOT on
# the minified symbols, which are derived from nearby developer strings so the
# patch survives re-minification (see the "Patch" section below):
#   `${_.ZI}\\Release\\Wispr Flow Helper.exe`);if(!<fs>().existsSync(<var>))
# We split it at  `...Helper.exe`);  and  if(!<fs>().existsSync(<var>))
# inserting the Linux override (which reassigns the derived <var>) between them.
#
# The override re-derives the resources root locally (process.resourcesPath)
# rather than trusting the minified `_.ZI` symbol, so the patch is robust even
# if `_.ZI` is something other than process.resourcesPath. On a packaged build
# process.resourcesPath is the directory that contains Release/ and app.asar.
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

# --- Patch (all minified symbols DERIVED from stable developer strings) -------
# Minified identifiers (the logger accessor, the fs accessor, the resolver
# result variable) churn every release, so we do NOT hardcode them. Instead we
# anchor on developer strings that survive minification and read the live
# identifiers back out of the match:
#
#   * logger accessor   <- the literal  "Running packaged Windows Helper service"
#   * resolver variable <- the literal  `Wispr Flow Helper.exe`  + existsSync(...)
#   * resolver decl     <- the property  isHelperProcessRunningManually  (+ var)
#
# The override reassigns the DERIVED variable and logs via the DERIVED logger,
# so a future re-minify that renames s/d/l still patches correctly (or fails
# loudly with a clear "could not derive" error -- never a silent no-op).
python3 - "$BUNDLE" "$LINUX_MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# 1) Logger accessor, from the packaged-Windows-helper log line (stable string).
lg = set(re.findall(r'([\w$]+)\(\)\.info\("Running packaged Windows Helper service"', data))
if len(lg) != 1:
    sys.exit(f"ERROR: could not uniquely derive logger symbol (candidates: {sorted(lg)}).")
LOG = lg.pop()

# 2) Anchor A: stable win-path literal + the existsSync guard. Capture the
#    resolver variable; the override is inserted just before this guard.
anchorA = re.compile(
    r'Wispr Flow Helper\.exe`\);'
    r'(?P<guard>if\(!(?P<fs>[\w$]+)\(\)\.existsSync\((?P<var>[\w$]+)\)\))'
)
ma = list(anchorA.finditer(data))
if len(ma) != 1:
    sys.exit(f"ERROR: expected exactly 1 existsSync resolver anchor, found {len(ma)}.")
VAR = ma[0].group('var')

# 3) Resolver declaration: const <VAR>=...isHelperProcessRunningManually? -> let.
#    `s` is const, so the override's reassignment would throw without this flip.
declRe = re.compile(
    r'const(\s+)' + re.escape(VAR) +
    r'(=[\w$]+\.[\w$]+\?[\w$]+\.[\w$]+\.isHelperProcessRunningManually\?)'
)
if len(declRe.findall(data)) != 1:
    sys.exit(f"ERROR: expected exactly 1 'const {VAR}=...isHelperProcessRunningManually' decl.")

# Build the Linux override against the DERIVED logger + resolver variable.
override = (
    'if("linux"===process.platform){/*' + marker + '*/'
    'const _wlp=require("path").join(process.resourcesPath,"Release","wispr-flow-linux-helper");'
    + LOG + '().info("Running packaged Linux Helper service",'
    '{customAttributes:{serviceScriptPath:_wlp}});'
    + VAR + '=_wlp;}'
)

# Apply with lambda replacements (no regex-DSL backref interpolation on the
# replacement side): const->let first, then insert the override.
data = declRe.sub(lambda m: 'let' + m.group(1) + VAR + m.group(2), data, count=1)
data = anchorA.sub(lambda m: 'Wispr Flow Helper.exe`);' + override + m.group('guard'),
                   data, count=1)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: derived logger={LOG!r}, resolver var={VAR!r}; "
      f"const->let + Linux override inserted (1 each).")
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
echo "  const s = isMac ? <mac> : <win>;"
echo "  if (process.platform === 'linux')"
echo "    s = path.join(process.resourcesPath, 'Release', 'wispr-flow-linux-helper');"
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
# 4. PATH ROOT -- the override uses process.resourcesPath (robust) instead of
#    the minified _.ZI symbol. On a packaged build both resolve to the dir that
#    contains Release/ and app.asar. If you prefer to mirror _.ZI exactly,
#    replace the require("path").join(...) expression with
#    `${_.ZI}/Release/wispr-flow-linux-helper` -- but process.resourcesPath is
#    safer across forge layouts.
#===============================================================================
