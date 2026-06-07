#!/usr/bin/env bash
#===============================================================================
# smoke-test.sh -- validate rebuilt native sqlite addons against real Electron.
#
# Runs the addons through their ACTUAL JS wrappers under Electron (RUN_AS_NODE,
# so no display is needed) and asserts:
#   1. NODE_MODULE_VERSION matches the expected Electron ABI (default 146).
#   2. better-sqlite3-multiple-ciphers opens an encrypted SQLCipher DB, round-
#      trips a row, and REJECTS a wrong key (the encrypted data path -- the V8
#      patch's getters all run here).
#   3. plain sqlite3 loads.
#
# It installs the pinned JS wrappers (npm ci against the committed lockfile in
# this dir, --ignore-scripts) into a throwaway dir and drops the supplied .node
# into each wrapper's build/Release/. This works on any normal runner against
# HARVESTED .node -- it does NOT need the rebuild's scratch tree -- so CI can
# build the .node on an old-glibc container and validate here on a full runner.
#
# Usage:   smoke-test.sh <node_dir> <electron_bin> [electron_abi]
#   node_dir       dir holding better_sqlite3.node + node_sqlite3.node
#   electron_bin   path to an Electron binary (the target version)
#   electron_abi   expected NODE_MODULE_VERSION (default: 146)
#
# Requires: node, npm, the Electron binary. Exit 0 on pass.
#===============================================================================
set -uo pipefail

this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'smoke-test: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 2 ]] || die 'usage: smoke-test.sh <node_dir> <electron_bin> [abi]'

node_dir="$(cd "$1" 2>/dev/null && pwd)" || die "node_dir not found: $1"
electron_bin="$2"
electron_abi="${3:-146}"

[[ -x $electron_bin ]] || die "electron binary not executable: $electron_bin"
[[ -f "$node_dir/better_sqlite3.node" ]] \
	|| die "better_sqlite3.node missing in $node_dir"
[[ -f "$node_dir/node_sqlite3.node" ]] \
	|| die "node_sqlite3.node missing in $node_dir"
[[ -f "$this_dir/package-lock.json" ]] \
	|| die "pinned package-lock.json missing in $this_dir"

scratch="$(mktemp -d)" || die 'mktemp failed'
# shellcheck disable=SC2064  # expand $scratch now, at trap-set time
trap "rm -rf '$scratch'" EXIT

log 'Installing pinned JS wrappers (npm ci, --ignore-scripts) ...'
cp "$this_dir/package.json" "$scratch/package.json"
cp "$this_dir/package-lock.json" "$scratch/package-lock.json"
( cd "$scratch" && npm ci --ignore-scripts --no-audit --no-fund >&2 ) \
	|| die 'npm ci failed'

# Drop the harvested .node where each wrapper loads it.
mkdir -p "$scratch/node_modules/better-sqlite3-multiple-ciphers/build/Release" \
	"$scratch/node_modules/sqlite3/build/Release"
cp "$node_dir/better_sqlite3.node" \
	"$scratch/node_modules/better-sqlite3-multiple-ciphers/build/Release/"
cp "$node_dir/node_sqlite3.node" \
	"$scratch/node_modules/sqlite3/build/Release/"

log "Running smoke test under $electron_bin (expect ABI $electron_abi) ..."
(
	cd "$scratch" \
		&& ELECTRON_RUN_AS_NODE=1 "$electron_bin" -e "
	const os = require('os'), fs = require('fs'), path = require('path');
	const v = process.versions.modules;
	if (v !== '$electron_abi') {
		console.error('NODE_MODULE_VERSION ' + v + ' != $electron_abi');
		process.exit(1);
	}
	const Database = require('better-sqlite3-multiple-ciphers');
	require('sqlite3');   // plain sqlite3 must at least load
	const f = path.join(os.tmpdir(), 'wispr-nm-smoke.db');
	fs.rmSync(f, { force: true });
	const KEY = 'correct horse battery staple';
	let db = new Database(f);
	db.pragma(\"cipher='sqlcipher'\");
	db.pragma(\"key='\" + KEY + \"'\");
	db.exec('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
	db.prepare('INSERT INTO t(v) VALUES (?)').run('ok');
	db.close();
	db = new Database(f);
	db.pragma(\"cipher='sqlcipher'\");
	db.pragma(\"key='\" + KEY + \"'\");
	const row = db.prepare('SELECT v FROM t WHERE id=1').get();
	if (!row || row.v !== 'ok') throw new Error('read-back failed');
	db.close();
	let rejected = false;
	try {
		db = new Database(f);
		db.pragma(\"cipher='sqlcipher'\");
		db.pragma(\"key='wrong key'\");
		db.prepare('SELECT v FROM t').get();
	} catch (e) { rejected = true; }
	fs.rmSync(f, { force: true });
	if (!rejected) throw new Error('wrong key was accepted -- encryption broken');
	console.error('smoke: ABI ' + v + ' ok; encrypted round-trip + reject ok');
" ) || die 'smoke test FAILED (addons load but encrypted data path broken)'

log 'SMOKE PASS'
