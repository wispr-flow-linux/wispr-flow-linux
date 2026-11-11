#!/usr/bin/env bash
# linux-meeting-loopback.sh -- let Notetaker capture system audio on Linux
# (#61). Upstream skips its display-media handler on Linux; remove the skip
# and answer Linux with the loopback, like win32. Electron 42 maps that to
# the default sink's monitor.
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin 'WISPR_LINUX_MEETING_LOOPBACK' "${1:-}" \
	'extract/app/.webpack/main/index.js'

python3 - "$BUNDLE" "$MARKER" <<'PY'
import re, sys
path, marker = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8', errors='surrogateescape').read()
skip = (r'if\("linux"===process\.platform\)return [\w$]+\(\)\.info\('
        r'"\[MeetingDisplayMedia\] Skipping handler install on Linux[^"]*"'
        r'\),void\([\w$]+=!0\);')
win = r'if\("win32"===process\.platform\)(return void [\w$]+\(\{audio:"loopback"\}\))'
src, n1 = re.subn(skip, '', src)
src, n2 = re.subn(win, lambda m: 'if("win32"===process.platform||"linux"==='
                  'process.platform/*' + marker + '*/)' + m.group(1), src)
if (n1, n2) != (1, 1):
    sys.exit(f'ERROR: expected 1 Linux skip and 1 win32 loopback site, '
             f'found {n1} and {n2}.')
open(path, 'w', encoding='utf-8', errors='surrogateescape').write(src)
PY

patch_verify_marker
patch_finish "Notetaker loopback handler enabled on Linux in $BUNDLE"
