#!/usr/bin/env node
// fetch-electron-binary.js -- download the Linux Electron prebuilt binary into
// a destination dist directory and rename the launcher 'electron' -> 'wispr-flow'.
//
// Why the rename: with the launcher named 'electron', Electron sets
// app.isPackaged=false, the app resolves DEV resource paths, and 0 DB
// migrations load ("no such table"). Renaming to 'wispr-flow' flips
// isPackaged=true and all migrations run. (See scripts/build-linux.sh step6.)
//
// Usage:
//   node fetch-electron-binary.js [destDir]
// Env (mirrors @electron/get + upstream tooling):
//   ELECTRON_VERSION   electron version to fetch (default: 42.3.0)
//   ELECTRON_ARCH      x64 | arm64 | armv7l | ia32 (default: host arch)
//   ELECTRON_MIRROR    release base URL override
//   ELECTRON_CUSTOM_DIR path segment override (replaces "v<version>")
//   destDir arg or WORK_DIR/downloads/electron-dist
//
// Prefers @electron/get + extract-zip when resolvable from the work dir's
// node_modules; otherwise this file documents the expected layout and exits
// non-zero so the bash fallback (download.sh fetch_electron) can take over.

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

function resolveArch() {
	if (process.env.ELECTRON_ARCH) {
		return process.env.ELECTRON_ARCH;
	}
	// node's process.arch maps cleanly to electron archs, except 'arm'.
	return process.arch === 'arm' ? 'armv7l' : process.arch;
}

async function main() {
	const version = process.env.ELECTRON_VERSION || '42.3.0';
	const platform = 'linux';
	const arch = resolveArch();

	const supportedArchs = ['x64', 'arm64', 'armv7l', 'ia32'];
	if (!supportedArchs.includes(arch)) {
		throw new Error(
			`Unsupported architecture: ${arch}. ` +
			`Electron publishes Linux binaries for ${supportedArchs.join(', ')}.`,
		);
	}

	const cwd = process.cwd();
	const destDir = process.argv[2]
		|| path.join(process.env.WORK_DIR || path.join(cwd, 'build-linux'), 'downloads', 'electron-dist');

	// Resolve @electron/get + extract-zip from the work dir's node_modules.
	let downloadArtifact;
	let extractZip;
	try {
		const workDirRequire = createRequire(path.join(cwd, 'package.json'));
		({ downloadArtifact } = workDirRequire('@electron/get'));
		extractZip = workDirRequire('extract-zip');
	} catch (err) {
		console.error(
			'@electron/get / extract-zip not resolvable from ' + cwd + '\n' +
			'Falling back: use scripts/setup/download.sh fetch_electron (pure bash).\n' +
			(err && err.message ? err.message : String(err)),
		);
		process.exit(2);
	}

	console.log(`Fetching electron@${version} for ${platform}-${arch}...`);
	const zipPath = await downloadArtifact({
		version,
		platform,
		arch,
		artifactName: 'electron',
		mirrorOptions: buildMirrorOptions(version),
	});

	console.log(`Extracting ${zipPath} into ${destDir}`);
	fs.mkdirSync(destDir, { recursive: true });
	await extractZip(zipPath, { dir: destDir });

	// MANDATORY rename: electron -> wispr-flow.
	const electronBin = path.join(destDir, 'electron');
	const wisprBin = path.join(destDir, 'wispr-flow');
	if (fs.existsSync(electronBin)) {
		fs.renameSync(electronBin, wisprBin);
		fs.chmodSync(wisprBin, 0o755);
		console.log('Renamed launcher electron -> wispr-flow (sets app.isPackaged=true).');
	} else if (fs.existsSync(wisprBin)) {
		fs.chmodSync(wisprBin, 0o755);
		console.log('Launcher already named wispr-flow.');
	} else {
		throw new Error(`No 'electron' launcher found in ${destDir} after extraction.`);
	}

	console.log('Electron binary fetched, extracted, and renamed successfully.');
}

// Translate ELECTRON_MIRROR / ELECTRON_CUSTOM_DIR into @electron/get options.
function buildMirrorOptions(version) {
	const opts = {};
	if (process.env.ELECTRON_MIRROR) {
		opts.mirror = process.env.ELECTRON_MIRROR;
	}
	if (process.env.ELECTRON_CUSTOM_DIR) {
		opts.customDir = process.env.ELECTRON_CUSTOM_DIR;
	} else {
		opts.customDir = `v${version}`;
	}
	return opts;
}

main().catch((err) => {
	console.error(err && err.stack ? err.stack : err);
	process.exit(1);
});
