# VM testing notes — building, launching, and driving the app

Hard-won operational knowledge for manually validating builds on a real desktop
session. Verified on **Ubuntu 24.04.4 / GNOME / Wayland** (virtio-gpu VM).

## Build a test `.deb`

```bash
git checkout <branch>          # e.g. main, or a pr-NN branch
./build.sh --build deb         # downloads the proprietary installer + Electron,
                               # rebuilds native sqlite, packages a .deb
sudo apt install -y ./build-linux/deb/wispr-flow_<ver>_amd64.deb
```

- Reinstalling **keeps the user profile** in `~/.config/Wispr Flow` (so a fixed
  keybind, login, etc. persist across reinstalls).
- The installer `.exe` is **not** retained between builds (re-downloaded each
  time; ~12s on a fast link). Pass `-e/--exe <Setup.exe>` to reuse a local copy.
- Build deps are checked by `build.sh` (`7z`, `icoutils`, `imagemagick`, `rsync`,
  `node`/`npx`, `dpkg-deb`).
- `wispr-flow --doctor` is the built-in diagnostic (display/session, uinput,
  clipboard, GNOME ext, AT-SPI, push-to-talk, launcher rename).

## Launch & backend

- Just run `wispr-flow` (no env overrides). On a working GPU this auto-detects
  **native Wayland** (Ozone) and gives a normal, focusable, taskbar-managed
  window.
- **Do NOT set `WISPR_DISABLE_GPU=1`** unless the GPU is actually broken — it
  adds `--disable-software-rasterizer`, which makes the transparent overlay paint
  as an **opaque fullscreen takeover**. (On a VM with a working virtio-gpu render
  node, GPU-on is correct.)
- Native Wayland ignores X11 EWMH window-type hints, so the overlay/pill sticky /
  Alt+Tab / positioning behaviors (see PRs #27/#28/#30) only manifest under
  **XWayland**. Force XWayland by passing `--ozone-platform=x11` as an arg
  (`ELECTRON_OZONE_PLATFORM_HINT=x11` was NOT honored). Under XWayland,
  `xdotool`/`import` can see/move/screenshot windows; under native Wayland they
  cannot, and GNOME's screenshot D-Bus is `AccessDenied`.
- **Kill safely with** `pkill -KILL -x wispr-flow` (exact comm). NEVER
  `pkill -f wispr-flow` — it also matches the shell running the command and kills
  it mid-run.

## Driving the UI

- The **system-tray icon** (not the GNOME dock/dash icon) has the real
  app-specific menu (Settings / Home / Quit). Closing the Hub via the titlebar X
  keeps the tray + app alive; tray → **Home** reopens the Hub. (After onboarding
  the Hub may not auto-open; reopen from the tray.)
- Onboarding **auto-completes after the first successful dictation** ("user has
  dictated but onboarding is not complete - manually completing").

## Microphone

- This VM's emulated mic has a **~1s startup delay**: hold the PTT key → wait
  ~1s → speak → release. Short holds capture only the silent lead-in
  ("Received silence from recorder worklet"). The mic itself works (visible level
  in GNOME Settings → Sound).

## Keybind gotcha (see issue #33)

A profile can arrive with push-to-talk bound to a **Mac-only key** — config has
`prefs.user.shortcuts` `"-1": "ptt"` with `modifierShortcut: "9"`. Per
`docs/reference/keycodes.json`, `-1` = "no keycode on Linux" (the Mac-only keys
`opt`/`cmd`/`fn`/`doubleFn`). Result: the Settings "Push to talk" entry is
**blank** and dictation can never trigger (the key monitor receives events but
nothing matches). **Fix:** Hub → Settings → General → Shortcuts → Change → set
**Ctrl+Meta** (Ctrl+Win); config then shows `"162+91": "ptt"`.

## Watching dictation in the log

`~/.cache/wispr-flow/launcher.log`. Mark the line count, do a dictation, then
grep for the pipeline:

```bash
grep -iE 'updateDictationStatus|RecordingStarted|transcription successful|PasteText' \
  ~/.cache/wispr-flow/launcher.log
```

A healthy round-trip: `listening → recording → gRPC transcription successful →
Electron -> Helper: PasteText request sent`, and the text lands in the focused
field.
