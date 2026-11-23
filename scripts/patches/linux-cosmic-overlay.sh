#!/usr/bin/env bash
# Forward ordinary dictation state to the COSMIC layer-shell indicator.
# Usage: linux-cosmic-overlay.sh <path-to-.webpack/main/index.js>
set -uo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin 'WISPR_LINUX_COSMIC_OVERLAY' "${1:-}"

python3 - "$BUNDLE" "$PATCH_LIB_DIR/linux-cosmic-overlay.js" <<'PY' || exit 1
import re
import sys
from pathlib import Path

bundle, bridge = map(Path, sys.argv[1:])
text = bundle.read_bytes()
ident = rb'[\w$]+'
member = ident + rb'(?:\.' + ident + rb')+'
call = rb'\(0,' + member + rb'\)'


def locate(anchor, literal, before, after, name):
    matches = []
    for occurrence in re.finditer(re.escape(literal), text):
        matches.extend(
            anchor.finditer(text, max(0, occurrence.start() - before),
                            occurrence.end() + after)
        )
    if len(matches) != 1:
        sys.exit(f'ERROR: expected one {name} anchor, found {len(matches)}. '
                 f'Re-audit the status window.')
    return matches[0]


log = rb'updateDictationStatus: skipping bubble DictationStatus IPC'
anchor = re.compile(
    rb'(?P<options>' + ident + rb')\.skipBubbleIPC\?' + ident + rb'\(\)\.'
    rb'info\((?P<quote>[`"\'])' + log + rb'[^\r\n]{0,100}?(?P=quote)[^\r\n]{0,110}?\):'
    + call + rb'\((?P<window>' + ident + rb'),(?P<channel>' + member
    + rb')\.DictationStatus,(?P<phase>' + ident + rb')\),'
    + call + rb'\(' + member + rb',(?P=channel)\.DictationStatus,(?P=phase)\);'
    rb'const ' + ident + rb'=(?P<state>' + member + rb')\.status;'
)
match = locate(anchor, log, 120, 540, 'dictation status bridge')

show_log = rb'Status window is not available or destroyed. Recreating.'
show_anchor = re.compile(
    rb'(?P<function>' + ident + rb')=\((?P<arg>' + ident + rb')=' + member
    + rb'\)=>\{(?=const (?P<window>' + ident + rb')=' + member
    + rb'\.statusWindow;if\(!(?P=window)\|\|(?P=window)\.isDestroyed\(\)\)'
    + rb'return ' + ident + rb'\(\)\.error\((?P<quote>[`"\'])'
    + re.escape(show_log) + rb'(?P=quote)\))'
)
show = locate(show_anchor, show_log, 240, 4, 'dictation status-window show')

# Create the startup renderer as usual so it can receive IPC and notifications.
# Only the AppReady call passes the new flag that keeps the window unmapped.
ready_log = rb'AnalyticsEventKey.AppReady'
ready_anchor = re.compile(
    ident + rb'\.sendEvent\(' + ident + rb'\.' + re.escape(ready_log)
    + rb',\{timeToOpen:Date\.now\(\)-' + member + rb'\.appReadyTime\}\),'
    + call + rb'\(\)'
)
ready = locate(ready_anchor, ready_log, 130, 200, 'AppReady status-window call')

rebuild_log = rb'Tried to show/hide status window, but it was destroyed. Rebuilding.'
rebuild_anchor = re.compile(
    ident + rb'=(?P<args>\(\))=>\{const ' + ident + rb'=\('
    + rb'(?P<win>' + member + rb'\.statusWindow)&&!(?P=win)\.isDestroyed\(\)'
    + rb'\|\|\(\s*(?P<logger>' + ident + rb')\(\)\.error\((?P<quote>[`"\'])'
    + re.escape(rebuild_log) + rb'(?P=quote)\),(?P=win)=' + ident
    + rb'\(\)\),(?P=win)\);'
)
rebuild = locate(rebuild_anchor, rebuild_log, 240, 170,
                 'status-window constructor')

options, window, phase, state = [match[key] for key in
                                ('options', 'window', 'phase', 'state')]
hook = (
    b'wisprLinuxCosmicOverlay?.update('
    + options + b'.skipBubbleIPC||' + state + b'.isInstructMode||'
    + state + b'.matchedRouteName?"idle":' + phase + b',' + window + b');'
)
defer = (b'if(wisprLinuxCosmicOverlay?.deferShow(()=>'
         + show['function'] + b'(' + show['arg'] + b')))return;')
keep_hidden = (
    b'if(wisprLinuxHiddenStartup===!0)return '
    + rebuild['logger'] + b'().info("Prepared hidden COSMIC status window");'
)
insertions = [
    (match.end(), hook),
    (show.end(), defer),
    (ready.end() - 1, b'!!wisprLinuxCosmicOverlay'),
    (rebuild.start('args') + 1, b'wisprLinuxHiddenStartup'),
    (rebuild.end(), keep_hidden),
]
for offset, snippet in sorted(insertions, reverse=True):
    text = text[:offset] + snippet + text[offset:]
bundle.write_bytes(bridge.read_bytes() + b'\n' + text)
PY

patch_verify_marker
patch_expect_shape -qF 'wisprLinuxCosmicOverlay?.update(' \
	-- 'COSMIC dictation state bridge not found.'
patch_expect_shape -qF 'wisprLinuxCosmicOverlay?.deferShow(' \
	-- 'COSMIC status-window guard not found.'
patch_expect_shape -qF 'if(wisprLinuxHiddenStartup===!0)' \
	-- 'COSMIC hidden startup guard not found.'
patch_finish 'COSMIC dictation overlay bridge active when supported'
