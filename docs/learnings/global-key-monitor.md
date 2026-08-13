[< Back to learnings](index.md)

# Global key monitor — push-to-talk lives in the helper, not the app

Hey! Here's something I had to learn the hard way: push-to-talk and the in-app
shortcut recorder stay dead until the helper streams key events to the app.
That's because **Wispr Flow has no hotkey detection of its own**. Its
"Keyboard Service" is fed entirely by `KeypressEvent` IPC frames from the
helper. On macOS/Windows the Swift/C# helpers supply them via OS-level key
hooks. The Linux helper originally shipped only text injection / focus /
clipboard, so the event stream was missing and every hotkey was silently dead.

(A correction to an earlier version of this page: the Keyboard Service —
chord matching and action dispatch — lives in the **main process**
(`.webpack/main/index.js`), not a renderer. The hub renderer only hosts the
shortcut-recorder UI, which main feeds via the `Shortcut` IPC while
`isRecordingKeybind` is set. This matters when you're deciding whether a
dead window can kill PTT: it can't — only a dead event stream or main-process
state can.)

**Source files** (in the [`wispr-flow-linux/helper`](https://github.com/wispr-flow-linux/helper) repo):

- [`src/capture/mod.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/capture/mod.rs) — backend selection, shared `KeypressEvent` emit, `HeldKeys` trait
- [`src/capture/evdev.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/capture/evdev.rs) — `/dev/input` reader (Wayland + X11 fallback)
- [`src/capture/xinput.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/capture/xinput.rs) — XInput2 raw-key reader (true X11, no device access)
- [`src/keymap.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/keymap.rs) — `evdev_to_vk` (inverse of `vk_to_evdev`)
- [`src/main.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/main.rs) — capture spawn + `CheckStaleKeys` handler
- [`reference/ipc-contract.md`](../reference/ipc-contract.md) — `KeypressEvent` shape (§5), VK codes (§6)

## The key realization

The app's keyboard service (in `index.js`) takes
`{eventType, key, index, inputType}` events from the helper. It does one of two
things with them. It either matches them against `prefs.user.shortcuts` (firing
push-to-talk), or — when `isRecordingKeybind` is set — forwards the held keys to
the settings window as the `Shortcut` IPC. **Both paths are the same event
stream.** So when I saw two broken features, I was really looking at one bug. No
`KeypressEvent` means push-to-talk never fires *and* the shortcut recorder shows
nothing and captures no input. The two symptoms have one cause.

## Two capture backends (selected like `backend::detect`)

Linux has no single portable userspace global-hotkey API. So the helper picks
per session, and the choice trades device-access requirements against coverage:

- **XInput2 (true X11).** Select `XI_RawKeyPress`/`RawKeyRelease` on the root
  window: global, no grab, and crucially **no device access** — just an X
  connection. This makes the entire X11 desktop population zero-config. It's
  gated on a *true* X11 session. Under XWayland, raw events only cover XWayland
  surfaces, so it must not be used on Wayland (`DISPLAY` set **and**
  `WAYLAND_DISPLAY` unset).
- **evdev (`/dev/input/event*`).** This is the session-agnostic fallback. Read
  raw events from the kernel input layer, which sits **below** the display server
  and behaves identically on Wayland and X11 (the read-side mirror of the
  [uinput injection](wayland-injection.md) write path). The catch is it needs
  read access to the input devices — and it must **keep watching `/dev/input`
  for hotplug**: a start-once enumeration silently decays to watching nothing
  as devices churn, killing PTT hours into a session. That failure and its fix
  get their own page: [evdev-hotplug-decay.md](evdev-hotplug-decay.md).

Here's the part I really liked. XInput2 raw `detail` is the X keycode, which on
Linux is the evdev code **+ 8**. Subtract 8 and both backends feed the *same*
`evdev_to_vk` table and the *same* emit path. They converge on identical VK
codes, so the app behaves the same either way. Stale-key queries mirror this:
evdev uses `EVIOCGKEY`, XInput2 uses core-X `QueryKeymap` (also no device
access).

## Details that matter

- **VK codes, not evdev codes.** The app's keycode constants are Windows
  Virtual-Key codes on non-mac (`isMac` is the only platform branch). And they
  are **left/right-specific**: left Ctrl = 162, left Shift = 160, left Alt = 164,
  left Meta/Win = 91. The default push-to-talk chord (Ctrl+Meta) is stored with
  these codes. So the monitor must translate each physical key with
  `keymap::evdev_to_vk` — the exact inverse of `vk_to_evdev`. A roundtrip test
  pins the two tables together. If they drift, matching silently breaks.
- **The `index` field is a monotonic sequence.** The app cross-checks each
  event's `index` against its own running counter and warns on a gap. That's why
  the capture path shares one `AtomicU64` across all reader threads.
- **Auto-repeat is dropped.** evdev `value == 2` is key auto-repeat; only press
  (1) and release (0) are emitted.
- **`CheckStaleKeys` is answered from physical state.** The app polls ~every 5 s
  with the keycodes it thinks are held. The helper replies with the subset that
  is *not* currently held (queried via `EVIOCGKEY` across all devices), so a key
  stuck by a missed release or an unplugged device gets recovered. I answer from
  the live kernel bitmap, not a tracked set, and that's what makes it
  self-healing.
- **Keyboards are filtered by capability.** Only `/dev/input/event*` nodes whose
  `EVIOCGBIT(EV_KEY)` advertises letter keys (KEY_A..KEY_Z) are watched, so mice
  and touchpads don't spawn reader threads.

## The requirement that bites (evdev only)

The evdev path needs read access to `/dev/input/event*`: the logind `uaccess`
ACL (granted to the active session on most desktops) **or** membership in the
`input` group. Default distro policy usually does *not* grant users blanket
evdev read, because it's a keylogging surface. So you have to provision it. The
XInput2 path sidesteps the whole thing, which is why I prefer it on X11.

Here's how the project removes the friction:

- **deb / rpm / Nix** ship a udev rule (`TAG+="uaccess"`, `input` group + `0660`
  fallback) covering *both* `/dev/uinput` write and `/dev/input/event*` read. The
  post-install runs `udevadm reload`/`trigger`, so it's zero-touch.
- **AppImage / non-NixOS Nix** can't run a root hook. So the launcher offers
  `wispr-flow --install-udev-rules` (pkexec/sudo) to install the same rule in one
  step.
- `wispr-flow --doctor` checks `/dev/input` readability under **Push-to-Talk
  (input monitor)** and points you at the fix.

There's a security trade-off here: evdev read means keystrokes are visible to
the logged-in user. I documented that in
[`SECURITY.md`](../../SECURITY.md#input-device-access-by-design).
