# Imsai (CachyOS / KDE Wayland desktop) — host state notes

The maintainer's desktop (hostname `Imsai`), where the PTT hotplug-decay bug
(helper#7, this repo #48) was diagnosed. Not a test VM — real daily driver.

- **The installed helper binary is a local build, not the release.** AUR
  package `wispr-flow-appimage` layout under `/opt/wispr-flow-appimage`;
  `resources/Release/wispr-flow-linux-helper` was replaced 2026-08-05 with a
  build of `~/dev/wispr-flow-linux-helper` branch `fix/evdev-keyboard-hotplug`
  (the helper#8 hotplug fix). It still reports `--version` `0.1.2` — do NOT
  assume repo-tag behaviour from the version string. The pristine release
  asset sits beside it as `wispr-flow-linux-helper.orig` (sha256 matches the
  v0.1.2 GitHub asset). A pacman upgrade of the package will silently restore
  the broken release helper until a fixed helper release is pinned.
- **`/dev/input` churn sources here:** Logitech G604 (Bluetooth mouse)
  exposes a keyboard HID node that returns on every reconnect; Keychron K2
  (USB) re-enumerates on replug/reset; suspend/resume cycles. `162+86 →
  paste_event` matches in the log can come from the G604, so they do NOT
  prove the Keychron stream is alive. (RustDesk — the loudest churn source
  during the helper#7 diagnosis, re-creating a uinput keyboard hourly on the
  hour — was **uninstalled 2026-08-13**; `input: RustDesk UInput Keyboard`
  journal entries before that date are it.)
- **Log forensics:** `~/.cache/wispr-flow/launcher.log` is append-only across
  runs and holds helper stderr (with full UTC dates — use as date anchors for
  the time-only app lines). `main.log` rotates at 3 MiB. PTT usage dates are
  recoverable by grepping `Handling action from keycodes: ctrl + win`.
- **`scripts/ptt-trace.sh start` was left running** (2026-08-13) writing to
  `~/.cache/wispr-flow/ptt-trace/` to catch any residual failure with the
  hotplug helper. Check it before diagnosing this machine again; stop it once
  a fixed helper release is pinned and validated.
- User PTT chord: Ctrl+Meta (`"162+91": "ptt"` in
  `~/.config/Wispr Flow/config.json`).
