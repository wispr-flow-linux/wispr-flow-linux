// Real-Electron lifecycle regression for the Linux idle Status window unmap
// (issues #76 and #71). Exercises scripts/patches/linux-status-idle-unmap.js
// exactly as the patched main bundle loads it, in real Electron/XWayland
// windows, and asserts both the Electron-visible state (win.isVisible()) and
// the physical X map state (xwininfo Map State) of the Status window.
//
// Launched by tests/status-visibility.sh, which shadows a packaged Electron
// runtime with an isolated resources/app and an isolated user profile. It
// must run under that wrapper, not node: it needs the Electron binary.
// No microphone permission is requested and no synthetic input is injected;
// every state change below is driven by the renderer's own
// status:reportAlphaCatchRects IPC report, the channel upstream's main
// process already consumes, widened for Linux by
// scripts/patches/linux-status-surface-report.sh.
const {app, BrowserWindow} = require('electron');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'wispr-visibility-test-'));
app.setPath('userData', path.join(tmp, 'profile'));
require('./linux-status-idle-unmap.js');
const directory = path.join(tmp, 'renderer', 'status');
fs.mkdirSync(directory, {recursive: true});
fs.writeFileSync(path.join(directory, 'index.html'), '<!doctype html><title>Status</title><body>Visibility regression</body>');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
function mapped(win) {
    const id = '0x' + win.getNativeWindowHandle().readUInt32LE().toString(16);
    return /Map State: IsViewable/.test(execFileSync('xwininfo', ['-id', id], {encoding: 'utf8'}));
}
function expectVisibility(win, expected, label) {
    assert.equal(win.isVisible(), expected, label + ' (Electron)');
    assert.equal(mapped(win), expected, label + ' (XWayland)');
    console.log('PASS: ' + label);
}
async function report(win, rects, shapes = [], viewport) {
    // Actual renderer -> Electron IPC with authentic sender/frame/url.
    await win.webContents.executeJavaScript(`require('electron').ipcRenderer.send('status:reportAlphaCatchRects', {
        rects: ${JSON.stringify(rects)}, shapeRects: ${JSON.stringify(shapes)},
        viewport: ${viewport ? JSON.stringify(viewport) : '{width:innerWidth,height:innerHeight}'}
    })`);
    await pause(150);
}
async function create() {
    const win = new BrowserWindow({title: 'Flow Status Indicator', show: false,
        width: 512, height: 586, x: -5000, y: -5000, transparent: true,
        frame: false, focusable: false, skipTaskbar: true,
        webPreferences: {nodeIntegration: true, contextIsolation: false, backgroundThrottling: false}});
    await win.loadFile(path.join(directory, 'index.html'));
    win.webContents.setZoomFactor(1);
    await pause(100);
    return win;
}
app.whenReady().then(async () => {
    const rect = {x: 200, y: 540, width: 100, height: 30};
    let win = await create();
    win.showInactive();
    await report(win, []);
    expectVisibility(win, false, 'idle window is physically unmapped');
    await report(win, [rect]);
    expectVisibility(win, true, 'recording surface maps without focus');
    await report(win, [], [], {width: 1, height: 1});
    expectVisibility(win, true, 'stale viewport cannot hide a recording');
    await report(win, [{...rect, x: 'bad'}]);
    expectVisibility(win, true, 'malformed renderer data is ignored');
    await report(win, [], [rect]);
    expectVisibility(win, true, 'visual-only status surface stays mapped');
    await report(win, []);
    expectVisibility(win, false, 'recording completion returns to unmapped idle');
    win.hide();
    await report(win, [rect]);
    expectVisibility(win, false, 'upstream hide intent is not overridden');
    win.showInactive();
    await pause(100);
    expectVisibility(win, true, 'upstream show restores a visible surface');
    win.webContents.setZoomFactor(1.25);
    await pause(100);
    await report(win, []);
    expectVisibility(win, false, 'zoomed empty report still unmaps');
    await report(win, [{x: 20, y: 20, width: 50, height: 20}]);
    expectVisibility(win, true, 'hidden zoomed renderer can report and remap');
    win.destroy();
    win = await create();
    win.showInactive();
    await report(win, []);
    expectVisibility(win, false, 'recreated Status window starts safely hidden');
    await report(win, [rect]);
    expectVisibility(win, true, 'recreated Status window can record');
    win.destroy();
    console.log('Visibility regression complete');
    app.exit(0);
}).catch(error => { console.error(error); app.exit(1); });
app.on('window-all-closed', () => {});
app.on('will-quit', () => fs.rmSync(tmp, {recursive: true, force: true}));
