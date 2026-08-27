#!/usr/bin/env bash
#===============================================================================
# build-linux.sh  --  Phase-0 Linux repackaging pipeline for Wispr Flow
#
# Mirrors the claude-desktop-debian build.sh flow, adapted for Wispr Flow:
#   1. (DONE) extract Squirrel .exe -> nupkg -> Electron app payload
#   2. patch the webpack main bundle (add the 'linux' helper-path branch)
#   3. rebuild native node modules (better-sqlite3-multiple-ciphers, sqlite3)
#      for the Linux Electron 42 ABI
#   4. drop/stub Windows-only modules (win-ca / crypt32)
#   5. stage a Linux Electron 42 runtime
#   6. copy in the clean-room Rust helper (wispr-flow-linux-helper)
#   7. repack -> directory tree ready for electron-forge maker-deb/maker-rpm
#      (or a portable run-in-place tree).
#
# AUTOMATED vs MANUAL: each step prints [AUTO] or [MANUAL]. MANUAL steps are
# network-heavy (downloading the Linux Electron tarball, npm/yarn rebuild of
# native addons) and are documented + stubbed so the script is runnable
# offline up to the point a download/rebuild is actually required.
#===============================================================================
set -uo pipefail

# ---- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source layout produced by extraction (Track-1 already did this):
EXTRACT_DIR="$PROJECT_ROOT/extract"
NET45_DIR="$EXTRACT_DIR/nupkg/lib/net45"
RESOURCES_SRC="$NET45_DIR/resources"            # app.asar, app.asar.unpacked, Release/, assets, ...
WEBPACK_MAIN="$EXTRACT_DIR/app/.webpack/main/index.js"   # unpacked main bundle (source of truth)

# Clean-room Linux helper. It lives in its own repo
# (github.com/wispr-flow-linux/helper) and is consumed as a prebuilt release
# asset pinned in helper-version.txt. A pre-set HELPER_BIN (a local build, or
# CI's prefetched asset) is honored as an override; otherwise the build
# auto-fetches the pinned release into the local helper-bin/ drop spot
# (resolve_helper_bin). Track whether the caller supplied a value so a bad
# explicit override is reported instead of silently fetched over.
HELPER_BIN_PRESET="${HELPER_BIN:+1}"
HELPER_BIN="${HELPER_BIN:-$PROJECT_ROOT/helper-bin/wispr-flow-linux-helper}"

# Linux-rebuilt native modules (better-sqlite3-multiple-ciphers + sqlite3). The
# shipped app carries Windows PE .node; Step 4 swaps in the linux-$ARCH builds
# from here (see Step 4 for the @electron/rebuild recipe). Honor a pre-set env
# value first, else default to a local native-modules/ drop spot.
NATIVE_MODULES_DIR="${NATIVE_MODULES_DIR:-$PROJECT_ROOT/native-modules}"

# Build output:
WORK_DIR="$PROJECT_ROOT/build-linux"
STAGE="$WORK_DIR/stage"                          # becomes the app's resources/ tree
# These honor env overrides (set by the build.sh orchestrator) but default to
# the validated values when run standalone -- behavior is identical unless an
# override is exported. Keep APP_VERSION in lockstep with build.sh's APP_VERSION
# so a standalone `build-linux.sh` run stages the same version the orchestrator
# does (a divergent default silently mislabels the staged tree).
APP_VERSION="${APP_VERSION:-1.5.695}"
ELECTRON_MAJOR="${ELECTRON_MAJOR:-42}"
ELECTRON_VERSION="${ELECTRON_VERSION:-42.3.0}"
ARCH="${ARCH:-x64}"   # linux-x64; the helper + sqlite must match

# ---- helpers -----------------------------------------------------------------
say()   { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
auto()  { printf '  \033[1;32m[AUTO]\033[0m   %s\n' "$*"; }
manual(){ printf '  \033[1;33m[MANUAL]\033[0m %s\n' "$*"; }
warn()  { printf '  \033[1;31m[WARN]\033[0m   %s\n' "$*"; }

# Resolve the clean-room Linux helper into $HELPER_BIN, in priority order:
#   1. an executable HELPER_BIN override (CI's prefetched asset or a local
#      build) -- used as-is, never version-checked.
#   2. an executable binary in the default helper-bin/ drop spot, IF it is not
#      a stale fetch: fetch-helper-bin.sh stamps the downloaded tag into
#      helper-bin/.tag, and a stamp that disagrees with helper-version.txt
#      means the pin moved past the cache -- refetch. No stamp = a manual
#      pre-drop (the documented offline path) -- used as-is.
#   3. HELPER_BIN was explicitly set but is missing/non-executable: respect the
#      override -- warn and do NOT fetch over it.
#   4. fetch the pinned prebuilt release asset (fetch-helper-bin.sh, tag in
#      helper-version.txt) into the default helper-bin/ drop spot -- the
#      normal, supported path for local builds.
#   5. fetch failed:
#      - in CI: hard-fail. A package without the helper is non-functional.
#      - locally: warn and continue (preserves the offline dry-run behavior;
#        the packaging makers refuse a helper-less tree, so nothing broken
#        ships).
resolve_helper_bin() {
  local helper_dir pinned stamp
  helper_dir="$(dirname "$HELPER_BIN")"

  if [[ -x "$HELPER_BIN" ]]; then
    if [[ $HELPER_BIN_PRESET == 1 ]]; then
      auto "Found Linux helper binary: $HELPER_BIN"
      return 0
    fi
    pinned="$(tr -d '[:space:]' < "$PROJECT_ROOT/helper-version.txt" \
      2>/dev/null)"
    stamp=''
    [[ -f "$helper_dir/.tag" ]] \
      && stamp="$(tr -d '[:space:]' < "$helper_dir/.tag")"
    if [[ -z $stamp || $stamp == "$pinned" ]]; then
      auto "Found Linux helper binary: $HELPER_BIN"
      return 0
    fi
    warn "Cached helper in $helper_dir was fetched as $stamp but"
    warn "  helper-version.txt now pins $pinned -- refetching."
  fi

  if [[ $HELPER_BIN_PRESET == 1 ]]; then
    warn "HELPER_BIN is set but not executable: $HELPER_BIN"
    warn "  Respecting the override (not auto-fetching over it). Point it at a"
    warn "  built helper (e.g. <helper checkout>/target/release/"
    warn "  wispr-flow-linux-helper), or unset HELPER_BIN to auto-fetch the"
    warn "  pinned prebuilt release (helper-version.txt)."
    return 1
  fi

  auto "Fetching pinned prebuilt helper ($ARCH, tag in helper-version.txt)..."
  if bash "$SCRIPT_DIR/setup/fetch-helper-bin.sh" "$ARCH" \
      "$(dirname "$HELPER_BIN")" >/dev/null; then
    auto "Fetched helper into $HELPER_BIN"
    return 0
  fi

  warn "Could not fetch the pinned prebuilt helper (network? unpublished tag"
  warn "  in helper-version.txt?)."
  if [[ -n ${GITHUB_ACTIONS:-} || -n ${CI:-} ]]; then
    warn "In CI: refusing to continue without the helper."
    exit 1
  fi
  if [[ -x "$HELPER_BIN" ]]; then
    # Only reachable via the stale-stamp path: the old fetch is still in
    # place, and Step 7 stages whatever executable sits at $HELPER_BIN.
    warn "  The previously fetched ${stamp:-unknown} helper is still in place"
    warn "  and WILL be staged -- the package will carry that stale helper,"
    warn "  not the pinned ${pinned:-tag}. Re-run with network access to"
    warn "  refetch."
  else
    warn "  Build will continue and stage everything else; packaging will"
    warn "  refuse a tree without the helper. Set HELPER_BIN to a local build,"
    warn "  or re-run with network access to auto-fetch."
  fi
  return 1
}

#===============================================================================
# Step 0: preflight  [AUTO]
#===============================================================================
step0_preflight() {
  say "Step 0: preflight"
  local ok=1
  if [[ -f "$RESOURCES_SRC/app.asar" ]]; then
    auto "Found app.asar ($(du -h "$RESOURCES_SRC/app.asar" | cut -f1))"
  else
    warn "app.asar not found at $RESOURCES_SRC -- run extraction first (Track 1)."
    ok=0
  fi
  if [[ -f "$WEBPACK_MAIN" ]]; then
    auto "Found unpacked main bundle: $WEBPACK_MAIN"
  else
    warn "Unpacked main bundle not found at $WEBPACK_MAIN"
    ok=0
  fi
  if [[ -f "$RESOURCES_SRC/Release/Wispr Flow Helper.exe" ]]; then
    auto "Found Windows helper (will be replaced by the Linux helper): Release/Wispr Flow Helper.exe"
  fi
  resolve_helper_bin
  if command -v node >/dev/null; then
    auto "node $(node --version)"
  else
    warn "node not found (needed for asar + native rebuild)"
  fi
  if command -v npx >/dev/null; then
    auto "npx present"
  else
    warn "npx not found"
  fi
  [[ $ok == 1 ]] || { warn "Preflight found missing inputs (see above). Continuing for documentation/dry-run."; }
}

#===============================================================================
# Step 1: extraction  [DONE upstream / documented]
#===============================================================================
step1_extract() {
  say "Step 1: extract Squirrel .exe -> nupkg -> Electron payload (already done)"
  manual "This was performed by Track 1; the result lives in $EXTRACT_DIR."
  manual "To redo from a fresh installer (requires 7z):"
  cat <<'DOC'
      7z x "Wispr Flow Setup-v1.5.695.exe" -o./extract            # -> *-full.nupkg
      7z x "./extract/WisprFlow-1.5.695-full.nupkg" -o./extract/nupkg
      # Electron payload is then under extract/nupkg/lib/net45/
      # (resources/app.asar, resources/app.asar.unpacked/, resources/Release/, Wispr Flow.exe, *.pak)
DOC
}

#===============================================================================
# Step 2: stage resources + unpack app.asar  [AUTO]
#===============================================================================
step2_stage_resources() {
  say "Step 2: stage resources and unpack app.asar"
  rm -rf "$WORK_DIR"
  mkdir -p "$STAGE"

  # Copy the non-asar resources (Release/, assets, migrations, etc.) but NOT the
  # raw app.asar yet -- we'll unpack, patch, and repack it.
  auto "Copying resource tree (excluding app.asar, app.asar.unpacked, Windows helper)..."
  if [[ -d "$RESOURCES_SRC" ]]; then
    rsync -a \
      --exclude 'app.asar' \
      --exclude 'app.asar.unpacked' \
      --exclude 'Release/Wispr Flow Helper.exe' \
      "$RESOURCES_SRC/" "$STAGE/" 2>/dev/null \
      || cp -a "$RESOURCES_SRC/." "$STAGE/"   # fallback if rsync absent
  else
    warn "Resources source missing -- skipping copy."
  fi

  # Unpack app.asar so we can patch the main bundle.
  local contents="$WORK_DIR/app.asar.contents"
  if [[ -f "$RESOURCES_SRC/app.asar" ]] && command -v npx >/dev/null; then
    auto "Unpacking app.asar with @electron/asar..."
    if npx --yes @electron/asar extract "$RESOURCES_SRC/app.asar" \
      "$contents"; then
      auto "Unpacked to $contents"
    else
      warn "asar extract failed (network needed for @electron/asar?). See MANUAL note."
    fi
  else
    manual "asar unpack (needs @electron/asar, may require network):"
    echo "      npx @electron/asar extract '$RESOURCES_SRC/app.asar' '$contents'"
    # For a quick local launch you can skip the asar round-trip entirely and use
    # the already-unpacked extract/app/ tree (see Step 8 'run-in-place').
  fi
}

#===============================================================================
# Step 3: patch the main bundle -- add the 'linux' helper-path branch  [AUTO]
#===============================================================================
step3_patch_bundle() {
  say "Step 3: patch main bundle, renderer chrome, and renderer platform flags"
  # Patch whichever main bundle we have. Prefer the unpacked-asar copy if Step 2
  # produced one; otherwise patch the standalone extract/app bundle in place
  # (with a .orig backup, handled by the patch script).
  local target_bundle=""
  if [[ -f "$WORK_DIR/app.asar.contents/.webpack/main/index.js" ]]; then
    target_bundle="$WORK_DIR/app.asar.contents/.webpack/main/index.js"
  elif [[ -f "$WEBPACK_MAIN" ]]; then
    target_bundle="$WEBPACK_MAIN"
    warn "Patching the source bundle $WEBPACK_MAIN in place (a .orig backup is kept)."
  fi

  if [[ -n "$target_bundle" ]]; then
    auto "Running patch-helper-resolver.sh on $target_bundle"
    bash "$SCRIPT_DIR/patches/helper-resolver.sh" "$target_bundle" \
      || warn "Patch failed -- see patch-helper-resolver.sh output above."
    # Gate the macOS-only "must be in /Applications" guard to darwin. On Linux it
    # otherwise shows a blocking "Move Flow to Applications folder" dialog and
    # calls app.quit() on launch. (Validated: 2026-06-04 launch.)
    auto "Running patch-mac-gates.sh on $target_bundle"
    bash "$SCRIPT_DIR/patches/mac-gates.sh" "$target_bundle" \
      || warn "Mac-gate patch failed -- see patch-mac-gates.sh output above."
    # Spread the session env (WAYLAND_DISPLAY/DISPLAY/XDG_RUNTIME_DIR/DBUS_...)
    # into the helper-spawn env object. Without it the Linux helper sees no
    # session and falls to the no-op `stub` injection backend, so text is never
    # injected. (Validated: 2026-06-04 PasteText stub.) See helper-env.sh.
    auto "Running patch-helper-env.sh on $target_bundle"
    bash "$SCRIPT_DIR/patches/helper-env.sh" "$target_bundle" \
      || warn "Helper-env patch failed -- see patch-helper-env.sh output above."
    # Make the hub/settings BrowserWindow frameless on Linux like win32 (it
    # otherwise falls to the Electron default: native frame + visible menu bar).
    # Pairs with linux-renderer-chrome.sh below so the .win32 custom title-bar
    # controls render correctly. See docs/learnings/platform-gates.md.
    auto "Running linux-window-frame.sh on $target_bundle"
    bash "$SCRIPT_DIR/patches/linux-window-frame.sh" "$target_bundle" \
      || warn "Window-frame patch failed -- see linux-window-frame.sh output above."
    # Parse the wispr-flow: deep-link URL out of argv at cold start on Linux too
    # (the parse was win32-only; the warm-start second-instance path already works).
    auto "Running linux-deeplink.sh on $target_bundle"
    bash "$SCRIPT_DIR/patches/linux-deeplink.sh" "$target_bundle" \
      || warn "Deep-link patch failed -- see linux-deeplink.sh output above."
    # Take the Electron single-instance lock at the very top of the bundle,
    # before ANY init runs. The vendor only requests the lock at the end of
    # its ~8.3 MB bundle, so a second launch fully initializes (native .node
    # modules, better-sqlite3, helper IPC) and then quits -- teardown of that
    # half-initialized native state aborts with V8 FATAL napi_throw (9
    # SIGABRT coredumps observed 2026-08-18/26, incl. a 4-in-6s crash loop).
    # With the early guard the second instance exits before executing another
    # byte; the primary still gets `second-instance` (argv handshake happens
    # during the failed lock request) and focuses its hub window. See
    # patches/linux-early-singleton.sh.
    auto "Running linux-early-singleton.sh on $target_bundle"
    bash "$SCRIPT_DIR/patches/linux-early-singleton.sh" "$target_bundle" \
      || warn "Early-singleton patch failed -- see linux-early-singleton.sh output above."

    # Renderer + preload patches live alongside the main bundle under .webpack/.
    local webpack_root="${target_bundle%/main/index.js}"
    # Remap the <html> platform class linux->win32 so Linux adopts the tested
    # .win32 stylesheet (fixes the ~68px phantom window-control inset that shoved
    # the sidebar collapse toggle right and left the controls invisible).
    local hub_renderer="$webpack_root/renderer/hub/index.js"
    if [[ -f "$hub_renderer" ]]; then
      auto "Running linux-renderer-chrome.sh on $hub_renderer"
      bash "$SCRIPT_DIR/patches/linux-renderer-chrome.sh" "$hub_renderer" \
        || warn "Renderer-chrome patch failed -- see linux-renderer-chrome.sh output above."
    else
      warn "Hub renderer bundle not found at $hub_renderer -- skipping chrome patch."
    fi
    # Treat Linux like Windows for renderer platform UI WITHOUT lying to the
    # bridge: leave window.electron.platform.isWindows reporting its real value
    # (false on Linux) and instead widen the single per-renderer isWindows BIND
    # so its module-local consumers (shortcut/PTT defaults, glyph labels, the
    # onboarding Permissions step) take the Windows branch on Linux. Only the
    # renderers that actually read isWindows carry the bind; grep-filter so the
    # ones that don't (calendar_reminder/overlay/vendor) are skipped, not
    # fail-closed. See docs/learnings/platform-gates.md.
    local renderer renderer_count=0
    for renderer in "$webpack_root"/renderer/*/index.js; do
      [[ -f "$renderer" ]] || continue
      grep -qF 'platform?.isWindows' "$renderer" || continue
      auto "Running linux-renderer-treat-as-windows.sh on $renderer"
      bash "$SCRIPT_DIR/patches/linux-renderer-treat-as-windows.sh" "$renderer" \
        || warn "Treat-as-windows patch failed on $renderer -- see output above."
      renderer_count=$((renderer_count + 1))
    done
    if [[ "$renderer_count" -eq 0 ]]; then
      warn "No renderer reads platform.isWindows under $webpack_root/renderer -- skipping treat-as-windows patch."
    fi
  else
    warn "No main bundle available to patch."
  fi
}

# Return the 4-byte ELF magic of $1 as lowercase hex (empty on read failure).
elf_magic() {
  LC_ALL=C od -An -j0 -N4 -tx1 "$1" 2>/dev/null | tr -d ' \n'
}

# Resolve the linux native modules into $NATIVE_MODULES_DIR, in priority order:
#   1. already present + linux-ELF (explicit pre-drop, pre-fetch, or a re-run).
#   2. fetch the pinned prebuilt release asset (fetch-native-bin.sh) -- the
#      normal, supported path; the asset is built on an old-glibc floor and is
#      provenance- + checksum-verified before it lands.
#   3. fetch failed:
#      - in CI: hard-fail. CI MUST ship the pinned prebuilt (correct glibc
#        floor); a local rebuild here would bake the runner's newer glibc.
#      - locally: by default do NOT rebuild -- the prebuilt is the supported
#        artifact. Opt in with WISPR_NATIVE_REBUILD=1 for a from-source rebuild
#        against the HOST glibc (fine for "does it launch here", NOT portable to
#        other distros). The builder + producer workflow live in their own repo
#        (github.com/wispr-flow-linux/native-modules); rebuild-native-modules.sh
#        is vendored here only to back this opt-in.
# The full rationale (V8 14.8 patch, the artifact model) lives in
# docs/learnings/electron42-v8-sqlite.md and docs/decisions.md.
resolve_native_modules() {
  local bsc="$NATIVE_MODULES_DIR/better_sqlite3.node"
  local sql="$NATIVE_MODULES_DIR/node_sqlite3.node"

  # 1. Already present + linux-ELF?
  if [[ -f $bsc && -f $sql \
        && $(elf_magic "$bsc") == '7f454c46' \
        && $(elf_magic "$sql") == '7f454c46' ]]; then
    auto "Using native modules already in $NATIVE_MODULES_DIR"
    return 0
  fi

  # 2. Fetch the pinned prebuilt (the normal path).
  auto "Fetching pinned prebuilt native modules ($ARCH)..."
  if EXPECT_ELECTRON_VERSION="$ELECTRON_VERSION" \
      bash "$SCRIPT_DIR/setup/fetch-native-bin.sh" "$ARCH" \
        "$NATIVE_MODULES_DIR" >/dev/null; then
    auto "Fetched + verified native modules into $NATIVE_MODULES_DIR"
    return 0
  fi
  warn "Could not fetch pinned native modules (network? unpublished tag in"
  warn "  native-modules-version.txt?)."

  # 3a. CI: never rebuild on the runner (would bake the runner's glibc floor).
  if [[ -n ${GITHUB_ACTIONS:-} || -n ${CI:-} ]]; then
    warn "In CI: refusing to rebuild locally. Publish the native-modules"
    warn "  release first (the Build Native Modules workflow in"
    warn "  github.com/wispr-flow-linux/native-modules)."
    exit 1
  fi

  # 3b. Default: the prebuilt IS the supported artifact -- do not rebuild.
  #     Opt in with WISPR_NATIVE_REBUILD=1 for a local (non-portable) build.
  if [[ ${WISPR_NATIVE_REBUILD:-0} != 1 ]]; then
    warn "Not rebuilding locally (the prebuilt is the supported path). To build"
    warn "  a local, non-portable copy from source, re-run with"
    warn "  WISPR_NATIVE_REBUILD=1 (needs node/npm + a C/C++ toolchain)."
    return 1
  fi

  # 3c. Opt-in from-source rebuild (HOST glibc -- dev convenience only).
  warn "WISPR_NATIVE_REBUILD=1 -- building native modules from source (host"
  warn "  glibc; the result is NOT portable to other distros -- local use only)."
  if ELECTRON_VERSION="$ELECTRON_VERSION" \
      bash "$SCRIPT_DIR/rebuild-native-modules.sh" "$ARCH" \
        "$NATIVE_MODULES_DIR"; then
    auto "Local rebuild produced native modules in $NATIVE_MODULES_DIR"
    return 0
  fi
  warn "Local rebuild failed (missing toolchain? see rebuild-native-modules.sh)"
  return 1
}

#===============================================================================
# Step 4: stage linux native node modules for the Electron 42 ABI  [AUTO]
#===============================================================================
step4_native_modules() {
  say "Step 4: stage native modules for Linux Electron $ELECTRON_MAJOR"

  # Populate $NATIVE_MODULES_DIR (pinned prebuilt; opt-in local rebuild only).
  resolve_native_modules

  # Stage whatever unpacked tree exists so paths line up for the .node swap.
  if [[ -d "$RESOURCES_SRC/app.asar.unpacked" ]]; then
    auto "Staging app.asar.unpacked/ skeleton (Windows .node placeholders)..."
    mkdir -p "$STAGE/app.asar.unpacked"
    cp -a "$RESOURCES_SRC/app.asar.unpacked/." "$STAGE/app.asar.unpacked/" 2>/dev/null || true
  fi

  # AUTO: swap the Windows PE .node for the linux-$ARCH rebuilds. We replace them
  # in BOTH the asar contents (the copy that gets packed -- and the copy Electron
  # loads from app.asar.unpacked once Step 7 unpacks it) AND the staged unpacked
  # tree. Without this the repacked asar ships Windows .node that dlopen-fail at
  # startup with "invalid ELF header": the node_sqlite3 / better_sqlite3 loaders
  # run during main-process init, before any window opens.
  local nm_rel=".webpack/main/native_modules/build/Release"
  local contents="$WORK_DIR/app.asar.contents"
  if [[ -f "$NATIVE_MODULES_DIR/better_sqlite3.node" \
        && -f "$NATIVE_MODULES_DIR/node_sqlite3.node" ]]; then
    local mod
    for mod in better_sqlite3 node_sqlite3; do
      if [[ -d "$contents" ]]; then
        mkdir -p "$contents/$nm_rel"
        cp "$NATIVE_MODULES_DIR/$mod.node" "$contents/$nm_rel/$mod.node"
      fi
      mkdir -p "$STAGE/app.asar.unpacked/$nm_rel"
      cp "$NATIVE_MODULES_DIR/$mod.node" \
         "$STAGE/app.asar.unpacked/$nm_rel/$mod.node"
      auto "Swapped $mod.node -> linux build ($NATIVE_MODULES_DIR)"
    done
  else
    warn "Linux native modules not found in $NATIVE_MODULES_DIR"
    warn "  (need better_sqlite3.node + node_sqlite3.node) -- repacked asar would"
    warn "  ship WINDOWS .node and crash at startup ('invalid ELF header')."
    warn "  Rebuild them (recipe above), set NATIVE_MODULES_DIR, or drop them there."
  fi
}

#===============================================================================
# Step 5: drop / stub Windows-only modules (win-ca / crypt32)  [AUTO]
#===============================================================================
step5_drop_winca() {
  say "Step 5: drop Windows-only win-ca / crypt32 native bindings"
  # crypt32-*.node are the win-ca Windows cert-store bindings. On Linux the app
  # uses the system CA bundle, so these are non-essential. Remove the Windows
  # binaries from the staged unpacked tree; the two .webpack/main root *.node
  # are just webpack shims pointing at crypt32 -- removing the real .node makes
  # win-ca a no-op (it try/catches its native load).
  local nm="$STAGE/app.asar.unpacked/.webpack/main/native_modules/lib"
  if [[ -d "$nm" ]]; then
    for f in crypt32-ia32.node crypt32-x64.node; do
      if [[ -f "$nm/$f" ]]; then
        rm -f "$nm/$f" && auto "Removed $f"
      fi
    done
  else
    warn "crypt32 native_modules/lib dir not staged (Step 2/4 may have been skipped)."
  fi
  manual "If win-ca's require() of the native binding throws (instead of being"
  manual "caught), drop a JS stub at node_modules/win-ca exporting a no-op inject()."
  manual "The Jabra Linux ELF under app.asar.unpacked .../jabra/linux/ is already"
  manual "cross-platform -- KEEP it (no action)."
}

#===============================================================================
# Step 6: stage Linux Electron 42 runtime  [MANUAL]
#===============================================================================
step6_stage_electron() {
  say "Step 6: stage Linux Electron $ELECTRON_VERSION runtime"
  manual "The extracted app ships the WINDOWS Electron runtime ('Wispr Flow.exe',"
  manual "*.dll, *.pak). For Linux we discard those and stage a Linux Electron $ELECTRON_MAJOR:"
  cat <<DOC
      # Option A -- via npm (needs network):
      npm install --no-save electron@$ELECTRON_VERSION
      #   -> node_modules/electron/dist/electron  (the Linux binary)
      # Option B -- direct tarball (needs network):
      #   https://github.com/electron/electron/releases/download/v$ELECTRON_VERSION/electron-v$ELECTRON_VERSION-linux-$ARCH.zip
      # Then the run/package layout is:
      #   <electron-dist>/electron                 # the ELF launcher
      #   <electron-dist>/resources/app.asar        # our patched, repacked asar
      #   <electron-dist>/resources/app.asar.unpacked/  # rebuilt native modules
      #   <electron-dist>/resources/Release/wispr-flow-linux-helper
DOC
  warn "BLOCKER CHECK: Electron $ELECTRON_VERSION must publish a linux-$ARCH build."
  warn "  Electron $ELECTRON_MAJOR is a normal upstream release with linux-x64/arm64"
  warn "  artifacts, so this is expected to be available -- but it is the one hard"
  warn "  network dependency. Verify the exact patch version is downloadable."
  warn "MANDATORY: rename the Electron launcher binary from 'electron' to a"
  warn "  non-'electron' name (e.g. 'wispr-flow'). Electron sets app.isPackaged=false"
  warn "  when the executable is named 'electron', which makes the app resolve DEV"
  warn "  resource paths (e.g. resourcesPath/src/main/db/migrations) instead of the"
  warn "  packaged ones (resourcesPath/migrations). With the binary named 'electron'"
  warn "  the DB schema migrations silently load 0 files -> 'no such table' on every"
  warn "  query. Renaming to 'wispr-flow' flips isPackaged=true and all 92 migrations"
  warn "  run. (Validated 2026-06-04.) The helper-path patch uses process.resourcesPath"
  warn "  directly, so the helper works regardless, but migrations need isPackaged=true."
  cat <<DOC
      # After staging the Linux Electron dist:
      mv <electron-dist>/electron <electron-dist>/wispr-flow
      # launch:  <electron-dist>/wispr-flow --no-sandbox
      # and stage the FULL resources tree next to app.asar:
      #   resources/{app.asar, app.asar.unpacked, Release/, migrations/, assets/, wispr-flow.mcpb}
      # (migrations/ + assets/ are read from resourcesPath at runtime; do not omit them.)
DOC
}

#===============================================================================
# Step 7: copy in the Rust helper + repack app.asar  [AUTO where possible]
#===============================================================================
step7_helper_and_repack() {
  say "Step 7: stage Linux helper + repack app.asar"

  # 7a. Place the Linux helper where the patched resolver looks for it:
  #     <resourcesPath>/Release/wispr-flow-linux-helper  (exec bit REQUIRED --
  #     the app does NOT chmod it; spawn() fails if it's not executable).
  mkdir -p "$STAGE/Release"
  if [[ -x "$HELPER_BIN" ]]; then
    cp "$HELPER_BIN" "$STAGE/Release/wispr-flow-linux-helper"
    chmod 0755 "$STAGE/Release/wispr-flow-linux-helper"
    auto "Staged helper at Release/wispr-flow-linux-helper (mode 0755)"
  else
    warn "Helper binary missing -- placing a placeholder note. Build & copy:"
    echo "      cp '$HELPER_BIN' '$STAGE/Release/wispr-flow-linux-helper' && chmod +x ..."
  fi
  # Remove the Windows helper from the staged tree if it slipped in.
  rm -f "$STAGE/Release/Wispr Flow Helper.exe" 2>/dev/null || true

  # 7a.5 Guard: never ship a Windows PE (or wrong-arch) .node -- it would
  #      dlopen-fail at startup ("invalid ELF header"). The authoritative load
  #      path is the staged app.asar.unpacked tree (Electron loads the addons
  #      from there); app.asar.contents is also checked when a copy was packed.
  #      Step 4 swaps in the linux build; this fails LOUD if that did not happen
  #      -- including the silent case where the dir was empty and the original
  #      Windows .node (or no .node) remained -- instead of shipping a crash.
  local nm_rel=".webpack/main/native_modules/build/Release"
  local want_machine
  case "$ARCH" in
    x64)   want_machine='3e00' ;;   # ELF e_machine EM_X86_64
    arm64) want_machine='b700' ;;   # ELF e_machine EM_AARCH64
    *)     want_machine='' ;;
  esac
  local mod nodef magic machine
  # The unpacked tree is what ships + dlopens: both .node MUST be present and be
  # a linux ELF of the target arch. Only enforced once the tree is staged (an
  # offline dry-run that never staged resources has nothing to ship).
  if [[ -d "$STAGE/app.asar.unpacked" ]]; then
    for mod in better_sqlite3 node_sqlite3; do
      nodef="$STAGE/app.asar.unpacked/$nm_rel/$mod.node"
      if [[ ! -f "$nodef" ]]; then
        warn "$mod.node missing from the staged app.asar.unpacked tree."
        warn "  Step 4 did not stage a linux native module. Refusing to ship a"
        warn "  package without it (it would crash at startup)."
        warn "  Provide it via NATIVE_MODULES_DIR / native-modules-version.txt."
        exit 1
      fi
      magic=$(elf_magic "$nodef")
      if [[ "$magic" != '7f454c46' ]]; then
        warn "$mod.node (app.asar.unpacked) is NOT linux ELF (magic=$magic)."
        warn "  Refusing to ship a Windows .node that crashes at startup."
        exit 1
      fi
      machine=$(LC_ALL=C od -An -j18 -N2 -tx1 "$nodef" 2>/dev/null \
        | tr -d ' \n')
      if [[ -n $want_machine && $machine != "$want_machine" ]]; then
        warn "$mod.node (app.asar.unpacked) is the wrong arch (e_machine="
        warn "  $machine, want $want_machine for $ARCH). Refusing to ship."
        exit 1
      fi
    done
  fi
  # Defense in depth: if a .node copy was also packed into app.asar.contents,
  # it must be a linux ELF too (absence there is fine -- .node are unpacked).
  for mod in better_sqlite3 node_sqlite3; do
    nodef="$WORK_DIR/app.asar.contents/$nm_rel/$mod.node"
    [[ -f "$nodef" ]] || continue
    magic=$(elf_magic "$nodef")
    if [[ "$magic" != '7f454c46' ]]; then
      warn "$mod.node in app.asar.contents is NOT linux ELF (magic=$magic)."
      warn "  Refusing to repack a Windows .node that crashes at startup."
      exit 1
    fi
  done

  # 7b. Repack the patched contents into app.asar with native modules unpacked.
  #     Unpack glob is '*.node' (matches .node at any depth); '**/*.node' matches
  #     NOTHING in @electron/asar and silently leaves the .node packed in-archive.
  local contents="$WORK_DIR/app.asar.contents"
  if [[ -d "$contents" ]] && command -v npx >/dev/null; then
    auto "Repacking app.asar (with --unpack '*.node')..."
    if npx --yes @electron/asar pack "$contents" "$STAGE/app.asar" \
      --unpack '*.node'; then
      auto "Wrote $STAGE/app.asar"
    else
      warn "asar pack failed (network for @electron/asar?). See MANUAL note."
    fi

    # 7c. Static-verify the SHIPPED asar carries the Linux patch markers, so a
    #     half-patched or unpatched asar fails the build here instead of
    #     shipping silently. Hard-fails (CI greps this script's exit code).
    if [[ -f "$STAGE/app.asar" ]]; then
      auto "Verifying Linux patch markers in repacked app.asar..."
      if ! bash "$SCRIPT_DIR/verify-patches.sh" "$STAGE/app.asar"; then
        warn "Repacked app.asar is missing Linux patch markers (see above) -- failing."
        exit 1
      fi
    fi
  else
    manual "Repack app.asar (needs @electron/asar):"
    echo "      npx @electron/asar pack '$contents' '$STAGE/app.asar' --unpack '*.node'"
  fi
}

#===============================================================================
# Step 8: produce installable package(s)  [MANUAL]
#===============================================================================
step8_package() {
  say "Step 8: package (.deb / .rpm / .AppImage) or run-in-place"
  manual "electron-forge already declares maker-deb + maker-rpm (package.json). With a"
  manual "Linux Electron staged and native modules rebuilt, you can either:"
  cat <<DOC
      # A) electron-forge makers (from a tree with devDeps installed):
      npx electron-forge make --platform linux --arch $ARCH
      # B) Hand-roll like claude-desktop-debian's scripts/packaging/{deb,rpm,appimage}.sh:
      #    lay out <electron-dist> + resources/ under /usr/lib/wispr-flow, add a
      #    /usr/bin/wispr-flow launcher and a .desktop file, then dpkg-deb / rpmbuild
      #    / appimagetool.
DOC
  manual "RUN-IN-PLACE smoke test (fastest path to 'does it launch?'):"
  cat <<DOC
      # Using the already-unpacked extract/app tree (no asar round-trip):
      #   1. patch:   bash scripts/patches/helper-resolver.sh \\
      #                    extract/app/.webpack/main/index.js
      #   2. helper:  mkdir -p <resourcesPath>/Release && \\
      #               cp "$HELPER_BIN" \\
      #                  <resourcesPath>/Release/ && chmod +x <...>
      #               ("$HELPER_BIN" = a prebuilt helper from
      #                github.com/wispr-flow-linux/helper releases, pinned tag in
      #                helper-version.txt, or your local checkout's
      #                target/release/wispr-flow-linux-helper)
      #   3. electron <app-dir>   (Linux Electron 42, --no-sandbox if needed)
      # NOTE: process.resourcesPath differs between 'electron <dir>' (dev) and a
      # packaged build; for the dev run, point the resolver at the app dir or use
      # a packaged layout. See README.md.
DOC
}

#===============================================================================
main() {
  step0_preflight
  step1_extract
  step2_stage_resources
  step3_patch_bundle
  step4_native_modules
  step5_drop_winca
  step6_stage_electron
  step7_helper_and_repack
  step8_package

  say "Done (Phase-0 staging)."
  echo "  Staged tree: $STAGE"
  echo "  AUTO steps:   bundle patch, resource staging, win-ca drop, helper staging,"
  echo "                app.asar unpack/repack (when @electron/asar is fetchable)."
  echo "  MANUAL steps: native-module rebuild (sqlite ABI), Linux Electron download,"
  echo "                final .deb/.rpm/.AppImage packaging (all network/toolchain)."
}

main "$@"
