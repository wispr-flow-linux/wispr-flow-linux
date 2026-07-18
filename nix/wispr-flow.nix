{
  lib,
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  electron_42,
  p7zip,
  icoutils,
  imagemagick,
  nodejs,
  asar,
  makeDesktopItem,
  python3,
  bash,
  rsync,
  # Path to the Wispr Flow installer .exe you obtained yourself. This build never
  # fetches the proprietary app (see the Source block below for how to supply it).
  installerExe ? null,
}:
let
  pname = "wispr-flow";
  version = "1.6.7";

  #============================================================================
  # Source: the user-supplied Wispr Flow Windows installer (a Squirrel .exe).
  #
  # This build NEVER fetches the proprietary app — you provide the installer you
  # obtained yourself, mirroring `build.sh --exe`. Supply it either way:
  #
  #   * impure env var (the flake default):
  #       WISPR_FLOW_EXE="/abs/path/Wispr Flow Setup-v1.5.619.exe" \
  #         nix build .#wispr-flow-fhs --impure
  #
  #   * package override (overlay / non-flake callers):
  #       wispr-flow.override { installerExe = /abs/path/to/Setup.exe; }
  #
  # Wispr ships only a win32/x64 installer (no win32/arm64 variant is known), so
  # the aarch64 build reuses the same x64 .exe — the payload is the
  # cross-platform Electron app, and the native Rust helper is built per-arch by
  # rustPlatform below, so one .exe drives both outputs.
  #============================================================================
  installerEnv = builtins.getEnv "WISPR_FLOW_EXE";
  resolvedExe =
    if installerExe != null then installerExe
    else if installerEnv != "" then /. + installerEnv
    else throw ''
      wispr-flow: no installer supplied. This build never downloads the
      proprietary Wispr Flow app — provide the Setup .exe you obtained yourself:

        WISPR_FLOW_EXE="/abs/path/Wispr Flow Setup-v${version}.exe" \
          nix build .#wispr-flow-fhs --impure

      or override the package:
        wispr-flow.override { installerExe = /abs/path/to/Setup.exe; }
    '';

  # Copy the supplied .exe into the store under a fixed, space-free name so the
  # derivation hash is independent of where the file lived on disk.
  src = builtins.path {
    path = resolvedExe;
    name = "wispr-flow-setup-${version}.exe";
  };

  # Repo root, used to reach scripts/ from the build.
  # build-reference / build-linux / extract / result are excluded so a dirty
  # working tree does not bust the derivation hash.
  sourceRoot = lib.cleanSourceWith {
    src = ./..;
    filter = path: type:
      let rel = lib.removePrefix (toString ./.. + "/") path;
      in !(lib.hasPrefix "build-linux" rel)
      && !(lib.hasPrefix "extract" rel)
      && !(lib.hasPrefix "logs" rel)
      && !(lib.hasPrefix "tools" rel)
      && !(lib.hasPrefix "result" rel);
  };

  #============================================================================
  # The clean-room Linux helper, built from its own repo
  # (github.com/wispr-flow-linux/helper) via Cargo.
  #
  # The crate has a committed Cargo.lock, so cargoLock.lockFile gives a fully
  # reproducible, vendored build off the fetched source. Produces
  # `wispr-flow-linux-helper`, which the install phase stages at
  # resources/Release/wispr-flow-linux-helper (mode 0755) where the patched
  # main bundle's 'linux' branch looks for it.
  #============================================================================
# Pinned FOD hash for the helper source fetch (v0.1.0). If the pin ever
  # goes stale (e.g. the tag is moved), `nix build` will fail and print the
  # correct `hash = ...` to paste in here.
  helperSrc = fetchFromGitHub {
    owner = "wispr-flow-linux";
    repo = "helper";
    rev = "v0.1.0";
    hash = "sha256-Teer9aJ7naKhZ3BOLSpOZSb48A7Ngsaq65ZJ3I14Bfc=";
  };

  linux-helper = rustPlatform.buildRustPackage {
    pname = "wispr-flow-linux-helper";
    version = "0.1.0";

    src = helperSrc;

    cargoLock.lockFile = "${helperSrc}/Cargo.lock";

    # The crate speaks XCB/Wayland/uinput wire protocols directly (pure-Rust:
    # x11rb, wayland-client, zbus, libc) — no C library dev headers needed, so
    # no buildInputs. The Python helper scripts in the crate dir are test
    # tooling, not part of the cargo build.
    doCheck = false;

    meta = with lib; {
      description = "Clean-room Linux helper for Wispr Flow (X11/Wayland text injection, window + selection)";
      license = with licenses; [ mit asl20 ];
      platforms = platforms.linux;
      mainProgram = "wispr-flow-linux-helper";
    };
  };

  # The unwrapped electron derivation holds the real ELF + Chromium resources
  # (.pak files, locales/, etc.). We copy the ELF into our own tree so that
  # /proc/self/exe — and therefore process.resourcesPath — resolves to a dir
  # that contains the app's resources, not stock electron's.
  electronUnwrapped = electron_42.passthru.unwrapped or electron_42;
  electronDir = "${electronUnwrapped}/libexec/electron";

  desktopItem = makeDesktopItem {
    name = "wispr-flow";
    exec = "wispr-flow %U";
    icon = "wispr-flow";
    type = "Application";
    terminal = false;
    desktopName = "Wispr Flow";
    genericName = "Voice Dictation";
    comment = "Voice dictation that types into your focused app";
    startupWMClass = "Wispr Flow";
    categories = [ "Utility" "AudioVideo" "Audio" ];
    keywords = [ "voice" "dictation" "speech" "transcription" ];
  };
in
stdenvNoCC.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    p7zip
    nodejs
    asar
    icoutils
    imagemagick
    bash
    python3
    rsync
  ];

  # The installer is a Squirrel .exe, not a standard archive — unpack manually.
  dontUnpack = true;

  #==========================================================================
  # Build phase.
  #
  # COUPLING DECISION: this does NOT call `build.sh --build nix`. The Wispr
  # build.sh delegates staging to scripts/build-linux.sh, whose Electron
  # download, @electron/asar fetch, and better-sqlite3 native ABI rebuild are
  # network/toolchain steps that cannot run inside the Nix sandbox. Instead we
  # replicate the deterministic extract -> patch -> repack steps here using
  # nixpkgs tooling (p7zip, asar, nodejs) and the committed patch scripts under
  # scripts/patches/. The reference flake's `build.sh --build nix` works only
  # because its build.sh stages everything inline; ours doesn't, so calling the
  # staging scripts' deterministic parts directly is the cleaner path.
  #
  # NATIVE-MODULE NOTE: the shipped better-sqlite3-multiple-ciphers + sqlite3
  # *.node are Windows PE binaries and must be rebuilt for the Linux Electron 42
  # ABI (see scripts/build-linux.sh step 4 and the V8 14.8 patch under
  # scripts/patches/). That rebuild needs npm deps + a toolchain and is not
  # hermetic here, so it is NOT performed in this derivation: the app launches
  # but DB-backed features stay broken until rebuilt natives are supplied. This
  # matches the deb/rpm makers, which also consume a pre-staged tree. A future
  # iteration can add a buildRustPackage-style fixed-output native build.
  #==========================================================================
  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR

    #-- 1. Extract the Squirrel .exe -> *-full.nupkg -> Electron payload -----
    7z x -y "$src" -oinstaller >/dev/null
    nupkg=$(find installer -iname '*-full.nupkg' | head -1)
    [[ -n "$nupkg" ]] || { echo "no *-full.nupkg in installer" >&2; exit 1; }
    7z x -y "$nupkg" -onupkg >/dev/null

    net45=nupkg/lib/net45
    resources_src="$net45/resources"
    [[ -f "$resources_src/app.asar" ]] || { echo "app.asar not found at $resources_src" >&2; exit 1; }

    #-- 2. Stage the resource tree (everything except the asar + Windows helper)
    mkdir -p stage
    rsync -a \
      --exclude 'app.asar' \
      --exclude 'app.asar.unpacked' \
      --exclude 'Release/Wispr Flow Helper.exe' \
      "$resources_src/" stage/

    #-- 3. Unpack app.asar, patch the main bundle, repack ---------------------
    asar extract "$resources_src/app.asar" asar-contents
    main_bundle=asar-contents/.webpack/main/index.js
    [[ -f "$main_bundle" ]] || { echo "main bundle not found at $main_bundle" >&2; exit 1; }

    # Add the 'linux' helper-path branch + gate the macOS Applications guard.
    bash ${sourceRoot}/scripts/patches/helper-resolver.sh "$main_bundle"
    bash ${sourceRoot}/scripts/patches/mac-gates.sh "$main_bundle"

    # Stage the unpacked native-module tree (Windows *.node kept as-is — see the
    # NATIVE-MODULE NOTE above) and drop the win-ca crypt32 Windows bindings.
    if [[ -d "$resources_src/app.asar.unpacked" ]]; then
      mkdir -p stage/app.asar.unpacked
      cp -a "$resources_src/app.asar.unpacked/." stage/app.asar.unpacked/
      rm -f stage/app.asar.unpacked/.webpack/main/native_modules/lib/crypt32-*.node || true
    fi

    # Repack with native modules left unpacked, then verify the Linux markers.
    asar pack asar-contents stage/app.asar --unpack '**/*.node'
    bash ${sourceRoot}/scripts/verify-patches.sh stage/app.asar

    #-- 4. Stage the clean-room Linux helper (mode 0755 — the app does not chmod)
    mkdir -p stage/Release
    cp ${linux-helper}/bin/wispr-flow-linux-helper stage/Release/wispr-flow-linux-helper
    chmod 0755 stage/Release/wispr-flow-linux-helper
    rm -f "stage/Release/Wispr Flow Helper.exe" || true

    runHook postBuild
  '';

  #==========================================================================
  # Install phase — reproduces the FHS layout the deb/rpm makers build, under
  # $out, with the Electron ELF copied (not symlinked) into the store tree so
  # /proc/self/exe resolves here.
  #==========================================================================
  installPhase = ''
    runHook preInstall

    #-- Custom Electron tree with app resources co-located -------------------
    # (Same rationale as the reference: Chromium derives resourcesPath from
    # /proc/self/exe, so the binary must live next to the app's resources.)
    electron_tree=$out/lib/wispr-flow/electron
    mkdir -p $electron_tree/resources

    # Copy the ELF as a REAL file named 'wispr-flow' (not 'electron') — both for
    # /proc/self/exe and because Electron sets app.isPackaged=false when the
    # binary is named 'electron', which breaks the 92 DB migrations.
    cp ${electronDir}/electron $electron_tree/wispr-flow
    chmod +x $electron_tree/wispr-flow

    # Symlink everything else from electron-unwrapped.
    for item in ${electronDir}/*; do
      name=$(basename "$item")
      [[ "$name" = "electron" ]] && continue
      [[ "$name" = "resources" ]] && continue
      ln -s "$item" "$electron_tree/$name"
    done

    # Start resources/ from Electron's own (default_app.asar, etc.).
    for item in ${electronDir}/resources/*; do
      ln -s "$item" "$electron_tree/resources/$(basename "$item")"
    done

    # Merge the staged Wispr resource tree (app.asar, app.asar.unpacked,
    # Release/, migrations/, assets/, *.mcpb, ...) into resources/.
    cp -r stage/* $electron_tree/resources/

    # Convenience symlink used by the launcher.
    ln -s $electron_tree/resources $out/lib/wispr-flow/resources

    #-- Electron wrapper: keep stock electron's GTK/GIO/GDK env, exec our ELF -
    head -n -1 ${electron_42}/bin/electron > $electron_tree/electron-wrapper
    echo "exec \"$electron_tree/wispr-flow\" \"\$@\"" >> $electron_tree/electron-wrapper
    chmod +x $electron_tree/electron-wrapper
    substituteInPlace $electron_tree/electron-wrapper \
      --replace-quiet "${electron_42}/libexec/electron/chrome-sandbox" \
        "$electron_tree/chrome-sandbox"

    #-- Icons ----------------------------------------------------------------
    icon_png=$electron_tree/resources/assets/logos/wispr-logo.png
    if [[ -f "$icon_png" ]]; then
      install -Dm644 "$icon_png" \
        $out/share/icons/hicolor/256x256/apps/wispr-flow.png
    fi
    icon_svg=$electron_tree/resources/assets/logos/wispr-flow.svg
    if [[ -f "$icon_svg" ]]; then
      install -Dm644 "$icon_svg" \
        $out/share/icons/hicolor/scalable/apps/wispr-flow.svg
    fi

    #-- Shared launcher library + doctor (launcher-common.sh sources doctor.sh
    #   from the same dir, so both must be co-located) ------------------------
    install -Dm755 ${sourceRoot}/scripts/launcher-common.sh \
      $out/lib/wispr-flow/launcher-common.sh
    install -Dm755 ${sourceRoot}/scripts/doctor.sh \
      $out/lib/wispr-flow/doctor.sh

    #-- .desktop file --------------------------------------------------------
    mkdir -p $out/share/applications
    install -Dm644 ${desktopItem}/share/applications/* $out/share/applications/

    #-- input access udev rule ------------------------------------------------
    # A user package cannot install into /etc/udev or /usr/lib/udev at runtime.
    # We emit the rule to $out/lib/udev/rules.d/; on NixOS wire it up with:
    #
    #   services.udev.packages = [ pkgs.wispr-flow ];   # or the fhs wrapper
    #
    # which symlinks it into the active rules set. Without it, keystroke
    # injection (/dev/uinput) and push-to-talk (/dev/input read) need the user
    # in the 'input' group + a matching rule. Keep in sync with deb.sh, rpm.sh,
    # and the launcher's _wispr_udev_rules_content (scripts/launcher-common.sh).
    mkdir -p $out/lib/udev/rules.d
    cat > $out/lib/udev/rules.d/70-wispr-flow-uinput.rules <<'UDEV'
# Wispr Flow: grant the active-session user the input access the helper needs.
#  - write /dev/uinput        — keystroke injection (PasteText/SimulateKeyPress)
#  - read  /dev/input/event*  — global key monitor for push-to-talk and the
#                               in-app shortcut recorder
# TAG+="uaccess" scopes the grant to the active logind session; the input group
# + 0660 is the cross-distro fallback (then `usermod -aG input $USER` + re-login).
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
SUBSYSTEM=="input", KERNEL=="event*", TAG+="uaccess", GROUP="input", MODE="0660"
UDEV

    #-- Launcher /bin/wispr-flow ---------------------------------------------
    mkdir -p $out/bin
    cat > $out/bin/wispr-flow <<'LAUNCHER'
#!/usr/bin/env bash
# Wispr Flow launcher for NixOS. Sources the shared launcher library, runs the
# doctor on --doctor, sets up logging + Electron env, then exec's our custom
# Electron wrapper (which sets GTK/GIO env then runs the merged ELF).

set -uo pipefail

electron_exec="ELECTRON_PLACEHOLDER"
helper_bin="RESOURCES_PLACEHOLDER/Release/wispr-flow-linux-helper"

# shellcheck source=/dev/null
source "LAUNCHER_LIB_PLACEHOLDER"

# Handle --doctor before anything else.
if [[ "''${1:-}" == '--doctor' ]]; then
	run_doctor "$helper_bin"
	exit $?
fi

setup_logging || exit 1
setup_electron_env
cleanup_stale_lock

log_message '--- Wispr Flow Launcher Start (NixOS) ---'
log_message "Timestamp: $(date)"
log_message "Arguments: $*"
log_session_env

if ! check_display; then
	log_message 'No display detected (TTY session)'
	echo 'Error: Wispr Flow requires a graphical desktop environment.' >&2
	echo 'Run from within a Wayland or X11 session, not a TTY.' >&2
	echo 'Tip: run "wispr-flow --doctor" to diagnose your setup.' >&2
	exit 1
fi

detect_display_backend
build_electron_args 'nix'

log_message "Executing: $electron_exec ''${electron_args[*]} $*"
exec "$electron_exec" "''${electron_args[@]}" "$@" >> "$log_file" 2>&1
LAUNCHER
    substituteInPlace $out/bin/wispr-flow \
      --replace-fail "ELECTRON_PLACEHOLDER" "$electron_tree/electron-wrapper" \
      --replace-fail "RESOURCES_PLACEHOLDER" "$electron_tree/resources" \
      --replace-fail "LAUNCHER_LIB_PLACEHOLDER" "$out/lib/wispr-flow/launcher-common.sh"
    chmod +x $out/bin/wispr-flow

    runHook postInstall
  '';

  meta = with lib; {
    description = "Wispr Flow voice dictation for Linux (unofficial build)";
    homepage = "https://wisprflow.ai";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "wispr-flow";
  };
}
