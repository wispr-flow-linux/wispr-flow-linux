#!/usr/bin/env bash
#===============================================================================
# verify-patches.sh -- static-grep the SHIPPED app.asar for the Linux patch
# markers, so a half-patched or unpatched asar fails the build (and CI) instead
# of shipping silently.
#
# This is the post-repack safety net for the Linux patch suite:
#   main bundle:
#     * helper-resolver.sh     -> inserts the Linux helper-path override
#     * helper-env.sh          -> spreads session env into the helper spawn
#     * mac-gates.sh           -> gates the macOS Applications-folder guard
#     * linux-window-frame.sh  -> frameless hub/settings window on Linux
#     * linux-deeplink.sh      -> cold-start wispr-flow: argv parse on Linux
#     * linux-overlay-visible.sh -> setVisibleOnAllWorkspaces for overlay windows
#   renderer bundles:
#     * linux-renderer-chrome.sh -> remaps the <html> platform class linux->win32
#     * linux-renderer-treat-as-windows.sh -> widens each renderer's isWindows
#       bind so its consumers take the Windows branch on Linux (the bridge's
#       platform.isWindows stays honest/false; no preload is touched)
#
# The .asar container stores the JS bundle as concatenated plaintext, so a
# byte-level grep over the packed file finds these markers without unpacking.
# We anchor on DEVELOPER STRINGS the minifier preserves, never on minified
# identifiers (which churn every release).
#
# Usage:   verify-patches.sh <path-to-app.asar>
# Exit 0 = all markers present; exit 1 = at least one missing (build should fail).
#===============================================================================
# No `set -e` (project styleguide): the grep probes below intentionally tolerate
# a no-match via `|| true` and accumulate into `missing`; status is checked
# explicitly. `set -u` + pipefail still apply.
set -uo pipefail

ASAR="${1:-}"
if [[ -z "$ASAR" || ! -f "$ASAR" ]]; then
  echo "usage: $0 <path-to-app.asar>" >&2
  exit 2
fi

# Each entry: "human label|grep mode|pattern"
#   mode F = fixed string (grep -aF), P = Perl regex (grep -aP)
MARKERS=(
  "helper-resolver: Linux branch marker|F|WISPR_LINUX_HELPER_BRANCH"
  "helper-resolver: Linux helper log line|F|Running packaged Linux Helper service"
  "helper-resolver: Linux helper staged path|F|wispr-flow-linux-helper"
  "helper-env: session env spread into helper spawn|F|WISPR_LINUX_HELPER_ENV"
  "mac-gates: darwin gate before getAppPath|P|if\\(\"darwin\"!==process\\.platform\\)return!1;const[ ]*[\\w\$]+=[\\w\$]+\\.app\\.getAppPath"
  "renderer-chrome: linux->win32 platform-class remap|F|WISPR_LINUX_WIN32_CHROME"
  "window-frame: linux frameless window branch|F|WISPR_LINUX_FRAMELESS"
  "treat-as-windows: linux widens renderer isWindows bind|F|WISPR_LINUX_RENDERER_ISWIN"
  "deeplink: linux cold-start argv parse|F|WISPR_LINUX_DEEPLINK"
  "overlay-visible: setVisibleOnAllWorkspaces on Linux for overlay windows|F|WISPR_LINUX_OVERLAY_VISIBLE"
  "status-position: pill placed above panel / autohide dock|F|WISPR_LINUX_STATUS_POSITION"
  "autostart: XDG desktop entry for Start at Login|F|WISPR_LINUX_AUTOSTART"
  "status-autohide: pill hidden when idle, shown on dictation|F|WISPR_LINUX_STATUS_AUTOHIDE"
)

missing=0
for entry in "${MARKERS[@]}"; do
  label="${entry%%|*}"; rest="${entry#*|}"
  mode="${rest%%|*}"; pat="${rest#*|}"
  if [[ "$mode" == "P" ]]; then
    found=$(grep -acP -- "$pat" "$ASAR" 2>/dev/null || true)
  else
    found=$(grep -acF -- "$pat" "$ASAR" 2>/dev/null || true)
  fi
  if [[ "${found:-0}" -ge 1 ]]; then
    echo "  OK      $label"
  else
    echo "  MISSING $label" >&2
    missing=1
  fi
done

if [[ "$missing" != "0" ]]; then
  echo "ERROR: app.asar is missing one or more Linux patch markers -- the bundle is" >&2
  echo "       unpatched or half-patched. Refusing to treat this as a good build." >&2
  echo "       Re-run patch-helper-resolver.sh / patch-mac-gates.sh before repacking." >&2
  exit 1
fi

echo "OK: all Linux patch markers present in $ASAR"
