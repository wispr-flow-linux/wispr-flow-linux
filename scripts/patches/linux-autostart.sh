#!/usr/bin/env bash
#===============================================================================
# linux-autostart.sh -- make "Open at login" work on Linux and start the app
# hidden when it was launched at login (issue #81), in the main bundle
# (.webpack/main/index.js).
#
# Electron's app.setLoginItemSettings / getLoginItemSettings do nothing
# useful on Linux: the setter writes no autostart entry and the getter
# always reports wasOpenedAtLogin:false. Wispr Flow reaches both from code
# that runs on Linux:
#
#   the Settings toggle        setLoginItemSettings({openAtLogin:e})
#   the new-user hook          setLoginItemSettings({openAtLogin:!0})
#   the Hub launch decision    getLoginItemSettings().wasOpenedAtLogin
#                              ? stay hidden : show
#
# so the toggle is a no-op and the Hub opens on every launch, login
# included. linux-autostart.js (beside this file) replaces the two methods
# on Linux with an XDG autostart entry carrying `--hidden`, which is how
# Anthropic's official Claude Desktop for Linux does it. Replacing the
# methods rather than patching each caller keeps this patch free of
# minified-identifier anchors: it only needs a place to stand at the top of
# the bundle. The three call shapes above are tripwires (the toggle's
# argument as `[\w$]+`, since only the call matters), so a caller that
# moves or disappears fails by name in step 3.
#
# Insertion: right after the webpack license banner on line 1 when there is
# one (the same slot linux-early-singleton.sh uses; the two do not depend on
# each other's order), else at byte 0. The injected code has no side effects
# at load beyond replacing the two methods; outside the setter, its only
# file write is the repair in the first getLoginItemSettings() call, which
# only the primary instance makes.
#
# Verified against the pristine 1.6.897 and 1.6.937 bundles.
#
# Usage: linux-autostart.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_AUTOSTART" "${1:-}"

SHIM="$PATCH_LIB_DIR/linux-autostart.js"

python3 - "$BUNDLE" "$MARKER" "$SHIM" <<'PY'
import io, sys

path, marker, shim_path = sys.argv[1], sys.argv[2], sys.argv[3]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()
with io.open(shim_path, "r", encoding="utf-8") as f:
	shim = f.read()

if not shim.startswith("/*" + marker + "*/"):
	sys.exit(f"ERROR: {shim_path} must open with the {marker} marker.")
if not shim.endswith("\n"):
	shim += "\n"

first, nl, rest = src.partition("\n")
if first.startswith("/*!") and first.rstrip().endswith("*/") and nl:
	src = first + "\n" + shim + rest
	where = "after the license banner"
else:
	src = shim + src
	where = "at the top of the bundle"

if src.count(marker) != 1:
	sys.exit("ERROR: expected the marker exactly once after injection.")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(src)
print(f"Patched: login-item shim injected {where}.")
PY

patch_verify_marker

patch_finish "Linux login items backed by an XDG autostart entry in $BUNDLE"
