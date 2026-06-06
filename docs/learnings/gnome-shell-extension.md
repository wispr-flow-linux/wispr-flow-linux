[< Back to learnings](index.md)

# GNOME Shell extension — active-app bridge

Hey! On GNOME, active-app identity, the running-apps list, and focus events all
come from a bundled GNOME Shell extension that bridges
`org.gnome.Shell.Introspect`. Two things here bit me and aren't obvious from the
code. The extension only loads after a **relogin**. And my original plan was to
read the Introspect D-Bus API directly, but that hit an `AccessDenied` and forced
the pivot to an extension.

**Source files** (in the [`wispr-flow-linux/helper`](https://github.com/wispr-flow-linux/helper) repo):

- [`src/backend/gnome.rs`](https://github.com/wispr-flow-linux/helper/blob/main/src/backend/gnome.rs) — the GNOME backend decorator
- [`src/backend/gnome_extension/`](https://github.com/wispr-flow-linux/helper/tree/main/src/backend/gnome_extension) — `extension.js`, `metadata.json` (the bundled extension)

## Overview

The `GnomeBackend` is a decorator over the shared Wayland backend. Injection,
clipboard, and selection still go through uinput / `ext-data-control` / AT-SPI.
Only three things are GNOME-specific: **active-app identity, running-apps, and
`AppInfoUpdate` focus events**. `detect()` routes GNOME via `is_gnome()`
(`contains("GNOME")`, so it handles Ubuntu's `ubuntu:GNOME` too).

The extension UUID is `wispr-flow-window-bridge@wispr.flow`, and it has to match
`gnome_extension/metadata.json`. `--doctor` checks that, and it hides the GNOME
section entirely when you're not on GNOME.

## Why an extension and not the raw Introspect API

`org.gnome.Shell.Introspect` (`GetWindows` / `GetRunningApps` /
`WindowsChanged`) is exactly the data the helper needs. But I found that calling
it directly from an unprivileged process can return **AccessDenied**. GNOME
restricts the Introspect API. So I bundled a Shell extension instead. It runs
inside the Shell's own process and re-exposes the data over a private interface,
which sidesteps the restriction. That's why this is a GNOME extension and not a
direct D-Bus client.

## The relogin requirement

> [!IMPORTANT]
> **GNOME scans extensions only at session start.** A freshly installed
> extension does not load until the user logs out and back in.

I had to learn this the hard way. The first run after install falls back to
AT-SPI for active-app data and logs a "log out and back in" notice. After the
relogin, the bridge is persistent. Packaging bundles the extension plus a
first-run relogin prompt. You can check and enable it like this:

```bash
gnome-extensions info wispr-flow-window-bridge@wispr.flow
gnome-extensions enable wispr-flow-window-bridge@wispr.flow
# then log out and back in
```

## Failure modes found in the VM sweep

1. **Active-app stuck at the startup seed** (`gnome.rs`). `current()` only read a
   cache that the `FocusChanged` signal updates, and mutter fires that signal
   *only on an actual focus change*. So a session whose focus never moves kept
   the empty startup value. **Fix:** `current()` now re-polls `GetFocusedWindow`
   on demand (refreshing the cache, falling back to it on error).

2. **No focused-window fallback** (`extension.js`). When
   `global.display.get_focus_window()` is null (focus is on the shell or
   overview), the extension returned nothing. **Fix:** an **MRU fallback**
   (`focusedOrMru`) returns the most-recently-used normal window, which is the
   right dictation target.

3. **`wl-copy` surface noise** (`extension.js`). The helper's own clipboard
   surfaces show up in the Shell's window list with a synthetic `window:N` app id
   and empty wmClass, and that pollutes `GetRunningApps`. **Fix:** a window-list
   filter drops them.

I validated all three on Ubuntu GNOME.

## A headless-test caveat (not a bug)

This one tripped me up before I figured out it wasn't a real failure. On the
Fedora-49 GNOME VM, mutter never granted keyboard focus to a programmatically
launched window. No real seat input ever happened in the headless session, so
injected Ctrl+V routed to a null focused surface. But I proved every component
individually: the extension returned the window list, uinput reached mutter per
`libinput debug-events`, and the clipboard was set. The same paste path passes
end-to-end on **Ubuntu GNOME**, where mutter does focus the window. So GNOME
paste works. The Fedora-49 VM just couldn't produce a focused window headlessly.

## References

- [configuration.md](../configuration.md#gnome-shell-extension),
  [decisions.md D-005](../decisions.md#d-005--per-compositor-active-app-providers).
