{
  buildFHSEnv,
  wispr-flow,
  glibc,
  wl-clipboard,
  xclip,
  xsel,
}:
#==============================================================================
# Glibc FHS wrapper around the Wispr Flow derivation.
#
# Electron expects a standard glibc dynamic loader (/lib64/ld-linux-*) and the
# usual shared libraries at FHS paths; on NixOS those do not exist, so we run
# the app inside a buildFHSEnv sandbox that provides them. This is the
# recommended default output (packages.default).
#
# Unlike the claude-desktop reference (which also pulls in docker/nodejs/uv for
# MCP servers), Wispr Flow has no MCP/cowork runtime — its only out-of-process
# native dependency is the bundled Rust helper plus clipboard tools:
#   - wl-clipboard : Wayland selection/clipboard (hard dependency, matches the
#                    deb Depends / rpm Requires).
#   - xclip / xsel : X11 clipboard fallback (matches the deb/rpm Recommends).
#==============================================================================
buildFHSEnv {
  name = "wispr-flow";

  targetPkgs = pkgs: [
    wispr-flow
    glibc
    wl-clipboard
    xclip
    xsel
  ];

  runScript = "${wispr-flow}/bin/wispr-flow";

  extraInstallCommands = ''
    # Surface the desktop file + icons so the FHS wrapper is a drop-in app.
    mkdir -p $out/share/applications
    cp ${wispr-flow}/share/applications/* $out/share/applications/

    mkdir -p $out/share/icons
    cp -r ${wispr-flow}/share/icons/* $out/share/icons/

    # Re-export the uinput udev rule so `services.udev.packages = [ fhs ];`
    # works against the wrapper too.
    mkdir -p $out/lib/udev/rules.d
    cp ${wispr-flow}/lib/udev/rules.d/* $out/lib/udev/rules.d/
  '';

  meta = wispr-flow.meta // {
    description = "Wispr Flow voice dictation for Linux (FHS environment, unofficial)";
    mainProgram = "wispr-flow";
  };
}
