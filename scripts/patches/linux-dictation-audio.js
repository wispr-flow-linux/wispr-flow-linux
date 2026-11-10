"use strict";
/*WISPR_LINUX_DICTATION_AUDIO_RUNTIME*/

const { spawn, execFileSync } = require("node:child_process");
const readline = require("node:readline");

function report(error) {
	console.warn("[Wispr Flow audio]", error.message);
}

function run(command, args) {
	return execFileSync(command, args, {
		encoding: "utf8",
		timeout: 1000,
		killSignal: "SIGKILL",
		stdio: ["ignore", "pipe", "pipe"]
	}).trim();
}

function runWorker() {
	const mutedSinks = new Set();
	const pausedPlayers = new Set();
	let recording = false;

	function restore() {
		recording = false;
		for (const sink of mutedSinks) {
			try {
				run("pactl", ["set-sink-mute", sink, "0"]);
				mutedSinks.delete(sink);
			} catch (error) { report(error); }
		}
		for (const player of pausedPlayers) {
			try {
				if (run("playerctl", ["--player", player, "status"]) === "Paused") {
					run("playerctl", ["--player", player, "play"]);
				}
				pausedPlayers.delete(player);
			} catch (error) { report(error); }
		}
	}

	function start({ mute, pause }) {
		if (recording) return;
		// Retry any restoration that failed after the previous recording.
		restore();
		recording = true;
		if (pause) {
			const players = run("playerctl", ["--list-all"])
				.split("\n").filter(Boolean);
			for (const player of players) {
				try {
					if (run("playerctl", ["--player", player, "status"]) !== "Playing") {
						continue;
					}
					// A command can apply before its reply times out.
					pausedPlayers.add(player);
					run("playerctl", ["--player", player, "pause"]);
				} catch (error) { report(error); }
			}
		} else if (mute) {
			const sinks = JSON.parse(run("pactl", ["--format=json", "list", "sinks"]));
			if (!Array.isArray(sinks)) throw new Error("Invalid pactl sink list");
			for (const sink of sinks) {
				if (typeof sink?.name !== "string" || sink.mute !== false) continue;
				try {
					// A command can apply before its reply times out.
					mutedSinks.add(sink.name);
					run("pactl", ["set-sink-mute", sink.name, "1"]);
				} catch (error) { report(error); }
			}
		}
	}

	readline.createInterface({ input: process.stdin }).on("line", line => {
		try {
			const state = JSON.parse(line);
			if (state.recording === true) start(state);
			else restore();
		} catch (error) { report(error); }
	}).once("close", restore);
	for (const signal of ["SIGINT", "SIGTERM"]) {
		process.once(signal, () => {
			restore();
			process.exit();
		});
	}
}

let worker;

module.exports = function update(recording, prefs = {}) {
	if (!worker) {
		if (!recording || !(prefs.shouldMuteAudio || prefs.shouldPauseAudio)) return;
		const child = spawn(process.execPath, [__filename, "--worker"], {
			env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
			stdio: ["pipe", "ignore", "inherit"]
		});
		worker = child;
		child.on("error", report);
		child.stdin.on("error", report);
		child.once("close", () => { if (worker === child) worker = undefined; });
		child.unref();
		child.stdin.unref();
	}
	worker.stdin.write(JSON.stringify({
		recording: recording === true,
		mute: prefs.shouldMuteAudio === true,
		pause: prefs.shouldPauseAudio === true
	}) + "\n");
};

if (require.main === module && process.argv[2] === "--worker") runWorker();
