#!/usr/bin/env bash
#===============================================================================
# linux-status-input.sh -- let the Linux Status window accept clicks on its own
# controls, in the main bundle (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# The Status window is created click-through on Linux
# (`setIgnoreMouseEvents(true, {forward:true})`). Its own controls -- the
# pill's stop button during Notetaker and the notification card's buttons --
# therefore receive no clicks unless the 400 ms alpha hit-test poll happens to
# re-enable input, and that poll is fragile outside dictation (#71/#144).
#
# THE ANCHOR
# ----------
# The shim only needs the strings main already uses: the Status window title,
# the renderer's surface report channel, and the notification show/clear
# channels. Each is present exactly once in the pristine bundle. It is
# injected right after the webpack license banner and attaches to the Status
# window on browser-window-created.
#
# THE PATCH
# ---------
# While the renderer reports a visible surface, or while a notification is
# shown, the window accepts input; when both are gone it returns to
# click-through. The window size and the pill are untouched.
#
# Verified against the pristine 1.6.1209 and 1.6.1264 bundles.
#
# Usage: linux-status-input.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_STATUS_INPUT" "${1:-}"

SHIM="$PATCH_LIB_DIR/linux-status-input.js"

if ! python3 - "$BUNDLE" "$MARKER" "$SHIM" <<'PY'
import io, re, sys

path, marker, shim_path = sys.argv[1], sys.argv[2], sys.argv[3]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    src = f.read()
with io.open(shim_path, "r", encoding="utf-8") as f:
    shim = f.read()

if not shim.startswith("/*" + marker + "*/"):
    sys.exit(f"ERROR: {shim_path} must open with the {marker} marker.")
if not shim.endswith("\n"):
    shim += "\n"

Q = r'[`"\']'
contract = {
    "Status window title": "title:" + Q + "Flow Status Indicator" + Q,
    "Status surface report channel": Q + "status:reportAlphaCatchRects" + Q,
    "Status notification show channel": Q + "notification:show" + Q,
    "Status notification clear channel": Q + "notification:clear" + Q,
}
for label, pattern in contract.items():
    count = len(re.findall(pattern, src))
    if count != 1:
        sys.exit(f"ERROR: upstream contract changed: {label} found {count} times, expected 1.")

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
print(f"Patched: status input shim injected {where}.")
PY
then
	patch_restore
	exit 1
fi

patch_verify_marker
patch_finish "Status window controls accept clicks in $BUNDLE"
