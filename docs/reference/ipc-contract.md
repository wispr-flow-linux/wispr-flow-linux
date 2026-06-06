[< Back to docs index](../index.md)

# Wispr Flow Helper — IPC contract

Source of truth: `extract/app/.webpack/main/index.js` (webpack-bundled Electron main, v1.5.619).
Everything below is recovered from that bundle — not inferred. A Linux helper must match this
exactly so the unmodified Electron app talks to it without patching the main process (beyond adding
a `'linux'` branch to the helper-path resolver).

Companion machine-readable files in this dir:
- `keycodes.json` — full key name → `{mac, linux}` numeric code table.
- `commands.json` — full request/response type name lists.

---

## 1. Process spawn & stdio topology

The helper is spawned (bundle ~offset 3663746) as:

```js
spawn(helperPath, {
  stdio: ["pipe", "pipe", "pipe", "pipe"],   // 4 pipes — note fd 3
  env: { sentryDSN, environment, segmentWriteKey, postHogProjectKey, sentryLocalDebug }
})
```

**This corrects the earlier "NDJSON over stdin/stdout" assumption.** The real topology:

| fd | direction | purpose |
|----|-----------|---------|
| **0 (stdin)**  | Electron → Helper | **commands** (`HelperAPIRequest` / `HelperAPIResponse` messages) — `writeMessage` writes here |
| 1 (stdout) | Helper → Electron | **non-IPC**; anything here is logged as `"Helper service stdout (non-IPC)"`. Do NOT use for protocol. |
| 2 (stderr) | Helper → Electron | logged line-buffered; benign system messages filtered. Use for diagnostics only. |
| **3 (extra pipe)** | Helper → Electron | **the IPC return channel** — every message the helper emits goes here. Electron reads it via `stdio[3].on("data", …)` → `pushData`. If fd 3 can't be created it logs `"Failed to create IPC pipe (fd 3)"`. |

So: **read commands on stdin, write all protocol output to fd 3.** On Linux, fd 3 is just the
4th entry of the stdio array; write to `/proc/self/fd/3` or the raw fd 3 directly.

The app also has a *separate, unrelated* one-shot utility (`getProcessInfoByIdAsync`) that spawns
something with `stdio:["ignore","pipe","ignore"]` and reads stdout — do not confuse it with the helper.

---

## 2. Wire framing

Both directions use the same framing (`pushData` / `writeMessage` / `escapeMessage`):

- **Message body** = `JSON.stringify(envelope, null, 2)` — **pretty-printed, multi-line** (2-space indent).
  Because the body contains newlines, newline is NOT the delimiter.
- **Delimiter** = `"|"` (U+007C pipe). Messages are concatenated as `body + "|"`.
- **Escaping** (applied to the body before appending the delimiter):
  - escape:   replace `+` → `+1`, then `|` → `+2`
  - unescape: replace `+2` → `|`, then `+1` → `+`
  (escape char is `+`. Order matters: escape `+` first, unescape `+2` first.)
- **Max length:** Electron refuses to send a body > **30000** chars (`"IPC message is too long"`). The
  helper should assume inbound messages are within this bound and keep its own outbound messages under it.
- **Parsing (inbound, helper side):** accumulate bytes, split on unescaped `"|"`, unescape each chunk,
  `JSON.parse`, dispatch. (Mirror of `pushData`.)

### Envelope

Every message is one of:

```jsonc
{ "HelperAPIRequest":  { "<CommandName>": <payload|true>, "uuid": "<id>", "sentryTrace": "...", "sentryBaggage": "..." } }
{ "HelperAPIResponse": { "<ResponseName>": <payload|true>, "uuid": "<id>" } }
```

- Exactly one command/response key is set per envelope (plus metadata keys). `getMessageType` =
  "first key that isn't a metadata key (`uuid`/`sentryTrace`/`sentryBaggage`) and isn't undefined".
- **`uuid` correlates request↔response.** Electron's `sendRequest` registers a resolver keyed by
  `request.uuid`; the helper's response MUST echo the same `uuid`. Fire-and-forget commands still
  carry a uuid but Electron may not wait on it.
- Messages flow **both ways as both kinds**: Electron sends requests (most commands) and sends
  responses (e.g. ACK to helper-initiated requests); the helper sends responses (to Electron's
  requests) and sends requests/events (e.g. `KeypressEvent`, `AppInfoUpdate`, `FocusChanged`-style).
- A command with no payload is encoded as the literal **`true`** (e.g. `{"GetActiveAppInfo": true, "uuid": …}`).

---

## 3. Readiness handshake (implement this first)

On startup, and then as a keepalive ping, Electron sends:

```jsonc
{ "HelperAPIRequest": { "IsReady": true, "uuid": "…" } }
```

The helper MUST reply (on fd 3) with an **ACK** response echoing the uuid; optionally include launch timing:

```jsonc
{ "HelperAPIResponse": { "ACK": true, "uuid": "<same uuid>",
                         "HelperLaunchTiming": { "helperMainEntryMs": <number> } } }
```

(`HelperLaunchTiming` is optional — the readiness resolver only checks `e.ACK`.)
Electron polls readiness up to 6 times (1×1000 ms then 5×10000 ms). After ready it sends `IsReady`
periodically as a keepalive (`KEEPALIVE_PING_THRESHOLD_MS`); failing to ACK eventually triggers a
helper relaunch. **`IsReady`/`ACK` are in the suppressed-logging set, so they won't spam logs.**

Suppressed-log message types (high-frequency, don't log each one):
`IsReady, CheckStaleKeys, ACK, StaleKeysResponse, TextBoxInfo, GetTextBoxInfo, DockInfoUpdate,
IsMediaPlayingUpdate, KeypressEvent, AppInfoUpdate, GetHardwareInfo, HardwareInfo, UpdateEditedText,
GetAccessibilityStatus, AccessibilityStatus, BLEAudioData, ClipboardChanged, GetMicrophoneHolders,
MicrophoneHolders`.

---

## 4. Full command surface

`commands.json` has the canonical lists. **68 request** types (65 commands + 3 metadata keys) and
**15 response** types (14 + uuid). Most are macOS/Windows-desktop-integration features; only a
subset is needed for a useful Linux MVP. Grouping by Linux relevance:

### MVP / core (implement first)
| Command (req) | Response | Linux backend |
|---|---|---|
| `IsReady` | `ACK` (+`HelperLaunchTiming`) | trivial — handshake/keepalive |
| `PasteText` | (ACK / `PasteOutcome` req back) | clipboard set + synth Ctrl+V |
| `SimulateKeyPress` | — | XTEST `XTestFakeKeyEvent` (X11) |
| `GetActiveAppInfo` | `ActiveAppInfo` | `_NET_ACTIVE_WINDOW`→`_NET_WM_PID`→`/proc/PID/exe`, `_NET_WM_NAME` |
| `GetAppInfo` | `AppInfo` | same, by request |
| `GetRunningApps` | `RunningApps` | enumerate windows / `/proc` |
| `GetSelectedTextViaCopy` | `SelectedTextViaCopy` | AT-SPI Text iface, or clipboard-copy probe |
| `GetAccessibilityStatus` | `AccessibilityStatus` | is AT-SPI bus reachable |
| `RequestAccessibilityPermission` / `StartAccessibilityServices` | — | no-op / best-effort on Linux |

### Focus / lifecycle (phase 2)
`SetFocusChangeDetectorState`, `StoreFocusedAppAndElement`, `FocusStoredAppAndElement`,
`SetFocusMode`, `FocusModeBlocked`, `StartAllIntervals`/`StopAllIntervals`,
`StartSpeakerPolling`/`StopSpeakerPolling`, `RecordingStarted`, `DictationStart`/`DictationStop`,
`CancelPaste`, `UpdateShortcuts`, `UpdateFeatureFlags`, `UpdateEditedText`, `GetTextBoxInfo`/`TextBoxInfo`,
`GetDictatedTextPosition`, `SuggestSelectTextbox`, `CursorContextUpdate`, `GetMicrophonePrivacyStatus`,
`GetHardwareInfo`/`HardwareInfoUpdate`, `PlayDictationStartSound`/`PlayDictationStopSound`,
`TrackAnalyticsEvent`, `PasteAnalytics`, `PasteBlocked`, `PasteOutcome`, `HelperAppShutdown`,
`CheckStaleKeys`.

### Likely no-op / stub on Linux (mac/Windows-only features)
BLE ring/headset: `BLEAudioData`, `BLEConnectionState`, `BLEControl`, `BlePairResult`,
`BleSetPairedDevice`, `BleStartPairing`, `FireHaptic`, `AudioCodecChanged`, `AudioInterruptionEvent`,
`MeetingSpeakerChange`, `IsMediaPlayingUpdate`, `GetMicrophoneHolders`.
Floating web panel (mac overlay): `ShowFloatingWebPanel`, `HideFloatingWebPanel`,
`FloatingWebPanelEvent`, `EvaluateFloatingWebPanelJS`, `PositionBrowserWindow`.
App-context scraping: `AppContextHTML`, `AppContextUpdate`, `AppInfoUpdate`, `DockInfoUpdate`,
`KeypressEvent` (emitted by helper).

> Unknown commands should be answered safely: emit a `HelperAPIError` response (see §5) or a benign
> ACK, never crash. The app tolerates missing optional capabilities.

---

## 5. MVP message shapes (exact, from the quicktype typemap)

`""` = string, `0` = number, `true` = boolean literal, `X[]` = array of X, `X?` = optional.

```jsonc
// ---- PasteText (req) ----
{ "HelperAPIRequest": { "uuid": "",
  "PasteText": { "payload": {
    "text": "",                    // plain text to insert
    "htmlText": "",                // HTML variant (set both clipboard formats)
    "transcriptEntityUUID": ""     // correlation id for analytics
  } } } }

// ---- SimulateKeyPress (req) ----
{ "HelperAPIRequest": { "uuid": "",
  "SimulateKeyPress": { "payload": {
    "keycode": 0,                  // numeric — see §6 (Linux receives Windows VK codes)
    "flags": []                    // modifier names: "Control" | "Shift" | "Alt" | "Command" | "Meta"
  } } } }

// ---- GetActiveAppInfo (req) ----  payload-less: value is literal true
{ "HelperAPIRequest": { "GetActiveAppInfo": true, "uuid": "" } }
// ---- ActiveAppInfo (resp) ----
{ "HelperAPIResponse": { "uuid": "",
  "ActiveAppInfo": { "payload": {
    "appName": "",
    "bundleId": "",                // Linux: use desktop-file id / exe basename
    "windowTitle": "",
    "url": "",                     // browser URL if derivable (else "")
    "codingCliAgent": "claude",        // enum: aider|claude|cline|codex|cursor-agent|gemini|opencode|qwen
    "codingCliAgentConfidence": "low"  // enum: high|low
  } } } }

// ---- GetAppInfo (req: true) → AppInfo (resp) ----
{ "HelperAPIResponse": { "uuid": "",
  "AppInfo": { "payload": { "appName": "", "bundleId": "", "url": "" } } } }

// ---- GetRunningApps (req: true) → RunningApps (resp) ----
{ "HelperAPIResponse": { "uuid": "",
  "RunningApps": { "payload": { "apps": [ { "bundleId": "", "name": "" } ] } } } }

// ---- GetSelectedTextViaCopy (req) ----
{ "HelperAPIRequest": { "uuid": "",
  "GetSelectedTextViaCopy": { "payload": { "copyMode": "slack" } } } }   // CopyMode enum: only "slack" so far
// ---- SelectedTextViaCopy (resp) ----
{ "HelperAPIResponse": { "uuid": "",
  "SelectedTextViaCopy": { "payload": {
    "selectedText": "", "beforeText": "", "afterText": "", "contents": ""
  } } } }

// ---- GetAccessibilityStatus (req: true) → AccessibilityStatus (resp) ----
{ "HelperAPIResponse": { "uuid": "",
  "AccessibilityStatus": { "payload": { "status": true } } } }

// ---- ACK (resp) ----  value is literal true
{ "HelperAPIResponse": { "ACK": true, "uuid": "" } }

// ---- HelperAPIError (resp) — use for unsupported/failed commands ----
{ "HelperAPIResponse": { "uuid": "",
  "HelperAPIError": { "payload": {
    "type": "",                    // HelperAPIErrorType enum (placeholder in this build)
    "description": "",
    "params": { "code": "", "messageType": "" }   // both optional
  } } } }

// ---- SetFocusChangeDetectorState (req) ----
{ "HelperAPIRequest": { "uuid": "",
  "SetFocusChangeDetectorState": { "payload": { "active": true } } } }

// ---- KeypressEvent (helper → Electron, an emitted event/request) ----
{ "HelperAPIRequest": { "uuid": "",
  "KeypressEvent": { "payload": {
    "eventType": "", "key": 0, "index": 0, "inputType": ""   // inputType optional
  } } } }

// ---- ClipboardChanged (helper → Electron) ----
{ "HelperAPIRequest": { "uuid": "", "ClipboardChanged": { "payload": { "text": "" } } } }
```

---

## 6. Keycodes & modifiers (critical Linux detail)

The renderer builds `SimulateKeyPress` from a key-name table (`keycodes.json`) selected by platform:

```js
const KEY = { enter: isMac?36:13, backspace: isMac?51:8, ctrl: isMac?59:162, /* … */ };
const mod = isMac ? "Command" : "Control";   // flags use names, not codes
SimulateKeyPress({ keycode: KEY.v, flags: [mod] });   // e.g. Ctrl+V on non-mac
```

`isMac` is the ONLY platform branch. **Linux is not a case → it falls into the `else` (Windows)
branch**, so:

- **`keycode` values the Linux helper receives are Windows Virtual-Key (VK) codes** — e.g.
  `enter=13(0x0D)`, `backspace=8`, `tab=9`, `esc=27`, `space=32`, arrows `left=37 up=38 right=39 down=40`,
  `a..z = 65..90`, `0..9 = 48..57`, `home=36 end=35 pgup=33 pgdn=34 delete=46 insert=45`,
  `f1..f24 = 112..135`, OEM `;=186 ==187 ,=188 -=189 .=190 /=191 \`=192 [=219 \=220 ]=221 '=222`,
  numpad `96..111`. Full map: `keycodes.json` (use the `linux` column).
- **`flags` are modifier *names*** (strings), platform-independent in spelling but semantically:
  on non-mac the renderer emits `"Control"` where mac emits `"Command"`. Expect any of
  `"Control" | "Shift" | "Alt" | "Command" | "Meta"`. Treat `"Command"`/`"Meta"` as Super on Linux
  (rarely sent on non-mac).

**Linux helper keymap job:** map Windows VK → X11 keysym (then `XKeysymToKeycode` for XTEST), or
VK → Linux `KEY_*` input-event code for uinput/ydotool. This is a static lookup table, ~130 entries.

Observed real usages in the bundle (sanity set): Ctrl+V (paste), Ctrl+A (select-all),
Ctrl+Z (undo), Ctrl+Home/Shift (select to start), backspace, enter (submit), up/left (cursor nudge).

### Modifier snapshot/restore
The Windows helper snapshots physically-held modifiers via `GetKeyState`
(Shift/Ctrl/Alt/LMenu/RMenu) and releases-then-restores them around injection so the user's held
keys don't corrupt the synthetic chord. Replicate on X11 via `XQueryKeymap` + temporary
`XTestFakeKeyEvent` releases, restoring after.

---

## 7. PasteText mechanism

Not per-character typing — **clipboard-based**:
1. `OpenClipboard` with exponential-backoff retry to ~250 ms (5 ms → ×2, cap 250 ms) to survive
   clipboard-lock contention.
2. `EmptyClipboard`.
3. `SetClipboardData(CF_UNICODETEXT)` + `SetClipboardData(CF_TEXT)` (both `htmlText` and `text`
   from the payload feed the formats — on Linux set `text/html` + `text/plain` targets).
4. Synthesize **Ctrl+V** via `SendInput`.

Linux replication: save current clipboard → set `CLIPBOARD` selection (X11) / `wl-copy` (Wayland)
to the paste text (offer `UTF8_STRING`/`text/plain` and optionally `text/html`) → synth Ctrl+V via
XTEST/ydotool → (optionally) restore prior clipboard after a short delay. Mirror the retry/backoff
on selection-owner acquisition. The renderer also fires follow-up `SimulateKeyPress` events after a
successful paste (cursor moves, Enter-to-send) gated on `PasteOutcome`, so emitting a
`PasteOutcome`/ACK after paste matters for those flows.

---

## 8. Helper-path resolver (the one main-process change needed)

```js
// current (bundle ~3661149): two-way switch, no linux case
const path = isMac
  ? `${root}/swift-helper-app-dist/Wispr Flow.app/Contents/MacOS/Wispr Flow`
  : `${root}\\Release\\Wispr Flow Helper.exe`;
if (!existsSync(path)) { /* "Helper service script path not found" → feature dead */ }
```

For a Linux build, add a `'linux'` branch pointing at the staged helper binary
(`resources/Release/wispr-flow-linux-helper`, from the
[wispr-flow-linux/helper](https://github.com/wispr-flow-linux/helper) release), and use
forward-slash path joins. This is the only mandatory patch to the unmodified app to wire the helper.
