#!/usr/bin/env bash
# Skip the dictation mic-conflict probes on Linux. The helper does not
# report which processes hold the microphone. Audio capture is separate.
set -uo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" || exit 1
patch_begin 'WISPR_LINUX_MIC_CONFLICT' "${1:-}" \
	'extract/app/.webpack/main/index.js'

python3 - "$BUNDLE" "$MARKER" <<'PY' || exit 1
from pathlib import Path
import re
import sys

path, marker = Path(sys.argv[1]), sys.argv[2]
data = path.read_text(encoding="utf-8", errors="surrogateescape")
gate = re.compile(r'if\((?=!\(0,[\w$]+\.micConflictDetectionOn\)\(\)\|\|)')
patched, count = gate.subn(f'if(/*{marker}*/"linux"===process.platform||', data)
if count != 1:
    if count or "micConflictDetectionOn" in data or "[MicConflict]" in data:
        sys.exit(f"ERROR: expected one mic-conflict feature gate, found {count}.")
    # Older bundles predate the watcher. Record the verified no-op so
    # the repack verifier can still distinguish a skipped patch stage.
    patched = data + f"\n/*{marker}: no watcher*/\n"
path.write_text(patched, encoding="utf-8", errors="surrogateescape")
PY

patch_verify_marker
patch_expect_shape -qE '/\*'"$MARKER"'(\*/"linux"===process\.platform\|\|!|: no watcher\*/)' \
	-- 'Linux mic-conflict gate is not in the expected form.'
patch_finish 'Skipped the unsupported microphone-conflict check on Linux.'
