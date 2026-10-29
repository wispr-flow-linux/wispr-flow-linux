/*WISPR_LINUX_STATUS_INPUT*/
// Injected at the top of .webpack/main/index.js by linux-status-input.sh.
//
// The Status window is created click-through on Linux
// (`setIgnoreMouseEvents(true, {forward:true})`). Its own controls -- the
// pill's stop button and notification card buttons -- then receive no clicks
// until the 400 ms alpha hit-test poll re-enables input, and that poll is
// fragile outside dictation. This shim forces input while the renderer
// reports a visible surface (status:reportAlphaCatchRects) or while a
// notification is shown (notification:show), and restores click-through when
// both are gone. It does not change the window size or the pill.
;(function () {
	if (process.platform !== "linux") return;
	const {app, BrowserWindow, ipcMain} = require("electron");
	const REPORT = "status:reportAlphaCatchRects";
	const SHOW = "notification:show";
	const CLEAR = "notification:clear";
	const states = new WeakMap();

	function attach(win) {
		if (win.getTitle() !== "Flow Status Indicator") return;
		const state = {active: false, surface: false};
		states.set(win, state);
		const setIgnore = win.setIgnoreMouseEvents.bind(win);
		win.setIgnoreMouseEvents = function (ignore, options) {
			if (state.active || state.surface) ignore = false;
			return setIgnore(ignore, options);
		};
		const send = win.webContents.send.bind(win.webContents);
		win.webContents.send = function (channel, ...args) {
			if (channel === SHOW) {
				state.active = true;
				win.setIgnoreMouseEvents(false);
			}
			const result = send(channel, ...args);
			if (channel === CLEAR && state.active) {
				state.active = false;
				win.setIgnoreMouseEvents(!state.surface, {forward: true});
			}
			return result;
		};
	}

	ipcMain.on(REPORT, (event, report) => {
		const win = BrowserWindow.fromWebContents(event.sender);
		const state = win && states.get(win);
		if (!state || !report) return;
		const rects = Array.isArray(report.rects) ? report.rects : [];
		const shapes = Array.isArray(report.shapeRects) ? report.shapeRects : [];
		state.surface = rects.length > 0 || shapes.length > 0;
		win.setIgnoreMouseEvents(!state.surface && !state.active, {forward: true});
	});

	app.on("browser-window-created", (_event, win) => attach(win));
})();
