#!/usr/bin/env bash
# Hooks the updateDictationStatus log in .webpack/main/index.js.
# Wraps the log with audio control and stages its worker beside the bundle.
# Verified against Wispr Flow 1.6.1209.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
if [[ -f ${1:-} ]]; then
	runtime="$(dirname "$1")/linux-dictation-audio.js"
	cp "$PATCH_LIB_DIR/linux-dictation-audio.js" "$runtime" || exit 1
	node --check "$runtime" || exit 1
fi
patch_begin 'WISPR_LINUX_DICTATION_AUDIO' "${1:-}"

python3 - "$BUNDLE" "$MARKER" <<'PY' || exit 1
import io
import re
import sys

path = sys.argv[1]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as bundle:
    source = bundle.read()
anchor = re.compile(
    r'[\w$]+\(\)\.info\(`updateDictationStatus: \$\{(?P<status>[\w$]+)\}`,'
    r'\{customAttributes:\{uuid:(?P<dictation>[\w$]+\.[\w$]+)\.uuid\}\}\),'
)
matches = list(anchor.finditer(source))
if len(matches) != 1:
    sys.exit(f'ERROR: expected one dictation status setter, found {len(matches)}.')
match = matches[0]
status = match['status']
region = source[match.end():match.end() + 1600]
transitions = list(re.finditer(
    re.escape(match['dictation']) + r'\.status=' + re.escape(status) + r'(?=[,;}])',
    region,
))
if len(transitions) != 1:
    sys.exit(f'ERROR: expected one dictation status update, found {len(transitions)}.')
forwards = list(re.finditer(
    r'\((?P<state>[\w$]+\.[\w$]+)\.hubWindow,'
    r'[\w$]+\.[\w$]+\.DictationStatus,' + re.escape(status) + r'\)',
    region[:transitions[0].start()],
))
if len(forwards) != 1:
    sys.exit(f'ERROR: expected one Hub status forward, found {len(forwards)}.')
hook = (
    f'/*{sys.argv[2]}*/(process.platform==="linux"&&'
    'require(require("path").join(__dirname,"linux-dictation-audio.js"))('
    f'{status}==="initializing"||{status}==="listening",'
    f'{forwards[0]["state"]}.prefs?.user)),'
)
replacement = f'({hook}{match[0][:-1]}),'
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as bundle:
    bundle.write(source[:match.start()] + replacement + source[match.end():])
PY

patch_verify_marker
patch_finish "Linux dictation audio controls added to $BUNDLE"
