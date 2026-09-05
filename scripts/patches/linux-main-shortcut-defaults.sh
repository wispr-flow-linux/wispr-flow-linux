#!/usr/bin/env bash
#===============================================================================
# linux-main-shortcut-defaults.sh
#
# Makes the Wispr Flow MAIN bundle (.webpack/main/index.js) pick WINDOWS
# keyboard chords instead of macOS ones inside its shortcuts module, so Linux
# profiles are seeded with shortcuts that have actual Linux keycodes.
#
# THE BUG  (upstream issues #33 and #46)
# --------------------------------------
# A fresh Linux profile is created with push-to-talk bound to a key that does
# not exist on Linux, so dictation can never be triggered and the onboarding
# "Shortcuts" step can never be satisfied. A brand-new
# ~/.config/Wispr Flow/config.json on 1.6.774 contained:
#
#   "shortcuts": { "27":"dismiss", "-1":"ptt", "-1+32":"popo",
#                  "-1+162":"lens", "-1+162+86":"paste_last_text",
#                  "-1+162+67":"copy_last_text", "-1+77":"open_meeting_recorder" },
#   "modifierShortcut": "9"
#
# `-1` is the documented sentinel for "this key has no keycode on Linux" (see
# docs/reference/keycodes.json: opt/opt_r/cmd/cmd_r/fn/doubleFn are all -1 on
# linux). So those entries are unpressable, Settings renders the binding BLANK,
# and the helper's key monitor delivers events that match nothing. Symptoms:
#   * issue #46 -- stuck on the onboarding shortcuts screen: the shown shortcut
#     does nothing and re-recording it appears to do nothing
#   * issue #33 -- dictation silently untriggerable, blank PTT in Settings
#
# WHY THE RENDERER PATCH DOES NOT COVER THIS
# ------------------------------------------
# The chords live in a module shared by the main and renderer bundles, which
# picks between a Windows and a macOS set with a single platform flag:
#
#   <winMap> = { [ctrl+win]:Ptt, [ctrl+win+space]:Popo, ... }   // Windows
#   <macMap> = { [fn]:Ptt,       [fn+space]:Popo,       ... }   // macOS
#   defaultShortcuts = <flag> ? <winMap> : <macMap>
#
# In the RENDERER `<flag>` derives from the bridged `platform.isWindows`, which
# linux-renderer-treat-as-windows.sh already widens to include linux. But the
# profile is seeded by the MAIN process, where the same `<flag>` is
# `"win32"===process.platform` -- false on Linux -- so main takes the macOS
# branch and writes the `-1` map to config.json. Patching only the renderer
# fixes the labels you see, never the values you get.
#
# WHY NOT WIDEN THE MAIN `isWindows` FLAG AT ITS SOURCE
# -----------------------------------------------------
# Because in the main bundle that flag has ~79 consumers across the app and it
# gates the genuinely Windows-only OS-API class -- registry access,
# %LOCALAPPDATA%-style path resolution, Windows-specific process/exit-code
# semantics. Flipping it at its definition is exactly the danger
# docs/learnings/platform-gates.md warns about ("the OS-API danger class lives
# in the MAIN bundle and gates on process.platform"). So we widen the flag ONLY
# where it is read INSIDE the shortcuts module, and leave every other consumer
# reporting the real platform.
#
# THE FIX (every chord consumer in that module, not just the PTT default)
# ----------------------------------------------------------------------
# Within the shortcuts module only, each read of the flag becomes:
#
#   <flag>            ->   (<flag>||"linux"===process.platform)
#
# In 1.6.774 that module reads the flag at 8 sites, and ALL EIGHT select a
# Windows chord against a macOS chord -- the default shortcut map, the default
# modifier, the four polish-prompt / meeting-recorder chord sets, and the two
# accessors that resolve the PTT chord for display. Fixing only the PTT default
# would leave its siblings seeding `-1` (e.g. "-1+77" open_meeting_recorder), so
# the flag is widened for the whole module in one rule.
#
# Linux then seeds the documented Linux chord: PTT = Ctrl+Meta, stored as
# "162+91" (left Ctrl 162, left Meta/Win 91 -- see
# docs/learnings/global-key-monitor.md), and modifier = Alt (164) not Tab (9).
# macOS and Windows are untouched: on darwin the flag is false and the platform
# check is false, so darwin still gets <macMap>; on win32 the flag is already
# true. The module's separate isMac flag is NOT touched (it already yields the
# correct Ctrl-side chords on Linux).
#
# ANCHORING (survives re-minification, fails closed)
# --------------------------------------------------
# Every identifier is minified and churns between builds, so NONE is hardcoded.
# The module is located by its PRESERVED developer names -- the keycode-table
# properties `ctrl`/`win`/`space` and `fn`/`space`, and the command-enum members
# `Ptt`/`Popo` -- and the flag is read back out of the ternary that selects
# between those two maps. Two invariants must hold or the patch aborts without
# editing:
#   1. exactly one Windows map and one macOS map in the bundle, in one module;
#   2. EVERY read of the flag inside that module is immediately followed by `?`
#      (i.e. every use is a ternary selection, never an OS-API branch).
# If upstream ever reads the flag non-ternarily in this module, (2) trips and a
# human re-audits instead of the patch silently widening an OS gate.
#
# Usage: linux-main-shortcut-defaults.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
  BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  BUNDLE="${BUNDLE%/scripts}"
  BUNDLE="$BUNDLE/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
  echo "ERROR: bundle not found: $BUNDLE" >&2
  exit 1
fi

MARKER="WISPR_LINUX_MAIN_SHORTCUT_DEFAULTS"
if grep -q "$MARKER" "$BUNDLE"; then
  echo "Already patched ($MARKER present in $BUNDLE) - nothing to do."
  exit 0
fi

if [[ ! -f "$BUNDLE.orig" ]]; then
  cp -p "$BUNDLE" "$BUNDLE.orig"
  echo "Backup written: $BUNDLE.orig"
fi

python3 - "$BUNDLE" "$MARKER" <<'PY'
import sys, io, re

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

def only(pattern, what, hay=None):
    hay = data if hay is None else hay
    ms = list(re.finditer(pattern, hay))
    if len(ms) != 1:
        sys.exit(f"ERROR: expected exactly 1 {what}, found {len(ms)}. "
                 f"The bundle layout may have changed; inspect manually.")
    return ms[0]

# --- 1. the WINDOWS chord map: its Popo key is the ctrl+win+space chord -------
# <winMap>={[<x>]:<enum>.Ptt,[<O>([<keys>.ctrl,<keys>.win,<keys>.space])]:<enum>.Popo,
win = only(
    r'(?P<map>[\w$]+)=\{\[[\w$]+\]:(?P<enum>[\w$]+)\.Ptt,'
    r'\[(?P<O>[\w$]+)\(\[(?P<keys>[\w$]+)\.ctrl,\4\.win,\4\.space\]\)\]:\2\.Popo,',
    "Windows chord map (ctrl+win+space Popo)")
win_map, enum_obj, chord_fn, keys_obj = (
    win.group('map'), win.group('enum'), win.group('O'), win.group('keys'))

# --- 2. the macOS chord map: its Popo key is the fn+space chord --------------
mac = only(
    r'(?P<map>[\w$]+)=\{\[[\w$]+\]:%s\.Ptt,\[%s\(\[%s\.fn,%s\.space\]\)\]:%s\.Popo,'
    % tuple(map(re.escape, (enum_obj, chord_fn, keys_obj, keys_obj, enum_obj))),
    "macOS chord map (fn+space Popo)")
mac_map = mac.group('map')

# --- 3. the ternary selecting between them -> read the platform flag back out -
sel = only(r'(?P<flag>[\w$]+(?:\.[\w$]+)?)\?%s:%s'
           % (re.escape(win_map), re.escape(mac_map)),
           "winMap/macMap selecting ternary")
flag = sel.group('flag')
if '"linux"' in flag:
    sys.exit(0)   # already accounts for linux

# --- 4. bound the enclosing webpack module -----------------------------------
# Module bodies look like `,<id>(e,t,n){"use strict";...`. Walk back to the
# header that precedes both maps, and forward to the next module header.
hdr = re.compile(r',(\d{3,6})\(e,t,n\)\{"use strict";')
lo = max(m.start() for m in hdr.finditer(data, 0, min(win.start(), mac.start(), sel.start())))
nxt = hdr.search(data, max(win.end(), mac.end(), sel.end()))
hi = nxt.start() if nxt else len(data)
mod_id = hdr.match(data, lo).group(1)
body = data[lo:hi]

# Both maps and the selector must live in this one module.
for pos, what in ((win.start(), "Windows map"), (mac.start(), "macOS map"),
                  (sel.start(), "selector")):
    if not (lo <= pos < hi):
        sys.exit(f"ERROR: {what} lies outside the resolved module extent.")

# --- 5. INVARIANT: every flag read in this module is a ternary selection ------
# Left boundary matters: a bare `r.H8` string also occurs inside longer
# identifiers such as `lr.H8` (a DIFFERENT module-local elsewhere in the
# bundle), so require the flag not be preceded by an identifier or dot char.
flag_re = re.compile(r'(?<![\w$.])' + re.escape(flag) + r'(?![\w$])')
uses = list(flag_re.finditer(body))
if not uses:
    sys.exit(f"ERROR: flag {flag!r} not found inside module {mod_id}.")
non_ternary = [u for u in uses if not body[u.end():u.end() + 1] == '?']
if non_ternary:
    ctx = body[max(0, non_ternary[0].start() - 90):non_ternary[0].end() + 90]
    sys.exit(
        f"ERROR: {len(non_ternary)} of {len(uses)} reads of {flag!r} in module "
        f"{mod_id} are NOT ternary selections. Refusing to widen a possible "
        f"OS-API gate. First one: ...{ctx}...")

# --- 6. widen every read, inside this module only ----------------------------
widened = f'({flag}||"linux"===process.platform)'
new_body, n = flag_re.subn(lambda m: widened, body)
if n != len(uses):
    sys.exit(f"ERROR: widened {n} sites, expected {len(uses)}.")

# Marker on the first widened site (the grep token verify-patches.sh looks for).
first = new_body.find(widened) + len(widened)
new_body = new_body[:first] + f'/*{marker}*/' + new_body[first:]

data = data[:lo] + new_body + data[hi:]
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)

print(f"Patched module {mod_id}: flag={flag!r} widened at {len(uses)} chord-"
      f"selection site(s); winMap={win_map} macMap={mac_map}.")
PY

if ! grep -q "$MARKER" "$BUNDLE"; then
  echo "ERROR: post-patch verification failed (marker not found). Restoring." >&2
  cp -p "$BUNDLE.orig" "$BUNDLE"
  exit 1
fi

if ! grep -qF '||"linux"===process.platform)/*'"$MARKER"'*/?' "$BUNDLE"; then
  echo "ERROR: widened flag not in expected form. Restoring." >&2
  cp -p "$BUNDLE.orig" "$BUNDLE"
  exit 1
fi

if command -v node >/dev/null; then
  if ! node --check "$BUNDLE"; then
    echo "ERROR: node --check failed on patched bundle. Restoring." >&2
    cp -p "$BUNDLE.orig" "$BUNDLE"
    exit 1
  fi
  echo "node --check OK"
fi

echo "OK: Linux now picks the Windows chords in the shortcuts module of $BUNDLE"
echo
echo "Effect on a FRESH Linux profile (config.json):"
echo '  ptt                   "-1"        ->  "162+91"      (Ctrl+Meta)'
echo '  popo                  "-1+32"     ->  "162+32+91"   (Ctrl+Meta+Space)'
echo '  lens                  "-1+162"    ->  "162+164+91"  (Ctrl+Alt+Meta)'
echo '  paste_last_text       "-1+162+86" ->  "160+164+90"  (Shift+Alt+Z)'
echo '  copy_last_text        "-1+162+67" ->  "160+164+88"  (Shift+Alt+X)'
echo '  open_meeting_recorder "-1+77"     ->  "91+164+77"   (Meta+Alt+M)'
echo '  modifierShortcut      "9" (Tab)   ->  "164"         (Alt)'
echo "  macOS/Windows profiles are unchanged."
