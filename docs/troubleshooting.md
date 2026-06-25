[< Back to docs index](index.md)

# Troubleshooting

Symptom-keyed fixes for the real Wispr Flow for Linux failure modes. The
headings are the symptoms — search for yours.

## First step: `wispr-flow --doctor`

Hey! Before you go spelunking, run the built-in diagnostics. I wired `--doctor`
up precisely so I'd stop guessing at which of a dozen Linux quirks was biting me
on any given machine — it checks them all in one shot:

```bash
wispr-flow --doctor
# AppImage:
./wispr-flow-*.AppImage --doctor
```

It prints `[PASS]` / `[WARN]` / `[FAIL]` lines with inline fix commands, grouped:

| Section | Checks |
|---|---|
| Display | Wayland/X11 detection, desktop family (KDE / GNOME / wlroots) |
| Text Injection (uinput) | `/dev/uinput` writability, `input` group membership |
| Clipboard | `wl-clipboard` (Wayland) / `xclip`/`xsel` (X11) |
| Accessibility (AT-SPI) | `toolkit-accessibility` / a11y bus reachability |
| GNOME Window Bridge | (GNOME only) extension installed + active |
| Helper / Singleton / Crashes | helper binary present, stale lock, recent crash count |

The exit status is non-zero if any check FAILs. Do me a favor and attach the
full output to bug reports — it's the single most useful thing you can hand me.

## Push-to-talk doesn't fire / shortcut recorder captures no keystrokes (including during onboarding)

The in-app shortcut recorder (including the one on the onboarding setup screen)
and push-to-talk are both fed entirely by `KeypressEvent` frames the helper
streams from the OS key layer. If those frames never arrive, the recorder shows
nothing and captures nothing — the app has no other path for global hotkey input.

The helper has two capture backends:

- **evdev** (`/dev/input/event*`) — works on Wayland **and** X11. Needs read
  access to the input devices.
- **XInput2** — true X11 sessions only (not XWayland). Needs no device access.

On **Wayland**, only evdev is available, and it needs the udev access grant.

### Fix

Run the built-in diagnostics first — the `Push-to-Talk (input monitor)` section
will tell you exactly what's missing:

```bash
wispr-flow --doctor
```

If it prints `[FAIL] /dev/input: none of N event device(s) readable`, install
the udev rule that grants your session access to input devices (this is a
one-time step; it survives reboots):

```bash
wispr-flow --install-udev-rules
```

The command escalates via `pkexec` (graphical sudo prompt) or falls back to
`sudo`. After it completes you may need to **log out and back in** (or replug
your keyboard) for the new ACL to take effect on already-open devices. Then
re-run `--doctor` to confirm the check passes and try the shortcut recorder
again.

Alternatively, if you're already a member of the `input` group (check with
`id -nG | grep input`), just re-login — logind should grant uaccess on session
start.

> [!NOTE]
> On **X11** the helper uses XInput2, which needs no device access at all. If
> the shortcut recorder is still dead on X11 after confirming the helper is
> running (`--doctor` shows the helper launch as OK), file a bug with the
> full `--doctor` output.

## Paste does nothing / transcription doesn't get typed into my app

This is the whole reason the app exists, so when it goes silent it hurts. In my
experience it's almost always one of two things: `/dev/uinput` or the clipboard.
Run `--doctor` and work the failures top-down:

### Fix

1. **`/dev/uinput` not writable** — injection has nowhere to type. The virtual
   keyboard can't open the device. Grant access (then re-run `--doctor`):

   ```bash
   # Immediate (this session):
   sudo setfacl -m u:$USER:rw /dev/uinput

   # Persistent: add yourself to the input group, then log out / back in:
   sudo usermod -aG input "$USER"
   ```

   If `/dev/uinput` is missing entirely, the kernel module isn't loaded yet —
   load it: `sudo modprobe uinput`.

2. **`wl-clipboard` missing (Wayland)** — clipboard-based paste has no tool to
   set the selection with. Install it:

   ```bash
   sudo dnf install wl-clipboard    # Fedora/RHEL
   sudo apt install wl-clipboard    # Debian/Ubuntu
   ```

   On X11, the equivalent dep is `xclip` or `xsel`.

3. **Not in the `input` group and no uaccess ACL** — some distros don't ACL
   uinput through logind (Arch is the one that caught me), so group membership
   is your grant path instead. Go back to step 1's `usermod` and relogin.

Want the why behind all this? See
[configuration.md](configuration.md#text-injection-devuinput-access) for how the
udev rule grants access, and
[learnings/wayland-injection.md](learnings/wayland-injection.md) for the
mechanism.

## Window / app detection wrong on GNOME

`--doctor` shows the GNOME Window Bridge as not active, or the active app /
running-apps list is empty or stale on a GNOME session.

### Fix

Here's the gotcha that ate an afternoon of mine: the bridge is a GNOME Shell
extension, and **GNOME scans extensions only at session start**. Enabling it
mid-session isn't enough on its own:

```bash
gnome-extensions info wispr-flow-window-bridge@wispr.flow
gnome-extensions enable wispr-flow-window-bridge@wispr.flow
```

Then **log out and back in.** That's the part people skip. The first run after
install quietly falls back to AT-SPI and logs a "log out and back in" notice;
once you've cycled the session the bridge sticks around for good. The whole story
is in [learnings/gnome-shell-extension.md](learnings/gnome-shell-extension.md).

> [!NOTE]
> This is GNOME-specific. KDE uses an in-process KWin script and wlroots
> compositors (Sway, Hyprland) use AT-SPI — neither needs the extension, and
> `--doctor` hides the GNOME Window Bridge section off GNOME.

## "no such table" / database errors

The app launches but every DB-backed feature errors with **"no such table"**,
and the log shows **"Executed 0 migrations"**.

### Fix

This one is sneaky, and it took me a while to trust the cause. Your Electron
launcher is named `electron`. Electron forces `app.isPackaged=false` whenever the
launcher is literally named `electron`, so the app goes hunting for migrations in
the (nonexistent) *dev* path, runs zero of them, and then every query slams into
a table that was never created. The launcher has to be renamed to `wispr-flow`:

- **Installed packages already do this** — the makers rename the binary for you
  and the launcher exports `ELECTRON_FORCE_IS_PACKAGED=true`, so you shouldn't
  see this from a `.deb` / `.rpm` / AppImage. If you do, that's a bug — file it
  with your `--doctor` output.
- **Run-in-place / manual builds** — you're on the hook for the rename here:
  move the Electron binary off `electron` (e.g. to `wispr-flow`) before you
  launch, or set `ELECTRON_FORCE_IS_PACKAGED=true`.

I wrote the whole thing up in
[learnings/ispackaged-rename.md](learnings/ispackaged-rename.md).

## App won't start from a terminal

Launching from an SSH session or bare TTY does nothing, or the launcher log says
no display is available.

### Fix

No surprise here once you know it: Wispr Flow needs a **graphical session** — a
live Wayland compositor or X server. It can't run headless from a TTY, full
stop. Quick check:

```bash
echo "$WAYLAND_DISPLAY $DISPLAY"   # at least one must be non-empty
```

If both come back empty, you're on a bare TTY or an SSH session with no display —
launch the app from inside your desktop session instead. (If you genuinely need
headless, that's what the artifact tests do: they wrap the launch in `xvfb-run` +
`dbus-run-session` — see [tests/README.md](../tests/README.md).)

## Blank window / GPU crash on launch

The window renders blank, or the GPU process crashes — common on broken drivers,
VMs, or remote (XRDP) sessions.

### Fix

Disable hardware acceleration:

```bash
# One-off:
WISPR_DISABLE_GPU=1 wispr-flow

# Persistent:
echo 'export WISPR_DISABLE_GPU=1' >> ~/.profile
```

Under the hood that passes `--disable-gpu --disable-software-rasterizer`. Good
news if you're on XRDP: the launcher already sets those flags for you there, no
env var needed (it detects XRDP specifically — other RDP backends still need the
variable). More knobs in
[configuration.md](configuration.md#environment-variables).

## App won't launch a second time (stale singleton lock)

After a crash or unclean shutdown, the app silently quits on every launch and
nothing appears.

### Fix

A stale `SingletonLock` left behind by a dead process is what's blocking new
instances. The launcher is supposed to clear it once the owning PID is gone, but
if it somehow lingers you can nuke it by hand:

```bash
rm -f ~/.config/Wispr\ Flow/SingletonLock
```

And yes, `--doctor` flags a stale lock under its singleton-lock check, so you
don't have to go looking for it yourself.

## Selection reads come back empty

`GetSelectedTextViaCopy` returns nothing in some apps.

### Fix

Don't panic — this is usually working as intended. Selection reads ride on the
AT-SPI accessibility bus, and apps without an a11y bridge (bare terminals, a
handful of Electron apps) just don't expose a selection at all. It's expected,
and it's scoped to those specific apps. First confirm AT-SPI is actually on:

```bash
wispr-flow --doctor   # check the "Accessibility (AT-SPI)" section
```

The helper turns on session accessibility itself, so if `--doctor` still reports
the a11y bus as unreachable, odds are the AT-SPI registry just isn't running on
your compositor. [configuration.md](configuration.md#at-spi-accessibility) has
the details.

## "ERROR: Linux helper not staged at resources/Release/wispr-flow-linux-helper"

A `./build.sh` run fails in the packaging step with this error (often after a
`helper not present in staged tree` warning during the resources sync).

### Fix

The packaging makers refuse to ship a tree without the helper, and staging
didn't get one. Staging auto-fetches the prebuilt helper pinned in
`helper-version.txt` when `HELPER_BIN` is unset, so this means the fetch failed
or an explicit `HELPER_BIN` pointed at a missing/non-executable file — scroll up
to the `[WARN]` lines from Step 0 for which one.

1. **Auto-fetch failed** (no network, or `gh`/`curl` unavailable) — restore
   network access and re-run, or fetch by hand:

   ```bash
   scripts/setup/fetch-helper-bin.sh x86_64   # or aarch64
   ./build.sh --build deb
   ```

2. **`HELPER_BIN` override is wrong** — the build respects an explicit override
   and never fetches over it. Point it at a *built binary* (not a source
   checkout), or unset it to auto-fetch:

   ```bash
   HELPER_BIN=/path/to/helper/target/release/wispr-flow-linux-helper \
     ./build.sh --build deb
   ```

See the helper section of [building.md](building.md#the-clean-room-helper-prebuilt-with-a-helper_bin-override).

## More

Curious which setups are actually validated, and which are only wired through?
That's all spelled out in [compatibility.md](compatibility.md), and the design
rationale behind these calls is in [decisions.md](decisions.md).
