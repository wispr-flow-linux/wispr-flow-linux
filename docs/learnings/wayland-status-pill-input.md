[< Back to learnings](index.md)

# Wayland: the status pill's transparent window swallows clicks

A native-Wayland client cannot make part of its window click-through, so the
status pill's window (200x110) blocks hover and clicks over an area far larger
than the ~48x14 pill; the fix is to publish the pill's painted box in the window
title and let the GNOME extension clip the window to it.

```
renderer (linux-status-shape.js)  ->  document.title = "Status|x,y,w,h"
extension (wispr-flow-window-bridge) reads the title -> actor.set_clip(x,y,w,h)
```

## Symptom

An app or game behind the pill: its buttons under the pill's window do not
highlight and cannot be clicked, and a fullscreen game that loses focus to the
pill's window minimizes.

## What does not work

- Wispr's own approach: poll the pixel under the cursor and toggle
  `setIgnoreMouseEvents`. It has no effect on native Wayland.
- `BrowserWindow.setShape(rects)`. Electron 42 accepts the call, but the
  compositor's pointer pick at a point outside the rects still returns the
  window. Measured in an isolated headless GNOME Shell: before and after
  `setShape`, `global.stage.get_actor_at_pos()` at an empty point of the window
  returned the window both times.
- Resizing the window to the pill. It is `resizable:false`, so Mutter clamps it,
  and the hover UI (globe button, tooltip) needs the room.

## What works

`Clutter.Actor.set_clip()` on the window actor restricts both painting and
pointer picking to that rectangle. Points inside it hit the window; points
outside fall through to whatever is beneath. Removing the clip restores the old
behaviour. On the same GNOME 50.1 / mutter 18 test, the clip on the window actor
alone was enough.

The compositor cannot see the DOM, so the renderer tells it. The window title is
the one channel a Wayland client has to the compositor with no new protocol and
no preload/IPC change. The status page has no `<title>` and the app never reads
that window's title (the one `getTitle()` comparison is for the feature tour), so
it is free to carry the box.

## What "painted" means

It mirrors Wispr's own hit test, where any pixel with alpha > 0 captures input,
including its alpha `0.004` hit-area elements. The snippet takes the union of
visible, non-zero-size elements that have a background, image, shadow, border,
text or pseudo-element content, whose opacity chain is not ~0. The hidden state
variants (`visibility:hidden`) are excluded. While the pointer is over the pill,
the small containers in the `:hover` chain are included, so the pointer cannot
slip out through the gap between the pill and its hover-only UI.

Resting state, measured on the rendered page: the only pixels with alpha > 0 are
the 48x14 hit area at (76, 88), so the published box is `70,82,60,26` with the
6px pad; hovering grows it to `70,56,60,52` and it shrinks back afterwards.

## Fullscreen apps

The box still captures clicks over its own 60x26. While a fullscreen window is
showing on the pill's monitor, the extension also makes the window actor and all
its descendants non-reactive (on the actor alone, the surface child is still
picked), so even that area falls through.

## Testing without a second seat

Run a headless shell with its own D-Bus session and config so the real session is
untouched, load the extension, and probe with `global.stage.get_actor_at_pos()`:

```
XDG_RUNTIME_DIR=... XDG_CONFIG_HOME=... XDG_DATA_HOME=... GSETTINGS_BACKEND=keyfile \
  dbus-run-session -- gnome-shell --headless --wayland --no-x11 \
  --virtual-monitor 1280x720 --wayland-display=probe-wl --unsafe-mode
```

`setsid` children escape a process-group kill, and `pkill -f` matches its own
command line; kill test shells by exact PID after checking `/proc/<pid>/environ`.
