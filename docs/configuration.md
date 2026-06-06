[< Back to docs index](index.md)

# Configuration

Here's everything you can tune: the runtime environment variables, where state
lives, and the system permissions the text-injection helper needs.

```bash
# Confirm your system is set up for text injection:
wispr-flow --doctor
```

## Environment variables

The launcher (`scripts/launcher-common.sh`) reads `WISPR_*` overrides. I kept
that list short on purpose. The launcher only carries the overrides Wispr Flow
actually needs at runtime. It does **not** carry the menu-bar, titlebar, or
input-method overrides the claude-desktop reference had.

| Variable | Default | Description |
|---|---|---|
| `WISPR_USE_WAYLAND` | unset | Set to `1` to force native Wayland (Ozone): pins `--ozone-platform=wayland`, enables the Wayland IME path, and exports `GDK_BACKEND=wayland`. Without it, Electron 42 auto-detects Wayland/X11. |
| `WISPR_DISABLE_GPU` | unset | Set to `1` to pass `--disable-gpu --disable-software-rasterizer`. Workaround for blank windows / GPU-process crashes on broken drivers or remote sessions. Also applied automatically inside XRDP sessions. |

```bash
# One-off:
WISPR_USE_WAYLAND=1 wispr-flow
WISPR_DISABLE_GPU=1 wispr-flow

# Persistent:
echo 'export WISPR_DISABLE_GPU=1' >> ~/.profile
```

> [!NOTE]
> Unlike the claude-desktop reference, the default does **not** force XWayland.
> Wispr Flow's keystroke injection uses an in-process `/dev/uinput` virtual
> keyboard (not X11 XTEST global hotkeys), so native Wayland is the validated
> default. See [learnings/wayland-injection.md](learnings/wayland-injection.md).

## Where state lives

| Path | Contents |
|---|---|
| `~/.config/Wispr Flow/` | Electron app config + state (the productName is `Wispr Flow`, so the config dir has a space). Includes `SingletonLock`. |
| `~/.cache/wispr-flow/launcher.log` | Launcher log — display backend, GPU decision, session env block, stale-lock cleanup. Attach this to bug reports. |

```bash
# Watch the launcher log:
tail -f ~/.cache/wispr-flow/launcher.log
```

## Text injection: `/dev/uinput` access

Keystroke injection (and clipboard-based paste) writes evdev events to an
in-process `/dev/uinput` virtual keyboard. On stock images that device is
**root-only**. So the packages ship a udev rule, and it grants access two ways
for cross-distro coverage:

```
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess", GROUP="input", MODE="0660"
```

- **`TAG+="uaccess"`** — logind grants the active-session user an ACL
  (`user:<you>:rw-`). Works on Fedora and most systemd distros.
- **`GROUP="input", MODE="0660"`** — fallback for distros (e.g. Arch) where
  uinput is a seatless static node logind won't ACL. Requires the user to be in
  the **`input` group**.

```bash
# Add yourself to the input group (then log out / back in):
sudo usermod -aG input "$USER"

# Immediate grant for the current session (no relogin):
sudo setfacl -m u:$USER:rw /dev/uinput
```

If `/dev/uinput` is missing entirely, the `uinput` kernel module isn't loaded.
Run `sudo modprobe uinput` (and make sure it loads at boot). I let
`wispr-flow --doctor` check all of this for you, and it prints the exact fix.

## Clipboard tools

Clipboard-based paste and selection reads shell out to clipboard CLIs:

| Session | Required | Package |
|---|---|---|
| Wayland | `wl-copy` / `wl-paste` | `wl-clipboard` |
| X11 | `xclip` **or** `xsel` | `xclip` / `xsel` |

On Wayland, `wl-clipboard` is a **hard runtime dependency**, and the packages
declare it. I hit this on the stock Ubuntu image. It was missing there, and
paste and selection both failed until I installed it. Install it if `--doctor`
flags it.

## GNOME Shell extension

On GNOME, active-app identity, the running-apps list, and focus events come from
a bundled GNOME Shell extension
(`wispr-flow-window-bridge@wispr.flow`) that bridges
`org.gnome.Shell.Introspect`. (KDE uses an in-process KWin script. wlroots
compositors fall back to AT-SPI. Neither one needs this extension.)

> [!IMPORTANT]
> **GNOME scans extensions only at session start.** After install, you must
> **log out and back in** for the extension to load. The first run after install
> falls back to AT-SPI and logs a "log out and back in" notice; the bridge is
> persistent afterward.

```bash
# Check / enable on GNOME:
gnome-extensions info wispr-flow-window-bridge@wispr.flow
gnome-extensions enable wispr-flow-window-bridge@wispr.flow
# then log out and back in
```

Details and the focus-fallback behavior:
[learnings/gnome-shell-extension.md](learnings/gnome-shell-extension.md).

## AT-SPI accessibility

Selection reads (`GetSelectedTextViaCopy`) and the universal active-app provider
for non-KDE/GNOME Wayland compositors (Sway, Hyprland) use the AT-SPI2
accessibility bus. The helper calls `set_session_accessibility(true)`
(idempotent, best-effort) so toolkits expose their accessible trees, and on the
tested images the AT-SPI registry autostarts on demand. Some apps don't ship an
a11y bridge: bare terminals, a few Electron apps. Those won't resolve. That's
expected, and only those windows degrade to empty.

`wispr-flow --doctor` reports the AT-SPI state
(`toolkit-accessibility` / `org.a11y.Bus` reachability).

## Diagnostics

When something isn't working, start here. `wispr-flow --doctor` checks the
display server, `/dev/uinput` writability, `input` group membership, clipboard
tools, AT-SPI, the GNOME extension (on GNOME), the helper binary, the singleton
lock, and recent crashes. For reading its output, see
[troubleshooting.md](troubleshooting.md).
