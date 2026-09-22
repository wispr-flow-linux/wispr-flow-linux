# shellcheck shell=bash
# shellcheck disable=SC2034  # sourced data file: build.sh, download.sh, build-linux.sh and CI read these
#===============================================================================
# installer-pin.sh -- the upstream Wispr Flow installer this checkout builds.
#
# Sourced by: build.sh, scripts/build-linux.sh (standalone default), the CI
#             build workflows, and tests/installer-pin.bats.
# Rewritten by: scripts/setup/write-installer-pin.sh, which the nightly
#             check-wispr-version workflow feeds from resolve-installer-url.sh.
#
# The build never resolves "latest" itself: it downloads exactly this URL and
# refuses the file unless its SHA-256 matches. Only the bump workflow looks at
# upstream's manifest, and a bump is a reviewable commit that moves these
# three lines together. Each line is anchored on ^NAME= by the writer, so keep
# one assignment per line and single quotes.
#
# The sha256 is the one upstream publishes in
# https://dl.wisprflow.com/wispr-flow/win32/latest.json for this URL.
#===============================================================================
WISPR_VERSION='1.6.897'
WISPR_INSTALLER_URL='https://dl.wisprflow.com/wispr-flow/win32/x64/Wispr%20Flow%20Setup-v1.6.897.exe'
WISPR_INSTALLER_SHA256='1fe57d8eadb5dff9f1efa47eefd2bbfcb2c94025ff2a8c907fea5bc8d4307896'
