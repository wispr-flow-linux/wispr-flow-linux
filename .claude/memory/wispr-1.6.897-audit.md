# Wispr 1.6.897 patch audit (2026-09-21)

Phase 1 of [`pr-triage-plan-2026-09.md`](pr-triage-plan-2026-09.md). Local
build from the direct installer URL in
`https://dl.wisprflow.com/wispr-flow/win32/latest.json` (sha256
`1fe57d8e…7896`, 344 MB), audited against the 1.5.789 bundle kept in
`extract-1.5.789/` on the dev host.

## Anchor results on the pristine 1.6.897 main bundle

| Patch | Result | Note |
|---|---|---|
| helper-resolver | match, same site | logger `l`, var `s`; guard shape unchanged |
| mac-gates | match, same site | still the `/Applications` regex guard |
| helper-env | **0 matches** | env object hoisted into `N=(e=a.app.isPackaged)=>({sentryDSN:…})`, spawn reads `env:N()`; fixed by #55's `{sentryDSN:` anchor |
| linux-window-frame | **0 matches** | meeting_recorder win32 object gained `frame:!1` between `titleBarStyle:"hidden"` and `autoHideMenuBar:!0`; fixed with a `[^{}]`-fenced property-bag regex |
| linux-deeplink | match, 1 site | second-instance handler is win32-gated too, but it was in 1.5.789 as well (not drift) |
| renderer-chrome | 2 sites (same as 1.5.789) | hub renderer |
| treat-as-windows | 7 renderers | calendar_reminder gone; feature_tour and meeting_ax_inspector new; driver grep-filters so no change needed |

`"win32"===process.platform` reads grew from 23 to 36. New gates are mostly
meeting-recorder/detection (`setDisplayMediaRequestHandler` loopback audio,
`autoDetectMeetingsEnabled`, session-end on `power-shutdown`) plus one chrome
behaviour: title-bar double-click does maximize on win32 and `setFullScreen`
elsewhere. None re-audited for Linux yet; see `platform-gates.md` for the
method. A new meeting_ax_inspector window uses a two-way switch whose else
branch already frames Linux.

## Runtime results

- AppImage artifact test: 34/34 under Xvfb, helper backend line read and not
  `stub`.
- Live KDE Wayland desktop with an isolated `HOME`/`XDG_*`: helper-ready in
  ~4 s, `injection: Wayland (uinput + wl-clipboard)`, `active-app: KWin
  scripting bridge`.
- Mutant AppDir (env spread stripped from the asar): the new
  `_smoke_check_backend` fails with `stub (no-op) — OS integration disabled`.
- Second patch pass over the patched tree is byte-identical.

## Gotchas hit

- `scripts/build-linux.sh` step 2 used to `rm -rf "$WORK_DIR"` (=
  `build-linux/`), deleting `build-linux/downloads/` (the installer and
  Electron zip `download.sh` just cached) and any earlier package output.
  Fixed 2026-09-22: step 2 keeps `downloads/`; the staged tree and package
  outputs are still regenerated, so copy artifacts out before the next
  format's build.
- `extract_installer` reuses an existing `extract/` tree without checking its
  version. Move the old tree aside before building a new Wispr version.
- Under `xvfb-run` on a Wayland dev session the helper still picks the Wayland
  backend (`WAYLAND_DISPLAY` is inherited), so the X11 path is only exercised
  on a headless runner.
- `xvfb-run` was not installed on the Nobara host (`dnf install
  xorg-x11-server-Xvfb`).
- The app logs `Error checking for override release … SyntaxError: Unexpected
  token '<'` at startup on 1.6.897: an upstream endpoint returning HTML, not a
  Linux issue.

## Gate audit of the new `"win32"===process.platform` reads (2026-09-22)

36 reads on 1.6.897 against 23 on 1.5.789. 22 pair up by developer string
(14 vendored libs, the platform-consts module, `getClientInfo`, the
meeting_recorder window config, the Squirrel "already running" guard, the
Sentry manufacturer probe, the Crashpad dirs, the Squirrel argv block and
the GPU switches); one 1.5.789 read (a vendored process-list helper) is
gone; 14 are new. Classified with the three rules in
`docs/learnings/platform-gates.md`:

| Site (1.6.897 order) | Shape | Linux lands on | Verdict |
|---|---|---|---|
| 17 session guard: `if(win32){session-end listeners}` | rule 3 | `powerMonitor.on("shutdown")`, which is registered for every platform just before | no action |
| 18 `Or` = meeting auto-detect enabled iff darwin or win32 | rule 3 | feature off | keep off: the clean-room helper has no meeting-window detection; document as a known gap |
| 19-25 meeting end-state / conference matching (`win32 ? A.rA : A.yt`, `wi()`, the `never_ran_*` outcomes, `isWin32` in the lane picker) | rule 2 | mac branches | unreachable while 18 is off; no action |
| 26 AX snapshot capabilities `n||r`, `hostPlatform:"other"` | consistent | everything false | no action |
| 27 `focusOrOpenConference`: darwin or win32 try the helper's window focus first | rule 3 | opens the URL | acceptable; a later helper active-app feature could add Linux |
| 28 `setDisplayMediaRequestHandler` | explicit Linux skip with a log line | skipped | no action |
| 29 `meetingRecorder:zoomWindow`: `win32 ? maximize/unmaximize : setFullScreen` | rule 2 | mac fullscreen toggle | **candidate**: `linux-window-frame.sh` gives that window the win32 frameless chrome, so a title-bar double-click should maximize like Windows; only worth a patch if the meeting_recorder window is reachable on Linux (auto-detect is off), which is unverified |
| 31 release type: win32 "squirrel", darwin "macos", else "unknown" | rule 2-ish | "unknown" | desirable: the in-app updater stays inert and updates come from APT/DNF/AUR; no action |

Pre-existing reads re-examined on the way, because #82's target lives
beside them:

- The platform-consts module (81609) exports `H8` (isWin32), `tD` (isMac),
  `ut()` (client type: "desktop_mac" / "desktop_windows" / **"desktop_mac"
  for Linux**, telemetry only), and two path constants built as
  `win32 ? AppData : ~/Library`: `q0` (app data) and `Jy` (logs). Both are
  rule 2. `q0` has 36 consumers and is what the packaged data-dir function
  returns, so on Linux **`flow.sqlite`, `meetings/`, `backups/` and all
  extension state live under `~/Library/Application Support/Wispr Flow`**;
  both isolated-profile launches on this host created it. `Jy` feeds
  electron-log's file transport, which packaged builds keep off. A third
  gate of the same shape puts a `Flow` dir under the same roots. Filed as
  #100 with the migration requirement (the database is in there).
- #82's gate is the `o.H8&&prefs.openAtLogin&&onboardingCompleted` arm of
  the launch decision that logs "Not showing hub window at launch: auto
  launch at login is enabled"; widening `o.H8` there to include Linux is the
  whole patch, anchored on that developer string.

