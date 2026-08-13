[< Back to docs index](../index.md)

# Learnings — subsystem deep-dives

Hey! This is the stuff I learned the hard way building the Wispr Flow Linux
helper and packaging pipeline — the things that aren't obvious from the code,
the ones that cost me a day before they clicked. Each page digs into one
non-obvious mechanic and the failure modes that bit me. If you're about to touch
one of these subsystems, read its page first. I wish I had.

| Deep-dive | What it covers |
|---|---|
| [KWin / zbus / tokio](kwin-zbus-tokio.md) | The async-zbus-on-tokio dispatch deadlock that left KDE active-app empty, and the fix. |
| [GNOME Shell extension](gnome-shell-extension.md) | Install, the relogin requirement, the MRU focus fallback, and the Introspect pivot. |
| [Electron 42 / V8 14.8 / sqlite](electron42-v8-sqlite.md) | The V8 14.8 ABI patch that lets `better-sqlite3-multiple-ciphers` compile. |
| [The isPackaged / launcher rename](ispackaged-rename.md) | Why an `electron`-named launcher silently breaks DB migrations ("no such table"). |
| [Wayland injection](wayland-injection.md) | In-process `/dev/uinput` virtual keyboard + `ext-data-control` clipboard. |
| [Global key monitor](global-key-monitor.md) | Push-to-talk lives in the helper: XInput2 (X11) / evdev (Wayland) → `KeypressEvent`, and why both PTT and the shortcut recorder were dead without it. |
| [evdev hotplug decay](evdev-hotplug-decay.md) | Enumerate-once capture decays to watching nothing as `/dev/input` churns — PTT dies hours into a session with doctor green; the hotplug fix, the liveness probe, and the log-spam patch that stopped destroying the evidence. |
| [Helper spawn env](helper-spawn-env.md) | The app spawns the helper with a replacement env (no `process.env`), starving it of `WAYLAND_DISPLAY`/`DISPLAY` → silent no-op `stub` injector; recording works, injection doesn't. |
| [Platform gates](platform-gates.md) | The darwin/win32 carve-outs Linux falls through: the `.linux`-matches-no-CSS bug behind the shifted side menu, the three gate-shape rules, and how to re-audit a new Wispr version. |
| [Patching minified JS](patching-minified-js.md) | Rules for patches that survive re-minification: `[\w$]+` for identifiers, anchor on developer strings, assert the match count, marker-based idempotency, verify against shipped bytes. |
| [APT/DNF + redirect Worker](apt-worker-architecture.md) | How packages reach users: metadata on `gh-pages`, binaries served by a Cloudflare Worker 302-redirecting to Release assets, and the heartbeat that watches the chain. |

Want the "why this and not that" behind these — what I picked, and what I
turned down? That all lives in [decisions.md](../decisions.md).
