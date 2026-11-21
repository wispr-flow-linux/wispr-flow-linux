/*WISPR_LINUX_COSMIC_OVERLAY*/
const wisprLinuxCosmicOverlay = (() => {
	const env = process.env;
	if (process.platform !== 'linux' || !env.WAYLAND_DISPLAY ||
		!env.XDG_CURRENT_DESKTOP?.split(':').some(
			desktop => desktop.toLowerCase() === 'cosmic') ||
		env.WISPR_COSMIC_OVERLAY === '0' || env.WISPR_USE_X11 === '1') {
		return;
	}

	const { app } = require('electron');
	if (app.commandLine.getSwitchValue('ozone-platform') === 'x11') return;

	const { spawn } = require('node:child_process');
	const { join } = require('node:path');
	const { createInterface } = require('node:readline');
	const helper = join(process.resourcesPath, 'Release',
		'wispr-flow-linux-helper');

	let child;
	let timer;
	let target;
	let hidden;
	let deferredShow;
	let revision = 0;
	let failed = false;

	function restore() {
		const win = hidden;
		hidden = undefined;
		if (win && !win.isDestroyed() && !win.isVisible()) {
			win.showInactive();
		}
	}

	function end() {
		clearTimeout(timer);
		const previous = child;
		child = undefined;
		deferredShow = undefined;
		if (previous) {
			previous.stdin.end();
			previous.kill();
		}
	}

	function fallback(proc, reason) {
		if (child !== proc) return;
		const show = deferredShow;
		failed = true;
		end();
		if (show) {
			hidden = undefined;
			show();
		} else {
			restore();
		}
		console.warn('Wispr COSMIC overlay unavailable:', reason);
	}

	function launch() {
		// Older helpers exit via --version without starting keyboard capture.
		const proc = spawn(helper, ['--dictation-overlay', '--version'],
			{ stdio: ['pipe', 'pipe', 'inherit'] });
		child = proc;
		proc.on('error', error => fallback(proc, error.message));
		proc.stdin.on('error', error => fallback(proc, error.message));
		proc.on('close', code => fallback(proc, `helper exited (${code})`));
		createInterface({ input: proc.stdout }).on('line', line => {
			if (child !== proc) return;
			if (line === `${revision} lost`) {
				fallback(proc, 'compositor closed the surface');
			} else if (line === `${revision} shown`) {
				clearTimeout(timer);
				if (hidden && hidden !== target) restore();
				if (target && !target.isDestroyed() && target.isVisible()) {
					hidden = target;
					target.hide();
				}
			}
		});
		return proc;
	}

	app.once('before-quit', end);
	return {
		deferShow(show) {
			if (!child) return false;
			// The original dictation show runs before the first Wayland
			// frame. Replay it if the native overlay fails.
			deferredShow = show;
			return true;
		},
		update(status, win) {
			const phase = {
				initializing: 'starting',
				listening: 'listening',
				stopping: 'processing',
				processing: 'processing',
				retrying: 'processing',
			}[status];
			if (!phase) {
				end();
				// Wispr decides when to show its status window for the
				// next dictation or notification. Ending ours should not
				// map an ordinary Electron window over the target app.
				hidden = undefined;
				target = undefined;
				failed = false;
				return;
			}
			if (failed) return;
			try {
				target = win;
				const proc = child || launch();
				clearTimeout(timer);
				timer = setTimeout(() => fallback(proc,
					'no compositor response'), 750);
				timer.unref();
				proc.stdin.write(`${++revision} ${phase}\n`);
			} catch (error) {
				fallback(child, error.message);
			}
		},
	};
})();
