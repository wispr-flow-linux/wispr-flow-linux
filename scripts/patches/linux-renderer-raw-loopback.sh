#!/usr/bin/env bash
# linux-renderer-raw-loopback.sh -- request Notetaker's system audio with
# echo cancellation, noise suppression and auto gain off on Linux (#61), as
# upstream already does for the mic. With Chromium's defaults the echo
# canceller removes the speaker sound the loopback captures.
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin 'WISPR_LINUX_RAW_LOOPBACK' "${1:-}" \
	'extract/app/.webpack/renderer/hub/index.js'

python3 - "$BUNDLE" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
old = 'getDisplayMedia({audio:!0,video:!1})'
new = ('getDisplayMedia({audio:/*' + marker + '*/"linux"===window.electron'
       '.platform.os?{echoCancellation:!1,noiseSuppression:!1,'
       'autoGainControl:!1}:!0,video:!1})')
if old not in src:
    sys.exit('ERROR: found 0 ' + old + ' sites.')
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(
    src.replace(old, new))
PY

patch_verify_marker
patch_finish "raw system-audio request on Linux in $BUNDLE"
