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
| `WISPR_USE_X11` | unset | Set to `1` on a Wayland session to run the app under XWayland (`--ozone-platform=x11`). The status pill then gets X11-style click-through on every compositor, at the cost of blurry HiDPI scaling. Wins over `WISPR_USE_WAYLAND` when both are set; does nothing on an X11 session. The helper is unaffected: it still sees `WAYLAND_DISPLAY` and keeps the `/dev/uinput` injection path. |
| `WISPR_COSMIC_OVERLAY` | unset | Set to `0` to use the Electron status window for dictation on native COSMIC Wayland. Normally the helper shows a red recording indicator and processing dots over the active display when layer-shell is available. The launcher also uses the Electron status window with XWayland or a helper without layer-shell support. |
| `WISPR_DISABLE_GPU` | unset | Set to `1` to pass `--disable-gpu --disable-software-rasterizer`. Workaround for blank windows / GPU-process crashes on broken drivers or remote sessions. Also applied automatically inside XRDP sessions. |

```bash
# One-off:
WISPR_USE_WAYLAND=1 wispr-flow
WISPR_USE_X11=1 wispr-flow
WISPR_DISABLE_GPU=1 wispr-flow

# Persistent:
echo 'export WISPR_DISABLE_GPU=1' >> ~/.profile
```

> [!NOTE]
> Unlike the claude-desktop reference, the default does **not** force XWayland.
> Wispr Flow's keystroke injection uses an in-process `/dev/uinput` virtual
> keyboard (not X11 XTEST global hotkeys), so native Wayland is the validated
> default. See [learnings/wayland-injection.md](learnings/wayland-injection.md).
> `WISPR_USE_X11=1` is the way back to XWayland when a compositor has no
> Wayland input-shaping path for the status pill (see
> [troubleshooting](troubleshooting.md#clicks-near-the-status-pill-are-swallowed-or-the-pills-buttons-dont-respond-on-wayland)).

## COSMIC Wayland

Use the Flow shortcut settings to bind Caps Lock and choose hold or double-tap.
To keep Caps Lock from changing capitalization, choose **Disabled** for its
XKB behavior if your COSMIC Settings version offers that option. Older versions
can set `caps:none` in
`~/.config/cosmic/com.system76.CosmicComp/v1/xkb_config`. Preserve any existing
XKB options by adding `caps:none` to the comma-separated options string. Shift
still capitalizes letters.

The layer-shell indicator follows the focused window's output when COSMIC
reports one, honors fractional scaling, and stays click-through. The helper
uses Ctrl+Shift+V in recognized terminal apps and Ctrl+V in other targets.
If the focused window changes while the paste is being prepared, use the
transcript in Flow History to recover it.

```bash
wispr-flow --doctor
wispr-flow --clipboard-mode
wispr-flow --clipboard-mode preserve
wispr-flow --clipboard-mode keep-transcript
```

`preserve` temporarily uses the Wayland clipboard for insertion and restores
its original formats. When the previous selection cannot be saved safely, use
Flow History to recover that transcript. Preserve mode reads selections via
AT-SPI and skips the clipboard-copy fallback. Clipboard history managers can
still see temporary selections. The helper reads this setting on each paste.

The GlobalShortcuts portal is a prerequisite for reducing raw keyboard access.
The helper currently uses evdev for hold and double-tap. On systemd desktops
prefer the active-session udev ACL over permanent `input` group membership.
`--doctor` reports portal availability and the mute state of the default
desktop microphone. Flow can select its own microphone in Settings.

## Where state lives

| Path | Contents |
|---|---|
| `~/.config/Wispr Flow/` | Electron app config + state (the productName is `Wispr Flow`, so the config dir has a space). Includes `SingletonLock`, the `flow.sqlite` database, and the `meetings/` and `backups/` directories. Follows `$XDG_CONFIG_HOME`. |
| `~/Library/Application Support/Wispr Flow/` | Where earlier builds kept the database (#100). The launcher moves it into `~/.config/Wispr Flow/` on the first start after the update, and `--doctor` warns while it remains. |
| `~/.config/autostart/wispr-flow.desktop` | The "Open at login" entry, written when you turn the setting on and removed when you turn it off. Its `Exec=` passes `--hidden`, so a login start keeps the Hub closed. Your desktop's startup-apps settings can disable it. |
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
