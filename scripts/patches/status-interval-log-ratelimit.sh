#!/usr/bin/env bash
#===============================================================================
# status-interval-log-ratelimit.sh
#
# Rate-limits the two leaked-interval log lines that flood main.log once the
# status (Flow Bar) window has been torn down, in the webpack-bundled Electron
# main process (.webpack/main/index.js).
#
# WHY THIS PATCH EXISTS
# ---------------------
# The status window uses a destroy-on-hide / rebuild-on-show lifecycle, but two
# of its main-process intervals (monitorMove @400ms and the alpha-region
# hit-test poll @~250ms) keep firing after the window is destroyed. Each tick
# logs one line:
#
#   [info] Window is destroyed, ignoring monitorMove interval
#   [info] Window is destroyed, ignoring interval for ignoreMouseEventsWhenNotInAlphaRegion
#
# Together that is ~6.4 lines/second, ~1.2 MiB/hour -- 98%+ of main.log in the
# field. electron-log rotates at 3 MiB with a single main.old.log, so the spam
# destroys all diagnostic history in ~5 hours and the evidence of any failure
# moment (e.g. wispr-flow-linux/helper#7) is routinely gone by the time anyone
# looks. Upstream's real bug is that the intervals are not cleared when the
# window is destroyed; until that is fixed upstream, sampling the two log
# sites 1-in-600 keeps a heartbeat of the condition (~1 line per 4 minutes
# per site) without burning the rotation window. See issue #48.
#
# THE PATCH (two sites, expression-safe)
# --------------------------------------
# Each site has the minified shape
#
#   <id>().info("<literal>")
#
# one in statement position (`else a().info(...)`), one behind `return void`.
# The replacement is therefore a pure expression, valid in both positions:
#
#   ((globalThis.WISPR_LINUX_LOG_RATELIMIT_<K> =
#     (globalThis.WISPR_LINUX_LOG_RATELIMIT_<K>||0)+1)%600!==1 ||
#       <id>().info("<literal> [sampled 1/600]"))
#
# The counter lives on globalThis (one per site), the first tick still logs
# (so the condition remains visible), and the original developer string stays
# a prefix of the logged message so existing greps keep matching. The marker
# WISPR_LINUX_LOG_RATELIMIT is carried by the counter names themselves.
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
  # default to the in-repo extracted bundle
  BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/extract/app/.webpack/main/index.js"
fi

if [[ ! -f "$BUNDLE" ]]; then
  echo "ERROR: bundle not found: $BUNDLE" >&2
  exit 1
fi

# --- Idempotency guard --------------------------------------------------------
RL_MARKER="WISPR_LINUX_LOG_RATELIMIT"
if grep -q "$RL_MARKER" "$BUNDLE"; then
  echo "Already patched ($RL_MARKER present in $BUNDLE) - nothing to do."
  exit 0
fi

# --- Backup -------------------------------------------------------------------
if [[ ! -f "$BUNDLE.orig" ]]; then
  cp -p "$BUNDLE" "$BUNDLE.orig"
  echo "Backup written: $BUNDLE.orig"
fi

# --- Patch (anchored on the preserved developer log strings) ------------------
python3 - "$BUNDLE" "$RL_MARKER" <<'PY'
import re, sys, io
path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

# (counter-suffix, developer log string). The strings are the stable anchors;
# the logger identifier ([\w$]+ -- minified names may contain $) is captured
# per site.
SITES = [
    ("MM", "Window is destroyed, ignoring monitorMove interval"),
    ("ALPHA",
     "Window is destroyed, ignoring interval for "
     "ignoreMouseEventsWhenNotInAlphaRegion"),
]

for key, literal in SITES:
    pat = re.compile(r'([\w$]+)\(\)\.info\("' + re.escape(literal) + r'"\)')
    matches = pat.findall(data)
    if len(matches) != 1:
        sys.exit(
            f"ERROR: expected exactly 1 '{literal[:40]}...' log site, "
            f"found {len(matches)}. Bundle layout changed; re-audit "
            f"(docs/learnings/patching-minified-js.md).")
    ctr = f"globalThis.{marker}_{key}"

    def repl(m, ctr=ctr, literal=literal):
        logger = m.group(1)
        return (f"(({ctr}=({ctr}||0)+1)%600!==1||"
                f'{logger}().info("{literal} [sampled 1/600]"))')

    data = pat.sub(repl, data, count=1)

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write(data)
print("Patched: both leaked-interval log sites now sample 1-in-600 (2).")
PY

# --- Verify the result --------------------------------------------------------
if ! grep -q "$RL_MARKER" "$BUNDLE"; then
  echo "ERROR: post-patch verification failed (marker not found)." >&2
  echo "       Restoring backup." >&2
  cp -p "$BUNDLE.orig" "$BUNDLE"
  exit 1
fi

# Syntax-check: the replacement is an expression spliced into two different
# grammatical positions; catch any edit that serializes but doesn't parse.
if command -v node >/dev/null; then
  if ! node --check "$BUNDLE"; then
    echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
    cp -p "$BUNDLE.orig" "$BUNDLE"
    exit 1
  fi
  echo "node --check OK"
fi
echo "OK: leaked-interval log spam is rate-limited (1/600 per site) in $BUNDLE"
