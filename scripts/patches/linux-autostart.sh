#!/usr/bin/env bash
#===============================================================================
# patch-linux-autostart.sh -- make "Open at login" work on Linux and start the
# app hidden in the tray when launched at login (.webpack/main/index.js).
#
# Wispr Flow toggles login launch via app.setLoginItemSettings() and skips
# showing the Hub at launch when app.getLoginItemSettings().wasOpenedAtLogin
# is true. On Linux both are no-ops in Electron: no autostart entry is written
# and wasOpenedAtLogin is always false, so the setting silently does nothing.
#
# This prepends a Linux-only shim that implements both with a standard XDG
# autostart entry:
#   setLoginItemSettings({openAtLogin:true})  -> write
#     $XDG_CONFIG_HOME/autostart/wispr-flow.desktop  (Exec=... --hidden)
#   setLoginItemSettings({openAtLogin:false}) -> remove it
#   getLoginItemSettings() -> {openAtLogin: <entry exists>,
#                              wasOpenedAtLogin: <launched with --hidden>}
# A login launch therefore starts in the tray without opening the Hub window.
#
# Usage: patch-linux-autostart.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -uo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
	echo "usage: $0 <.webpack/main/index.js>" >&2
	exit 2
fi

MARKER='WISPR_LINUX_AUTOSTART'
if grep -qF "$MARKER" "$BUNDLE"; then
	echo "Already patched ($MARKER present) - nothing to do."
	exit 0
fi

cp -p "$BUNDLE" "$BUNDLE.autostart.orig" || exit 1

python3 - "$BUNDLE" "$MARKER" <<'PY' || exit 1
import io, sys
path, marker = sys.argv[1], sys.argv[2]
src = io.open(path, encoding="utf-8", errors="surrogateescape").read()
shim = (
 '/*' + marker + '*/if("linux"===process.platform){try{'
 'const E=require("electron"),F=require("fs"),P=require("path"),O=require("os"),'
 'A=P.join(process.env.XDG_CONFIG_HOME||P.join(O.homedir(),".config"),'
 '"autostart","wispr-flow.desktop"),'
 'X=process.env.APPIMAGE?JSON.stringify(process.env.APPIMAGE):"wispr-flow";'
 'E.app.setLoginItemSettings=o=>{try{if(o&&o.openAtLogin){'
 'F.mkdirSync(P.dirname(A),{recursive:!0});F.writeFileSync(A,'
 '"[Desktop Entry]\\nType=Application\\nName=Wispr Flow\\nExec="+X+'
 '" --hidden\\nIcon=wispr-flow\\nTerminal=false\\n'
 'X-GNOME-Autostart-enabled=true\\n")}else F.rmSync(A,{force:!0})}catch(e){}};'
 'E.app.getLoginItemSettings=()=>({openAtLogin:F.existsSync(A),'
 'wasOpenedAtLogin:process.argv.includes("--hidden")})'
 '}catch(e){}}\n'
)
nl = src.index('\n')
if not src.startswith('/*'):
	nl = -1
src = src[:nl + 1] + shim + src[nl + 1:]
io.open(path, 'w', encoding="utf-8", errors="surrogateescape").write(src)
print("Patched: Linux login-item shim injected.")
PY

if ! grep -qF "$MARKER" "$BUNDLE" || ! node --check "$BUNDLE"; then
	echo "ERROR: verification failed; restoring backup." >&2
	cp -p "$BUNDLE.autostart.orig" "$BUNDLE"
	exit 1
fi
echo "OK: Linux autostart shim applied to $BUNDLE"
