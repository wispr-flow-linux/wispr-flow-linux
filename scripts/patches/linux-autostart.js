/*WISPR_LINUX_AUTOSTART*/
// Injected at the top of .webpack/main/index.js by linux-autostart.sh.
// Electron's app.setLoginItemSettings / getLoginItemSettings are macOS and
// Windows only: on Linux the setter writes nothing and the getter reports
// wasOpenedAtLogin:false, so "Open at login" never starts the app and the
// Hub's "opened at login, stay hidden" branch never fires (issue #81).
//
// This replaces both methods on Linux with an XDG autostart entry, the way
// Anthropic's official Claude Desktop for Linux does it:
//   set({openAtLogin:true})  writes $XDG_CONFIG_HOME/autostart/wispr-flow.desktop
//                            with Exec=<launcher> --hidden
//   set({openAtLogin:false}) removes it
//   get()                    wasOpenedAtLogin = argv carries --hidden
// The launchers pass their arguments through to Electron, so --hidden
// reaches process.argv. The getter's other fields are Electron's own: the
// one upstream read on Linux is wasOpenedAtLogin, and the Settings toggle
// shows the saved preference, not the entry.
//
// The setter only touches an entry carrying the X-Wispr-Flow-Linux-Autostart
// marker, so a wispr-flow.desktop the user wrote is theirs to keep. The entry
// carries TryExec= naming the launcher, so desktops skip it once the package
// is removed or the AppImage deleted.
//
// The first get() in a process also repairs an entry this shim wrote whose
// TryExec= target is gone (an AppImage that moved, a package since removed):
// its Exec= and TryExec= lines are rewritten, nothing else. An entry whose
// target still exists is left alone, so a deb and an AppImage installed side
// by side do not take it in turns. Only the primary instance reaches get()
// (the Hub launch decision calls it; a second instance exits before that),
// so the repair never races.
;(function () {
	if (process.platform !== "linux") return;
	try {
		var app = require("electron").app;
		var fs = require("fs");
		var path = require("path");
		var os = require("os");
		if (!app) return;

		var configHome = process.env.XDG_CONFIG_HOME ||
			path.join(os.homedir(), ".config");
		var entry = path.join(configHome, "autostart", "wispr-flow.desktop");
		var OURS = "X-Wispr-Flow-Linux-Autostart=true";

		// The AppImage runtime exports APPIMAGE and APPDIR, and so does every
		// other AppImage, into everything started from it. A deb or rpm
		// launched from, say, an AppImage editor's terminal inherits them, so
		// APPIMAGE only counts when this Electron runs from inside APPDIR.
		var appImage = function () {
			var ai = process.env.APPIMAGE, dir = process.env.APPDIR;
			if (!ai || !dir) return null;
			try {
				var real = fs.realpathSync(dir) + path.sep;
				return fs.realpathSync(process.execPath).indexOf(real) === 0
					? ai : null;
			} catch (e) { return null; }
		};
		// Desktop Entry spec: a quoted Exec argument escapes " ` $ \ with a
		// backslash, then the string-value rule doubles every backslash, and
		// a literal % is written %%. TryExec is a plain string value.
		var quoteArg = function (s) {
			return ('"' + s.replace(/(["`$\\])/g, "\\$1") + '"')
				.replace(/\\/g, "\\\\")
				.replace(/%/g, "%%");
		};
		var escString = function (s) {
			return s.replace(/\\/g, "\\\\").replace(/\n/g, "\\n")
				.replace(/\t/g, "\\t").replace(/\r/g, "\\r");
		};
		var unescString = function (s) {
			var map = { s: " ", n: "\n", t: "\t", r: "\r", "\\": "\\" };
			return s.replace(/\\(.)/g, function (m, c) {
				return map[c] !== undefined ? map[c] : m;
			});
		};
		var execLines = function () {
			var ai = appImage();
			return [
				"Exec=" + (ai ? quoteArg(ai) : "wispr-flow") + " --hidden",
				"TryExec=" + escString(ai || "wispr-flow")
			];
		};
		// TryExec semantics: an absolute path must be executable, a bare
		// name is looked up in $PATH.
		var present = function (target) {
			var dirs = target.indexOf("/") !== -1 ? [""]
				: (process.env.PATH || "").split(":").filter(Boolean);
			return dirs.some(function (d) {
				try {
					fs.accessSync(d ? path.join(d, target) : target, fs.constants.X_OK);
					return true;
				} catch (e) { return false; }
			});
		};
		var read = function () {
			try { return fs.readFileSync(entry, "utf8"); } catch (e) { return null; }
		};
		var ours = function (text) {
			return text !== null && text.indexOf(OURS) !== -1;
		};
		var writeAtomic = function (text) {
			fs.mkdirSync(path.dirname(entry), { recursive: true });
			var tmp = entry + ".tmp-" + process.pid;
			fs.writeFileSync(tmp, text);
			fs.renameSync(tmp, entry);
		};
		var write = function () {
			writeAtomic([
				"[Desktop Entry]",
				"Type=Application",
				"Name=Wispr Flow"
			].concat(execLines(), [
				"Icon=wispr-flow",
				"Terminal=false",
				"X-GNOME-Autostart-enabled=true",
				OURS,
				""
			]).join("\n"));
		};

		var repaired = false;
		var repair = function () {
			if (repaired) return;
			repaired = true;
			try {
				var text = read();
				if (!ours(text)) return;
				var m = text.match(/^TryExec=(.*)$/m);
				if (m && present(unescString(m[1]))) return;
				var want = execLines();
				text = text.replace(/^TryExec=.*\n?/mg, "");
				text = /^Exec=.*$/m.test(text)
					? text.replace(/^Exec=.*$/m, function () { return want.join("\n"); })
					: text.replace(/\n?$/, "\n" + want.join("\n") + "\n");
				writeAtomic(text);
			} catch (e) {}
		};

		var origGet = typeof app.getLoginItemSettings === "function"
			? app.getLoginItemSettings.bind(app) : null;
		app.getLoginItemSettings = function (options) {
			repair();
			var base = {};
			try { base = (origGet && origGet(options)) || {}; } catch (e) {}
			return Object.assign({}, base, {
				wasOpenedAtLogin: process.argv.indexOf("--hidden") !== -1
			});
		};
		app.setLoginItemSettings = function (settings) {
			try {
				var text = read();
				if (text !== null && !ours(text)) return;
				if (settings && settings.openAtLogin) write();
				else if (text !== null) fs.rmSync(entry, { force: true });
			} catch (e) {}
		};
	} catch (e) {}
})();
