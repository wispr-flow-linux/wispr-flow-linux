/*WISPR_LINUX_STATUS_IDLE_UNMAP*/
// Injected at the top of .webpack/main/index.js by linux-status-idle-unmap.sh.
//
// The bar can be visually hidden while its transparent native window remains
// mapped. In a GNOME/XWayland reproduction, physical clicks failed even where
// X11 reported an empty input region. Unmapping Status restored clicks;
// remapping it brought the dead zone back (refs #71, #76).
//
// This shim does not touch how Wispr decides to show or hide the pill. It
// wraps the Status window's show/showInactive/hide so the native intent is
// remembered (`wanted`) and reconciles the *actual* visibility against the
// renderer's semantic surface report: the window is mapped only while Wispr
// wants it shown AND the renderer reports a live visual surface (the
// recording indicator, a notification, ...). Idle => wanted but no surface
// => the window is genuinely unmapped, so its input shape goes with it and
// dead-spot scrolling works again.
//
// The surface report arrives on upstream's own status:reportAlphaCatchRects
// channel (the same one main already consumes for click-through input
// shape); linux-status-surface-report.sh enables visual-only surfaces on Linux
// and forces an initial report even when all rectangle maps start empty.
// Reports are trusted only from the Status window's own
// main frame loaded from renderer/status/index.html, with well-formed
// rectangle lists and a viewport that matches the window's current content
// bounds at its zoom factor -- a stale report from mid-resize can never hide
// a recording indicator.
//
// backgroundThrottling is disabled on the window's webContents so the
// hidden renderer stays responsive to dictation IPC and React effects
// (upstream already sets backgroundThrottling:!1 in the window's
// webPreferences; this keeps it pinned across any runtime re-enable).
;(function () {
	if (process.platform !== "linux") return;
	const {app, BrowserWindow, ipcMain} = require("electron");
	const states = new WeakMap();
	const channel = "status:reportAlphaCatchRects";

	function attach(win) {
		if (win.getTitle() !== "Flow Status Indicator") return;
		const original = {
			show: win.show.bind(win),
			showInactive: win.showInactive.bind(win),
			hide: win.hide.bind(win),
		};
		const state = {wanted: win.isVisible(), surface: false, logged: null};
		states.set(win, state);
		function reconcile() {
			if (win.isDestroyed()) return;
			const visible = state.wanted && state.surface;
			if (visible && !win.isVisible()) original.showInactive();
			if (!visible && win.isVisible()) original.hide();
			if (state.logged !== visible) {
				console.info("[StatusVisibility] " + (visible ? "shown" : "hidden"));
				state.logged = visible;
			}
		}
		state.reconcile = reconcile;
		win.show = function (...args) {
			state.wanted = true;
			if (state.surface) return original.show(...args);
			reconcile();
		};
		win.showInactive = function (...args) {
			state.wanted = true;
			if (state.surface) return original.showInactive(...args);
			reconcile();
		};
		win.hide = function (...args) {
			state.wanted = false;
			return original.hide(...args);
		};
		win.webContents.on("did-start-loading", () => {
			state.surface = false;
			reconcile();
		});
		win.webContents.on("render-process-gone", () => {
			state.surface = false;
			reconcile();
		});
		// Keep a hidden renderer responsive to dictation IPC and React effects.
		win.webContents.setBackgroundThrottling(false);
		reconcile();
	}

	function rectangles(value) {
		return Array.isArray(value) && value.length <= 512 && value.every(r =>
			r && typeof r === "object" && ["x", "y", "width", "height"].every(k =>
				typeof r[k] === "number" && Number.isFinite(r[k])));
	}
	ipcMain.on(channel, (event, report) => {
		const win = BrowserWindow.fromWebContents(event.sender);
		const state = win && states.get(win);
		if (!state || win.isDestroyed() || event.senderFrame !== event.sender.mainFrame) return;
		let url;
		try { url = new URL(event.sender.getURL()); } catch { return; }
		if (url.protocol !== "file:" || !url.pathname.endsWith("/renderer/status/index.html")) return;
		if (!report || !rectangles(report.rects) || !rectangles(report.shapeRects)) return;
		const viewport = report.viewport;
		if (!viewport || !Number.isFinite(viewport.width) || !Number.isFinite(viewport.height) ||
			viewport.width <= 0 || viewport.height <= 0) return;
		const bounds = win.getContentBounds();
		// Ignore a stale report during resize/monitor movement; never hide a
		// recording indicator based on rectangles from a different viewport.
		const zoom = win.webContents.getZoomFactor();
		if (Math.abs(bounds.width - viewport.width * zoom) > 2 ||
			Math.abs(bounds.height - viewport.height * zoom) > 2) return;
		const intersects = r => r.width > 0 && r.height > 0 &&
			r.x < viewport.width && r.y < viewport.height && r.x + r.width > 0 && r.y + r.height > 0;
		state.surface = report.rects.some(intersects) || report.shapeRects.some(intersects);
		state.reconcile();
	});
	app.on("browser-window-created", (_event, win) => attach(win));
})();
