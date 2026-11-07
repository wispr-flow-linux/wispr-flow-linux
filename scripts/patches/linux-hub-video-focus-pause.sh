#!/usr/bin/env bash
#===============================================================================
# linux-hub-video-focus-pause.sh -- stop the hidden Hub's onboarding video
# from playing (and holding a screen wake lock) until the Hub is focused, in
# the Hub renderer bundle (.webpack/renderer/hub/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# Started at login (`--hidden`, the XDG autostart entry), the app holds an
# org.freedesktop.ScreenSaver inhibit, reason "Video Wake Lock", until it
# quits, so the screen never turns off. The chain:
#
#   1. The Hub BrowserWindow is created with show:!1 and Electron's default
#      paintWhenInitiallyHidden:true, so the never-shown Hub page reports
#      document.visibilityState "visible".
#   2. An account that hasn't finished the post-onboarding dialog ("How would
#      you like to use Flow first?") has it rendered in that Hub, with an
#      autoPlay loop muted <video>.
#   3. Chromium takes a display-sleep wake lock for any playing video in a
#      visible WebContents, muted or not; on Linux that is the inhibit.
#
# Upstream already meant to stop this video when nobody is looking: the
# dialog's hook pauses it on window "blur" and plays it again on "focus",
# but only a video the hook itself paused (its ref flag):
#
#   const a=()=>{const t=e.current;t&&!t.paused&&(n.current=!0,t.pause())},
#         r=()=>{const t=e.current;t&&n.current&&(t.play()...,n.current=!1)};
#   return window.addEventListener("blur",a),window.addEventListener("focus",r)
#
# A window that was never shown never blurs, so the video plays forever.
#
# THE PATCH
# ---------
# Also listen for the video's "play" event, and when the document does not
# have focus, run the hook's own blur handler, which pauses the video and
# sets the flag:
#
#   ...};return window.addEventListener("blur",a),...,()=>{...remove...}
#     becomes
#   ...};/*MARKER*/const wflVideo=e.current,wflPlay=()=>{document.hasFocus()
#         ||a()};wflVideo&&wflVideo.addEventListener("play",wflPlay);
#   return window.addEventListener("blur",a),...,()=>{...remove...,
#         wflVideo&&wflVideo.removeEventListener("play",wflPlay)}
#
# A one-off pause at mount is not enough: the dialog's video component
# attaches its source (hls.js, a MediaSource) after the hook mounts, and the
# media load algorithm re-arms autoplay. The "play" event fires for every
# start, autoplay included, so the hidden Hub's video stops as it starts.
# When the Hub is opened it gets "focus", and the hook's own focus handler
# plays the video, so the dialog looks as upstream intends. A focused Hub is
# unchanged.
#
# Why not paintWhenInitiallyHidden:false on the Hub window instead: it also
# stops the wake lock, but the hidden page then skips autoplay and the focus
# handler never resumes a video it did not pause, so the dialog's video sits
# frozen on its first frame with no control to start it.
#
# Anchor: the hook's pause/resume pair and its blur/focus registration. There
# are no developer strings inside the hook, so the anchor is its whole shape
# with every minified identifier captured as [\w$]+ and back-referenced. The
# EXPECTED count assertion fails loudly if upstream reshapes it.
# Verified on 1.6.957 and 1.6.1337.
#
# Usage: linux-hub-video-focus-pause.sh <path-to-.webpack/renderer/hub/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_HUB_VIDEO_FOCUS_PAUSE" "${1:-}" \
	"extract/app/.webpack/renderer/hub/index.js"

# --- Patch (anchored on the hook's whole minified shape) ----------------------
python3 - "$BUNDLE" "$MARKER" <<'PY'
import sys, io, re
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

I = r'[\w$]+'
site = re.compile(
    # g1: the blur handler. g2 its name, g3 its local, g4 the video ref,
    # g5 the hook's paused-by-me flag.
    r'(const (' + I + r')=\(\)=>\{const (' + I + r')=(' + I + r')\.current;'
    r'\3&&!\3\.paused&&\((' + I + r')\.current=!0,\3\.pause\(\)\)\},'
    # the focus handler (g6), same ref and flag.
    r'(' + I + r')=\(\)=>\{const (' + I + r')=\4\.current;'
    r'\7&&\5\.current&&\(\7\.play\(\)\.catch\(\(\)=>\{\}\),\5\.current=!1\)\};)'
    # g8: the registration that follows, up to the cleanup's last removal.
    r'(return window\.addEventListener\("blur",\2\),'
    r'window\.addEventListener\("focus",\6\),\(\)=>\{'
    r'window\.removeEventListener\("blur",\2\),'
    r'window\.removeEventListener\("focus",\6\))\}'
)
matches = list(site.finditer(data))

EXPECTED = 1
if len(matches) != EXPECTED:
    sys.exit(
        f"ERROR: expected exactly {EXPECTED} blur/focus video-pause hook "
        f"site(s), found {len(matches)}. Bundle layout may have changed; "
        f"re-audit the post-onboarding dialog's video hook before patching."
    )

# The wfl-prefixed names cannot collide with the minifier's short names.
if "wflVideo" in data or "wflPlay" in data:
    sys.exit("ERROR: the bundle already uses wflVideo/wflPlay; pick new names.")

def fix(m):
    blur, ref = m.group(2), m.group(4)
    return (
        m.group(1)
        + '/*' + marker + '*/const wflVideo=' + ref + '.current,'
        + 'wflPlay=()=>{document.hasFocus()||' + blur + '()};'
        + 'wflVideo&&wflVideo.addEventListener("play",wflPlay);'
        + m.group(8)
        + ',wflVideo&&wflVideo.removeEventListener("play",wflPlay)}'
    )

data = site.sub(fix, data, count=EXPECTED)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print(f"Patched: the Hub video hook pauses a video that starts while the "
      f"Hub is unfocused ({EXPECTED} site).")
PY

# --- Verify the result --------------------------------------------------------
patch_verify_marker

listener='/\*'"$MARKER"'\*/const wflVideo=[\w$]+\.current,'
listener+='wflPlay=\(\)=>\{document\.hasFocus\(\)\|\|[\w$]+\(\)\};'
listener+='wflVideo&&wflVideo\.addEventListener\("play",wflPlay\);'
listener+='return window\.addEventListener\("blur",'
patch_expect_shape -qP "$listener" \
	-- 'injected play listener not in expected form.'
patch_expect_shape -qF \
	',wflVideo&&wflVideo.removeEventListener("play",wflPlay)}' \
	-- 'injected cleanup not in expected form.'

patch_finish "Hub video focus-pause applied in $BUNDLE"
echo
echo "The post-onboarding dialog's video hook now pauses the video whenever it"
echo "starts while the Hub has no focus, so a hidden Hub holds no wake lock;"
echo "focusing the Hub plays it through upstream's own focus handler."
