# Issue #32 — manual UX validation status

Tracking issue: **#32** "Manual UX validation: baseline + PRs #27/#28/#29/#30
(Wispr Flow 1.5.789)". Goal: manually validate the baseline and four Linux UI
PRs across desktop environments and comment results.

PR branches (fetch as `pr-NN`): #27 `c884ffc` overlay sticky / Alt+Tab exclusion
(`linux-overlay-visible.sh`); #28 `f10356c` status-pill positioning + dock
autohide (`linux-status-position.sh`); #29 `58090b5` XDG autostart
(`linux-autostart.sh`); #30 `30fb3f7` pill autohide + XWayland default launcher
(`linux-status-autohide.sh` + `launcher-common.sh`). Each PR adds a build-time
patch baked into the app bundle, so testing runtime behavior needs a full
rebuild + reinstall from that branch.

## Result-comment template (one VM row)

```
VM / DE: <e.g. Ubuntu 24.04 GNOME Wayland>
Build under test: <main | PR #NN @ short-sha>
Baseline: <pass / issues>
#27: <pass / N/A here / issues>
#28: <pass / issues>
#29: <pass / issues>
#30 Part A: <pass / issues>   Part B sharpness: <sharp / blurry / N/A>
Notes / screenshots:
```

## Status by environment

### Ubuntu 24.04.4 / GNOME / Wayland (virtio-gpu VM)

- **Baseline (clean `main` build) = PASS.** Hotkey → listening → gRPC
  transcription → `PasteText` → text injected into gnome-text-editor; pill shows
  during dictation; `--doctor` all-green. (Required first rebuilding a pristine
  `main` deb — the pre-existing installed deb was not pristine main; it forced
  XWayland by default, i.e. already carried PR #30's launcher change.)
- Filed **issue #33**: default push-to-talk binds to a Mac-only key on Linux
  profiles → dictation silently untriggerable (blank PTT in Settings); suggested
  fix: fall back to Ctrl+Meta when the resolved keycode is `-1`.
- **#27 / #28 / #30 Part B (XWayland overlay behavior): DEFERRED to a dedicated
  X11 VM.** These depend on X11 window-type hints that no-op under native
  Wayland, so they aren't meaningfully testable on this Wayland session.
- **TODO on this VM:** #29 (XDG autostart — file-based: toggle setting → verify
  `~/.config/autostart/wispr-flow.desktop` created/removed); optionally #30 Part
  A (pill autohide timing — app-logic, may manifest under Wayland). Then post the
  VM row to #32.

## Checklists (condensed)

- **Baseline:** hotkey starts dictation; text injects into focused app; pill
  shows during dictation; `--doctor` all-green.
- **#27:** pill visible across all workspaces; Alt/Super+Tab excludes overlays;
  app-switch doesn't steal focus; meeting recorder NOT sticky.
- **#28:** pill just above fixed panel/dock (no overlap); context menu positions
  correctly; ~11px above a revealed autohide dock; no floating gaps on
  left-dock/top-bar.
- **#29:** settings toggle ON creates `~/.config/autostart/wispr-flow.desktop`,
  OFF removes it; fresh profile auto-creates; real login uses `/usr/bin/wispr-flow`;
  no crash if autostart dir missing; (KDE) entry appears in KDE Autostart UI.
- **#30 Part A:** idle = no pill; listening = pill instantly; dictation end hides
  ~2s; error states hide after grace; respects visibility flags. **Part B:**
  HiDPI/fractional-scale clarity under forced XWayland; note blurriness.
