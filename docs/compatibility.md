[< Back to docs index](index.md)

# Compatibility

Hey! Here's where I've actually run the Wispr Flow Linux helper and watched it
work — the validated desktop environments and display servers. The helper picks
a backend per session, on its own. This page is my record of what each target
actually does.

| Environment | Backend | Active app | Running apps | Paste (Ctrl+V) | Selection (AT-SPI) | Focus events |
|---|---|---|---|---|---|---|
| **KDE Plasma 6 (Wayland)** | wayland-uinput + KWin bridge | ✓ | ✓ | ✓ | ✓ | ✓ |
| **GNOME (Wayland)** | wayland-uinput + GNOME extension | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Sway / wlroots (Wayland)** | wayland-uinput + AT-SPI | ✓ | ✓ | ✓ | ✓ | ✓ |
| **Hyprland (wlroots)** | wayland-uinput + AT-SPI | ✓ | ✓ | ✓ | ✓ | ✓ |
| **i3 / X11 (Xorg)** | x11-XTEST + AT-SPI | ✓ | ✓ | ✓ | ✓ | ✓ |

> [!NOTE]
> Validation ran on **x86_64**. arm64 is wired through but not
> hardware-validated — see [building.md](building.md#architecture-support).

## Backends

Here's what each backend is doing under the hood, in plain terms.

- **KDE Plasma (Wayland)** — text injection via in-process `uinput` +
  `wl-clipboard`; active-window identity and focus events via a KWin script over
  D-Bus; selection reads via AT-SPI.
- **GNOME (Wayland)** — active app / running apps / focus via the
  `org.gnome.Shell.Introspect` API and the bundled GNOME Shell extension;
  injection, clipboard, and selection via the shared Wayland backend. Heads up:
  the extension needs a relogin to load after first install. Until then the
  helper quietly falls back to AT-SPI and logs a notice — nothing's broken,
  it just hasn't loaded yet.
- **wlroots / other Wayland (Sway, Hyprland)** — the generic Wayland backend:
  `uinput` + `wl-clipboard`, with AT-SPI for active-app. Apps without an AT-SPI
  bridge (bare terminals, some Electron apps) won't resolve an active app. That's
  expected — it degrades to empty for those windows only, not the whole session.
- **X11** — XTEST injection + `_NET_*` window properties, AT-SPI selection.

## Requirements

These are the things the helper genuinely can't work without. Three of them:

- **`/dev/uinput` write access** for Wayland injection — granted by the bundled
  udev rule; see [configuration.md](configuration.md).
- **`wl-clipboard`** is a hard runtime dependency on Wayland (paste + selection);
  `xclip` / `xsel` cover the X11 path.
- **`/dev/input/event*` read access** for push-to-talk — the same udev rule
  grants it.

If something's off in your particular setup, the
[troubleshooting.md](troubleshooting.md) page is where I keep the
environment-specific fixes. And honestly, the fastest move is to just run
`wispr-flow --doctor` — it checks your session against everything above and tells
you what's missing.
