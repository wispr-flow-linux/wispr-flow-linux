#!/usr/bin/env bash
# The installed Linux package supplies updates. Skip the vendor update
# check before it fetches a feed for the unsupported in-app updater.
set -uo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" || exit 1
patch_begin 'WISPR_LINUX_PACKAGE_UPDATES' "${1:-}" \
	'extract/app/.webpack/main/index.js'

python3 - "$BUNDLE" "$MARKER" <<'PY' || exit 1
from pathlib import Path
import re
import sys

path, marker = Path(sys.argv[1]), sys.argv[2]
data = path.read_text(encoding="utf-8", errors="surrogateescape")
check = re.compile(
    r'async checkForUpdates\([\w$]+=!1\)\{'
    r'(?=if\(this\.updateState!==[^\n]{0,1000}await this\.setAutoUpdateUrl\(\))'
)
patched, count = check.subn(
    lambda match: match[0] + f'/*{marker}*/if("linux"===process.platform)return;',
    data,
)
if count != 1:
    sys.exit(f"ERROR: expected one vendor update check, found {count}.")
path.write_text(patched, encoding="utf-8", errors="surrogateescape")
PY

patch_verify_marker
patch_expect_shape -qF '/*'"$MARKER"'*/if("linux"===process.platform)return;' \
	-- 'Linux package-update gate is not in the expected form.'
patch_finish 'Disabled the vendor update check on packaged Linux.'
