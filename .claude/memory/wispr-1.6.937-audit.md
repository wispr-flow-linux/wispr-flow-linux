# Wispr 1.6.937 gate audit (2026-09-24)

Semantic re-audit of the pristine 1.6.937 bundle against 1.6.897, using the
method in `docs/learnings/platform-gates.md`. Patch anchoring is out of scope
here: every patch in `scripts/patches/` already applies (12/12 in
`tests/test-patch-stage.sh`; helper-resolver re-anchored in #102). Inputs were
the unpatched `.webpack/main/index.js` of both versions and the full renderer
trees (1.6.897 renderers re-extracted from `extract/nupkg/.../app.asar`).

## 1. Main bundle: `process.platform` reads, 1.6.897 vs 1.6.937

| Form | 1.6.897 | 1.6.937 | Diff |
|---|---|---|---|
| `"win32"===process.platform` | 36 | 37 | +1 |
| `"darwin"===process.platform` | 40 | 40 | 0 |
| `"linux"===process.platform` | 4 | 4 | 0 |
| `"win32"!==process.platform` | 7 | 7 | 0 |
| `"darwin"!==process.platform` | 19 | 21 | +2 |
| `"linux"!==process.platform` | 2 | 2 | 0 |
| `switch(process.platform)` (vendored file-lock lib, has a `linux` case) | 2 | 2 | 0 |
| `process.platform===...` / `!==...` (reversed operand order) | 0 | 0 | 0 |
| all `process.platform` tokens (incl. passthroughs like `platform=process.platform`) | 150 | 153 | +3 |

Pairing after normalising minified identifiers matches 150 of the 153 reads
to a 1.6.897 read; no 1.6.897 read disappeared. The three new reads:

| # | Site (1.6.937 offset) | Context | Shape | Linux lands on | Reachable on Linux? | Verdict |
|---|---|---|---|---|---|---|
| 1 | @5009021, speaker polling `Mt(e,t,n)` | `l="teams"===r&&"native"===i&&("win32"===process.platform\|\|"darwin"===process.platform&&void 0!==o)&&a` (was darwin-only in 1.6.897); gates `NotetakerAudioSwitching` speaker attribution for the native Teams client | rule 3 (`darwin\|\|win32`) | `false`, same as before | no: runs only inside a notetaker session with Teams native, behind meeting auto-detect (`Lr`, off on Linux) | no action |
| 2 | @5354120, `Wo=(e,t,n)=>{if("darwin"!==process.platform\|\|!n.clickProofHolders.includes(e.platform))return null;...}` | MeetingAutoDetect "native click consult": asks the mac helper whether a recent native click ended the call | rule 3 (darwin-only early return) | `null`, the Windows path | no (auto-detect off) | no action |
| 3 | @5384444, window_lost end-state corroboration | `if("darwin"!==process.platform\|\|!b.ug.has(e.platform)\|\|null!==t.prompt\|\|!(0,F.mn)().corroboratedSpeechBoundaryEnabled\|\|...)return"none"` | rule 3 | `"none"`, the Windows path | no (auto-detect off) | no action |

Reads that moved but did not change meaning (identifier churn only): the
platform-consts module, `Lr` auto-detect, the `Bi/Li/Di` end-state gates,
`tabStripBaselineAcquisition`, the `He` early-stop snapshot, `co`, the
meeting_recorder window config, the AX attestation `E`, the Posthog client
(`version="1.6.937"`), and the Squirrel argv block.

### The hoisted flags (`tD` = isMac, `H8` = isWin32)

Still webpack module `81609`; locals renamed `c/l` (1.6.897) to `l/u`
(1.6.937), exports unchanged (`tD`, `H8`, `ut`, `q0`, `Jy`, `Fm`, `bN`,
`v5`). One new expression in its init: `l&&(0,a.t)()` calls new module
`35310`, a pure `process.getSystemVersion()` major `>= 26` check (macOS
Tahoe); the result is discarded, so it is noise on every platform.

`.tD` consumers 216 to 221 (+5), `.H8` consumers 80 to 82 (+2). New sites,
same three rules:

| Site | Shape | Linux | Verdict |
|---|---|---|---|
| `Ko`: `lr.tD&&!Vo&&systemPreferences.subscribeLocalNotification("NSSystemTimeZoneDidChangeNotification",...)` @3093084 | rule 3 | never re-syncs `process.env.TZ` after a system time-zone change while running; the handler itself reads `/etc/localtime` and would work on Linux | low: needs a restart after a TZ change; no patch (Node's ICU TZ cache is the only casualty) |
| Accessibility drag-guidance panel: `q()` @5922169, request path @5925111/@5925175, macOS-26 check @5925474, `de()` app-bundle path from `Contents/MacOS` @5928908, drag warn @5929884 | rule 3, five `tD` reads, all inside `!m.tD` early returns | unreachable | no action (see §2 for the renderer) |
| Native meeting audio capture module `5419` (`"WAF1"` PCM frames): `M(e){if(u.H8){native capture}else{IPC StartMeetingSystemCapture to hub}}` and `w(e)` @5775903/@5776436 | rule 2 (`H8 ? native : getDisplayMedia`) | the hub `getDisplayMedia` path, same as 1.6.897 | no action; this is the second caller of the helper-path export re-anchored in #102 |
| Notetaker entry deferral predicate @~6148000: 1.6.897 required `!!o.tD&&...&&"not-determined"===getMediaAccessStatus("microphone")`; 1.6.937 drops both and defers whenever `onboardingCompleted!==true` | gate removed (was rule 3) | **now applies to Linux**: Notetaker auto-start is deferred until onboarding completes, with the `hub_notetaker_finish_setup` toast | behaviour change, not a bug; desirable since #33/#46 made onboarding completable on Linux; the one `tD` consumer that went away |

Status-pill geometry constant beside `O.tD,O.H8` changed 586 to 614 (all
platforms); the meeting_recorder darwin `trafficLightPosition` moved from
`{x:1e4,y:10}` to `{x:16,y:20}` (mac only). The 1.6.897 candidate
`meetingRecorder:zoomWindow` (`win32 ? maximize : setFullScreen`) is
unchanged and still unverified as reachable on Linux.

## 2. Renderer split

189 `.js` files under `renderer/`: 9 named renderers (`accessibility_drop`
new, plus `contextMenu`, `feature_tour`, `hub`, `meeting_ax_inspector`,
`meeting_recorder`, `scratchpad`, `status`, `overlay` preload-only),
`vendor`, and 170 code-split chunks laid out as `renderer/<digits>/index.js`
(14.9 MB total). 1.6.897 had 21 `.js` files and no chunks.

Per-file counts (files with any hit; every other file is all zeros):

| File | `platform?.isWindows` | `platform?.isMacOS` | `platform.os` | `classList.add(` w/ platform | `.linux` CSS |
|---|---|---|---|---|---|
| accessibility_drop/index.js (new) | 1 | 1 | 2 | 0 | 0 |
| contextMenu/index.js | 1 | 1 | 2 | 0 | 0 |
| feature_tour/index.js | 1 | 1 | 2 | 0 | 0 |
| hub/index.js | 1 | 1 | 8 | 2 | 0 |
| meeting_ax_inspector/index.js | 1 | 1 | 2 | 0 | 0 |
| meeting_recorder/index.js | 1 | 1 | 3 | 1 | 0 |
| scratchpad/index.js | 1 | 1 | 2 | 0 | 0 |
| status/index.js | 1 | 1 | 2 | 0 | 0 |
| every `*/preload.js` (9 identical copies) | 0 | 0 | 0 | 0 | 0 (9 `process.platform`, 3 `"linux"`: the bridge) |
| all 170 `<digits>/index.js` chunks + vendor | 0 | 0 | 0 | 0 | 0 |
| total | 8 (7 in 1.6.897) | 8 | 23 (21) | 3 (3) | 0 (0) |

Confirmed: no chunk carries `isWindows`, `isMacOS`, `isLinux`, `platform.os`,
`process.platform`, `"win32"`, `"darwin"`, or any `classList.add(` at all.
The bind still occurs exactly once per named renderer, in the preserved
`X?.platform?.isMacOS??!1, Y?.platform?.isWindows??!1` shape (three
renderers also bind a new `platform?.macSystemAudioCapabilities`, which the
driver's anchor does not touch). `build-linux.sh` globs `renderer/*/index.js`
and grep-filters on `platform?.isWindows`, so the 170 chunk `index.js` files
are skipped by the filter, not by luck of naming; the count of 8 is exact.
The hub's two `classList.add(window.electron.platform.os)` sites and
meeting_recorder's one are unchanged (renderer-chrome patch still 2 hub
sites). Zero `.linux` CSS rules anywhere, so the headline CSS bug is still
live and the win32 remap is still the right fix.

**accessibility_drop** is a 560x144 transparent, frameless, always-on-top,
non-focusable `type:"panel"` window titled "Accessibility" that main creates
in the permissions module (`[AccessibilityDropPanel]`). Its strings: "Allow
Accessibility access for Wispr Flow to arrange windows.", "Click Allow to
open System Settings, then drop the icon into the list.", "Accessibility
access is required for split-screen on join.", IPC `perms:startAppBundleDrag`
/ `perms:hideAccessibilityDropPanel`. It is the macOS 26 (Tahoe)
drag-the-app-bundle-into-System-Settings guidance for the Accessibility
permission, behind feature flag `accessibility-drag-guidance` and
`m.tD && macOS>=26`; main positions it against the helper-reported
`GetSystemSettingsWindowBounds`. It is never created on Linux. The hub's
`HideAccessibilityDropPanel` cleanup IPC on unmount is a no-op when no panel
exists. The two `platform.os` reads in its bundle are the shared i18n and
Posthog-client boilerplate every renderer carries.

Two helper commands are new in main's message schema: `SetAccessibilityGuidance`
(with `SetAccessibilityGuidancePayload`) and `GetSystemSettingsWindowBounds`.
Both are sent only from `tD`-gated code. `docs/reference/commands.json` does
not list them; worth a one-line "mac-only, never sent on Linux" note there
rather than helper work.

## 3. Path constructions (issue #100 territory)

Main bundle: 34 hits of `Library` / `Application Support` / `AppData` /
`APPDATA` / `LOCALAPPDATA` / `Roaming` in both versions, and every one pairs
across versions. Nothing new. `q0` (app data) and `Jy` (logs) in module
`81609` are still `win32 ? AppData : ~/Library/...` with no Linux branch, so
#100 stands as filed. No renderer file in either version contains any of
those strings.

## 4. What changed for Linux

- Nothing new in 1.6.937 lands Linux on a wrong branch: the three new
  `process.platform` reads and five of the six new `tD`/`H8` sites are
  meeting-detection or macOS-permission code behind gates Linux never
  enters (auto-detect off, `tD` false).
- One gate was removed rather than added: Notetaker auto-start now defers
  until onboarding completes on every platform, including Linux, with a
  "finish setup" toast. Expected, and consistent with the #33/#46 fixes.
- Renderer code-splitting changed the file layout (170 numbered chunks) but
  not the gate surface: every platform read is still in a named renderer's
  `index.js`, bound once, and the build's grep filter finds exactly 8.
- The new accessibility_drop renderer is macOS-26-only guidance and inert on
  Linux; its two helper commands are undocumented in the IPC contract.
- Data-dir strings (#100) and the 1.6.897 `zoomWindow` candidate are
  unchanged; no new `Library`/`AppData` construction.

Ranked:

1. No patch needed for 1.6.937.
2. Follow-up (docs): add `SetAccessibilityGuidance` and
   `GetSystemSettingsWindowBounds` to `docs/reference/commands.json` as
   mac-only / never sent on Linux, so a future helper contract diff does not
   flag them as missing.
3. Follow-up (verify on a VM): Notetaker deferral now fires on Linux for
   profiles with `onboardingCompleted` unset; confirm the toast path does not
   trap an otherwise-working profile (e.g. one migrated from a pre-#46 build
   that never wrote the flag).
4. Known gap, low: time-zone change re-sync is mac-only (rule 3); Linux needs
   an app restart after changing the system zone. Not worth a patch.
5. Carried from 1.6.897 unchanged: #100 (data dir under `~/Library`), the
   `meetingRecorder:zoomWindow` maximize-vs-fullscreen candidate (only if
   that window is reachable on Linux), and the #82 launch-decision widening.

Fine, do not touch: keycode/accelerator/glyph gates (rule 1), the vendored
`switch(process.platform)` lock helper, the Squirrel/Update.exe blocks, the
release-type `"unknown"` fallback that keeps the in-app updater inert, the
`desktop_mac` client type, and the darwin-only `trafficLightPosition` move.
