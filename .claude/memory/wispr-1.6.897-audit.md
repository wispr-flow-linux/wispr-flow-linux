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

- `scripts/build-linux.sh` step 2 does `rm -rf "$WORK_DIR"` (= `build-linux/`),
  which deletes `build-linux/downloads/` (the installer and Electron zip
  `download.sh` just cached) and any earlier package output. Keep a local
  `--exe` outside `build-linux/`, and copy artifacts out before the next
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
