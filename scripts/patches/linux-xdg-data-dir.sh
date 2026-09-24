#!/usr/bin/env bash
#===============================================================================
# linux-xdg-data-dir.sh -- keep Wispr Flow's app data and log directories
# under the XDG config dir on Linux instead of ~/Library, in the main bundle
# (.webpack/main/index.js). Issue #100.
#
# WHY THIS PATCH EXISTS
# ----------------------
# The main bundle's platform-consts module derives two directories from a
# two-way gate:
#
#   <logs> = win32 ? ~\AppData\Roaming\Wispr Flow\Logs
#                  : join(homedir(),"Library","Logs","Wispr Flow")
#   <data> = win32 ? join(process.env.APPDATA||"","Wispr Flow")
#                  : join(homedir(),"Library","Application Support",
#                         "Wispr Flow")
#
# Linux falls through to the macOS arm of both (the second gate shape in
# docs/learnings/platform-gates.md), so a fresh profile ends its first
# launch with ~/Library/Application Support/Wispr Flow holding flow.sqlite,
# next to the real Electron config dir ~/.config/Wispr Flow. <data> is
# where every database path, the meetings/ and backups/ directories and the
# extension state live. <logs> feeds electron-log's file transport, which
# packaged builds keep off, and the dev-only "open log dir" action.
#
# On Windows <data> is %APPDATA%\Wispr Flow, which is also Electron's
# userData dir, so the database sits beside the Chromium state. This patch
# gives Linux the same layout: <data> becomes $XDG_CONFIG_HOME/Wispr Flow
# (default ~/.config/Wispr Flow, the dir wispr_config_dir() in
# launcher-common.sh names) and <logs> becomes its logs/ subdirectory,
# which is where electron-log's own Linux default already points.
#
# Existing installs keep their data: the launcher's
# migrate_legacy_data_dir() moves ~/Library/Application Support/Wispr Flow
# into the XDG dir before Electron starts, and `wispr-flow --doctor` warns
# while a legacy dir remains.
#
# Left alone on purpose: the pre-rename "Flow" dir (upstream's own
# migration reads it and copies its flow.sqlite into <data> when <data> has
# none; it never existed on Linux), a discarded session.json expression in
# the same module (a comma-operator operand with no effect), and the
# vendored electron-log and env-paths helpers (both already XDG on Linux).
#
# THE PATCH
# ----------
# Each macOS-arm join is wrapped in a Linux ternary that reuses the join
# and homedir callees it captured (webpack interop getters today,
# `o().join` / `i().homedir`; the `(0,x.join)` indirection shape is
# accepted too):
#
#   o().join(i().homedir(),"Library","Application Support","Wispr Flow")
#     becomes
#   ("linux"===process.platform/*WISPR_LINUX_XDG_DATA_DIR*/
#     ?o().join(process.env.XDG_CONFIG_HOME||o().join(i().homedir(),".config"),
#       "Wispr Flow")
#     :o().join(i().homedir(),"Library","Application Support","Wispr Flow"))
#
# and the logs join the same way, ending in "Wispr Flow","logs". An empty
# XDG_CONFIG_HOME falls back to ~/.config, as `${XDG_CONFIG_HOME:-...}` does
# in the launcher and as Electron does for userData.
#
# The anchors are the developer literals of each join, in any string
# delimiter (docs/learnings/patching-minified-js.md, "Quote style"), and
# each must match exactly once. The session.json join carries one more
# argument and the "Flow" join a different last one, so neither matches.
# scripts/patches/tripwires.tsv pins both literals in the pristine bundle.
#
# Verified against the pristine 1.6.897 and 1.6.937 bundles.
#
# Usage: linux-xdg-data-dir.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

# shellcheck source=scripts/patches/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
patch_begin "WISPR_LINUX_XDG_DATA_DIR" "${1:-}"

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()

Q = r'[`"\']'


def lit(s):
	return Q + re.escape(s) + Q


def callee(name):
	# o().join / o.join / (0,o.join) / (0,o().join)
	return (
		r'(?:\(0,[\w$]+(?:\(\))?\.' + name + r'\)'
		r'|[\w$]+(?:\(\))?\.' + name + r')'
	)


# (label, the macOS arm's literal tail, the Linux arm's path under the XDG
# config dir)
SITES = (
	("app data", [lit("Application Support"), lit("Wispr Flow")],
		'"Wispr Flow"'),
	("logs", [lit("Logs"), lit("Wispr Flow")],
		'"Wispr Flow","logs"'),
)

for label, tail, linux_tail in SITES:
	anchor = re.compile(
		r'(?P<join>' + callee("join") + r')\('
		r'(?P<home>' + callee("homedir") + r')\(\),'
		+ lit("Library") + ',' + ','.join(tail) + r'\)'
	)
	matches = list(anchor.finditer(src))
	if len(matches) != 1:
		sys.exit(
			f"ERROR: expected exactly 1 macOS {label} join, found "
			f"{len(matches)}. The platform-consts module moved; re-audit "
			f"the \"Library\" path sites before patching.")
	m = matches[0]
	j, h = m.group("join"), m.group("home")
	linux = (
		j + "(process.env.XDG_CONFIG_HOME||" + j + "(" + h + '(),".config"),'
		+ linux_tail + ")"
	)
	wrapped = (
		'("linux"===process.platform/*' + marker + '*/?' + linux + ":"
		+ m.group(0) + ")"
	)
	src = src[:m.start()] + wrapped + src[m.end():]
	print(f"Patched: the {label} dir resolves under XDG_CONFIG_HOME on Linux.")

if src.count(marker) != len(SITES):
	sys.exit(f"ERROR: expected {len(SITES)} markers after patching.")

with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(src)
PY

patch_verify_marker

patch_finish "Linux app data and logs dirs under XDG_CONFIG_HOME in $BUNDLE"
