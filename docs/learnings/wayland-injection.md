[< Back to learnings](index.md)

# Wayland injection — uinput + ext-data-control clipboard

Hey! Typing transcribed text into whatever app you've got focused is the entire
reason this product exists. And on Wayland, that turned out to be the genuinely
hard part — there's no XTEST equivalent that reaches native surfaces, so the
obvious trick just doesn't work. I had to go under the display server entirely:
the helper injects at the **kernel input layer** through an in-process
`/dev/uinput` virtual keyboard, and it owns the clipboard via the focus-free
`ext_data_control` protocol. This is the piece the whole port hinges on. The
good news — it's live-validated.

**Source files** (in the [`wispr-flow-linux/helper`](https://github.com/wispr-flow-linux/helper) repo):

- [`src/backend/wayland.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/backend/wayland.rs) — the Wayland backend
- [`src/backend/uinput.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/backend/uinput.rs) — the virtual keyboard
- [`src/backend/wl_clipboard.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/backend/wl_clipboard.rs) — `ext-data-control` clipboard owner

## The key realization

Here's the thing that unlocked all of it: stop fighting Wayland, and inject
**below** the compositor. The helper creates an in-process `/dev/uinput` virtual
keyboard and writes evdev key events; libinput → compositor then routes them to
the focused surface exactly like they came off a real keyboard. It's the same
move `ydotool` makes — except **in-process, with no `ydotoold` daemon and no
root**. See
[D-002](../decisions.md#d-002--in-process-devuinput-virtual-keyboard).

All it asks for is **write access to `/dev/uinput`**. The active-session user
gets that from the logind `uaccess` udev rule (an ACL `user:<you>:rw-`), and the
`input` group is there as a cross-distro fallback when that rule doesn't fire.
See
[configuration.md](../configuration.md#text-injection-devuinput-access).

## uinput details that matter

I drive this with raw `libc` ioctls — no extra C deps, which keeps the
single-static-binary property I care about. Here's the sequence I landed on:

1. Open `/dev/uinput` `O_WRONLY|O_NONBLOCK`.
2. `UI_SET_EVBIT(EV_KEY / EV_SYN)`; `UI_SET_KEYBIT` over the standard key range.
3. Write a legacy `uinput_user_dev`, then `UI_DEV_CREATE`.
4. **Wait ~200 ms** so the compositor enumerates the device before the first
   event — injecting earlier drops keys.
5. `input_event` writes for press/release, each followed by `SYN_REPORT`.
6. `UI_DEV_DESTROY` on drop.

ioctl encodings (x86_64): `UI_DEV_CREATE=0x5501`, `UI_DEV_DESTROY=0x5502`,
`UI_SET_EVBIT=0x40045564`, `UI_SET_KEYBIT=0x40045565`.

## The chord trap: NO delay between modifier-down and key-down

That device-creation wait in step 4 is the *only* place a sleep belongs.
**Inside a chord, do not sleep between the modifier press and the key press.**
On KWin/Wayland, a quiescent gap after a virtual modifier-down makes the
compositor drop the modifier before the key lands — so an injected `Ctrl+V`
quietly degrades to a bare `v`. The mic records, the clipboard is set, the
keystroke fires, and the user just watches a lone `v` show up in their field.
This burned me because it's the exact opposite of the usual "give the compositor
time to latch the modifier" intuition.

I measured this on Plasma 6 / KWin Wayland with a GTK Wayland client watching the
`key-press-event` modifier state for the injected `v`:

| modifier→key gap | `v` arrives with Control? |
|---|---|
| **0 ms** | **yes** — `Ctrl+V`, full clipboard text pastes (5/5) |
| 8 ms (old code) | no — bare `v` |
| 50 ms / 200 ms | no — bare `v` |

So `UInput::chord` now fires modifier-down → key-down → key-up → modifier-up as
one contiguous batch — each event still followed by its own `SYN_REPORT`, just
no `thread::sleep` wedged between them. What made this nasty to track down: the
regression stayed hidden until input-read access got provisioned for
push-to-talk. The held-modifier dance was a no-op before `/dev/input` was
readable, and the chord had originally been validated back when the gap just
happened to be tolerated. Want to reproduce it? Wire up a GTK entry logging
`ev.state & CONTROL_MASK` and a uinput injector that varies the gap.

## Keycodes

`SimulateKeyPress.keycode` comes in numeric, and the renderer's only platform
branch is `isMac`. Which means **Linux falls straight into the Windows branch and
gets Windows Virtual-Key codes** (`enter=13`, `a..z=65..90`) — not what you'd
guess. So the helper maps VK → evdev `KEY_*` (`keymap::vk_to_evdev`). The
modifier `flags` arrive as names (`"Control"/"Shift"/"Alt"`), and non-mac uses
`"Control"`. The full table lives in
[`reference/keycodes.json`](../reference/keycodes.json).

## Held-modifier snapshot/release

Right before a chord, the helper sweeps every readable `/dev/input/event*` with
`EVIOCGKEY`, releases any modifier the user is physically holding, runs the
chord, then restores it afterward — that way a Shift you happen to be leaning on
doesn't corrupt the injected keys. When `/dev/input` isn't readable (no `input`
group / uaccess ACL) it's just a no-op, degrading cleanly. One honest caveat:
clearing a modifier held on *another* device through the virtual device leans on
the compositor's shared seat xkb-state, so it's compositor-dependent.

## Clipboard via ext-data-control (paste path)

`PasteText` goes through the clipboard, not per-character typing (see
[D-003](../decisions.md#d-003--clipboard-based-paste-not-per-character-typing)).
The helper runs an in-process `ext_data_control_manager_v1` source that
advertises **both `text/plain` and `text/html`** from a single owner — that
replaced an earlier `wl-copy` shell-out, which I kept around as a plain-text
fallback — then synths a uinput Ctrl+V chord. `ext_data_control` is the
focus-free clipboard protocol; KWin advertises it as `ext_data_control_manager_v1`
v1.

Every `set` spawns a detached thread that owns a Wayland connection and serves
paste requests, sticking around until the compositor cancels the source — that's
either the next `set`, or another app grabbing the clipboard out from under it.

> [!NOTE]
> **Gotcha:** the data-control *device* receives `data_offer` child-creating
> events, so `wayland-client` needs an `event_created_child!` specialization or
> it panics.

## detect() ordering

The order: prefer Wayland when `$WAYLAND_DISPLAY` is **set and non-empty** *and*
uinput is usable; otherwise X11 (`$DISPLAY`); otherwise stub. Two traps caught me
here:

- An **empty** `WAYLAND_DISPLAY` has to be treated as unset. `var_os(...).is_some()`
  comes back `true` even for an empty value, which would wrongly pick Wayland on a
  pure-X11 host (that's VM-sweep bug #7). So the helper's `env_set()` treats empty
  as unset for both `WAYLAND_DISPLAY` and `DISPLAY`.
- On a Wayland session, XWayland also sets `$DISPLAY` — but the X11 backend is
  blind there. XTEST doesn't reach native Wayland windows, and `_NET_CLIENT_LIST`
  comes back empty.

## Clipboard reads can hang

`wl-paste` can block on compositors that don't have `ext`/`wlr-data-control`
(mutter, looking at you). The single-threaded helper would just freeze solid, so
`run_capture` spawns a reader thread and kills the child after a 1.5 s timeout
(VM-sweep bug #6).

## References

- [configuration.md](../configuration.md#text-injection-devuinput-access),
  [decisions.md D-002](../decisions.md#d-002--in-process-devuinput-virtual-keyboard) /
  [D-003](../decisions.md#d-003--clipboard-based-paste-not-per-character-typing).
