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
//   get()                    openAtLogin = the entry exists and is not
//                            disabled (Hidden=true or
//                            X-GNOME-Autostart-enabled=false);
//                            wasOpenedAtLogin = argv carries --hidden
// The launchers pass their arguments through to Electron, so --hidden
// reaches process.argv.
//
// The first get() in a process also does two once-per-launch chores. Only
// the primary instance reaches it (the Hub launch decision calls it; a
// second instance exits before that), so these never race:
//   - repair: an entry this shim wrote whose Exec= no longer matches (an
//     AppImage that moved) gets its Exec= line rewritten, nothing else;
//   - sync: once per profile, when the saved preference says open at login
//     is on and no entry exists, write it. Upstream defaults the preference
//     to on and its new-user hook calls set() only for brand-new profiles,
//     so without this an existing profile would show the toggle on with
//     nothing behind it. A marker file in the config dir keeps it to one
//     attempt, so an entry the user later removes stays removed.
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
		var appDir = path.join(configHome, "Wispr Flow");
		var syncMark = path.join(appDir, ".linux-autostart-synced");
		var OURS = "X-Wispr-Flow-Linux-Autostart=true";

		// Desktop Entry spec: a quoted Exec argument escapes " ` $ \ with a
		// backslash, then the string-value rule doubles every backslash, and
		// a literal % is written %%.
		var quoteArg = function (s) {
			return ('"' + s.replace(/(["`$\\])/g, "\\$1") + '"')
				.replace(/\\/g, "\\\\")
				.replace(/%/g, "%%");
		};
		var execLine = function () {
			var cmd = process.env.APPIMAGE
				? quoteArg(process.env.APPIMAGE)
				: "wispr-flow";
			return "Exec=" + cmd + " --hidden";
		};
		var read = function () {
			try { return fs.readFileSync(entry, "utf8"); } catch (e) { return null; }
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
				"Name=Wispr Flow",
				execLine(),
				"Icon=wispr-flow",
				"Terminal=false",
				"X-GNOME-Autostart-enabled=true",
				OURS,
				""
			].join("\n"));
		};
		var enabled = function () {
			var text = read();
			return text !== null &&
				!/^Hidden=true\s*$/m.test(text) &&
				!/^X-GNOME-Autostart-enabled=false\s*$/m.test(text);
		};
		var prefOn = function () {
			try {
				var cfg = JSON.parse(
					fs.readFileSync(path.join(appDir, "config.json"), "utf8"));
				return !!(cfg && cfg.prefs && cfg.prefs.user &&
					cfg.prefs.user.openAtLogin === true);
			} catch (e) { return false; }
		};

		var choresDone = false;
		var chores = function () {
			if (choresDone) return;
			choresDone = true;
			try {
				var text = read();
				if (text !== null && text.indexOf(OURS) !== -1) {
					var want = execLine();
					var m = text.match(/^Exec=.*$/m);
					if (!m || m[0] !== want) {
						writeAtomic(m ? text.replace(/^Exec=.*$/m, function () { return want; })
							: text.replace(/\n?$/, "\n" + want + "\n"));
					}
				}
			} catch (e) {}
			try {
				if (!fs.existsSync(syncMark)) {
					fs.mkdirSync(appDir, { recursive: true });
					fs.writeFileSync(syncMark, "");
					if (read() === null && prefOn()) write();
				}
			} catch (e) {}
		};

		var origGet = typeof app.getLoginItemSettings === "function"
			? app.getLoginItemSettings.bind(app) : null;
		app.getLoginItemSettings = function (options) {
			chores();
			var base = {};
			try { base = (origGet && origGet(options)) || {}; } catch (e) {}
			var on = enabled();
			return Object.assign({}, base, {
				openAtLogin: on,
				executableWillLaunchAtLogin: on,
				wasOpenedAtLogin: process.argv.indexOf("--hidden") !== -1
			});
		};
		app.setLoginItemSettings = function (settings) {
			try {
				if (settings && settings.openAtLogin) write();
				else fs.rmSync(entry, { force: true });
			} catch (e) {}
		};
	} catch (e) {}
})();
